import 'dart:convert';

import 'package:esp32_photoframe_app/models/config.dart';
import 'package:esp32_photoframe_app/models/device.dart';
import 'package:esp32_photoframe_app/providers/device_provider.dart';
import 'package:esp32_photoframe_app/services/api_client.dart';
import 'package:esp32_photoframe_app/services/saved_devices.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String authHeader(String password) =>
    'Basic ${base64Encode(utf8.encode('photoframe:$password'))}';

/// Just enough of the firmware's password handling (esp32-photoframe #130):
/// every request is checked against [password] when one is set, and PATCH
/// /api/config with http_password replaces it.
class FakeFrame {
  FakeFrame(this.password, {this.legacy = false});

  String password;

  /// Firmware from before #130: no http_auth_enabled, http_password ignored.
  final bool legacy;

  /// Answer the PATCH with success but ignore http_password.
  bool ignorePassword = false;

  /// Answer PATCH /api/config with this instead, leaving [password] alone.
  http.Response? patchResponse;

  /// Apply the PATCH, then fail as if the reply were lost on the way back.
  bool dropPatchReply = false;

  /// Fail the PATCH before it reaches the frame.
  bool failPatch = false;

  /// Runs after the PATCH is applied, before it is answered.
  Future<void> Function()? onPatchApplied;

  /// While set, refuse every request that carries a password with 429 and
  /// this Retry-After, as the frame does for a client it has locked out. One
  /// without a password still gets 401: the firmware answers those before its
  /// limiter, and never counts them.
  Duration? lockout;

  /// While set, answer nothing at all: the frame is asleep or off the network.
  bool unreachable = false;

  final List<http.Request> patches = [];

  /// Every request, in order.
  final List<http.Request> requests = [];

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (unreachable) throw http.ClientException('connection refused');
    if (request.method == 'PATCH' && request.url.path == '/api/config') {
      patches.add(request);
      if (failPatch) throw http.ClientException('connection reset');
      if (patchResponse != null) return patchResponse!;
    }
    if (password.isNotEmpty) {
      final auth = request.headers['authorization'];
      if (auth == null) {
        return http.Response('{"error":"authentication required"}', 401);
      }
      if (lockout != null) {
        return http.Response(
          '{"error":"too many wrong passwords, try again later"}',
          429,
          headers: {'retry-after': '${lockout!.inSeconds}'},
        );
      }
      if (auth != authHeader(password)) {
        return http.Response('{"error":"authentication required"}', 401);
      }
    }
    switch ('${request.method} ${request.url.path}') {
      case 'GET /api/config':
        return http.Response(
          jsonEncode({
            'device_name': 'Study',
            if (!legacy) 'http_auth_enabled': password.isNotEmpty,
          }),
          200,
        );
      case 'PATCH /api/config':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final next = legacy || ignorePassword
            ? null
            : body['http_password'] as String?;
        if (next != null) {
          if (utf8.encode(next).length > 63) {
            return http.Response(
              '{"status":"error",'
              '"message":"Device password is too long (max 63 bytes)"}',
              400,
            );
          }
          password = next;
        }
        await onPatchApplied?.call();
        if (dropPatchReply) throw http.ClientException('connection reset');
        return http.Response('{"status":"success"}', 200);
      default:
        return http.Response('{}', 200);
    }
  }
}

void main() {
  late FakeFrame frame;
  late DeviceProvider provider;

  /// needsPassword / deviceOffline as seen by every listener notification.
  late List<(bool, bool)> seen;

  DeviceProvider newProvider() => DeviceProvider(
    apiClientFactory: ({required baseUrl, required password}) => ApiClient(
      baseUrl: baseUrl,
      password: password,
      client: MockClient(frame.handle),
    ),
  );

  Device device(String password) =>
      Device(name: 'Study', host: 'frame', password: password);

  Future<void> connect(String savedPassword) async {
    provider = newProvider();
    try {
      await provider.connectToDevice(device(savedPassword));
    } on ApiException catch (e) {
      // A saved password the frame no longer takes: the test wants the
      // provider left on the frame, flagging it.
      if (!e.isUnauthorized) rethrow;
    }
    // Let the settings refresh that connecting starts run out.
    await pumpEventQueue(times: 200);
    seen = [];
    provider.addListener(
      () => seen.add((provider.needsPassword, provider.deviceOffline)),
    );
  }

  Future<String?> savedPassword() async {
    final devices = await SavedDevices.load();
    final saved = devices.where((d) => d.host == 'frame');
    return saved.isEmpty ? null : saved.single.password;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('changeFramePassword', () {
    tearDown(() => provider.dispose());

    test('turning it on switches the app to the new password', () async {
      frame = FakeFrame('');
      await connect('');
      expect(provider.config!.httpAuthEnabled, isFalse);

      await provider.changeFramePassword('s3cret');

      expect(frame.password, 's3cret');
      expect(frame.patches.single.headers['authorization'], isNull);
      expect(provider.device!.password, 's3cret');
      expect(provider.apiClient!.password, 's3cret');
      expect(provider.config!.httpAuthEnabled, isTrue);
      expect(await savedPassword(), 's3cret');
      expect(provider.needsPassword, isFalse);
      expect(provider.deviceOffline, isFalse);
      expect(seen, isNot(contains(predicate<(bool, bool)>((s) => s.$1))));
    });

    test('a change is sent with the current password', () async {
      frame = FakeFrame('old');
      await connect('old');

      await provider.changeFramePassword('new');

      expect(frame.patches.single.headers['authorization'], authHeader('old'));
      expect(jsonDecode(frame.patches.single.body), {'http_password': 'new'});
      expect(frame.password, 'new');
      expect(provider.device!.password, 'new');
      expect(await savedPassword(), 'new');
      expect(provider.needsPassword, isFalse);
      expect(seen, isNot(contains(predicate<(bool, bool)>((s) => s.$1))));
    });

    test('requests racing the change do not ask for a password', () async {
      frame = FakeFrame('old');
      await connect('old');
      // The frame has the new password, but the app is still waiting for
      // the PATCH reply: anything it sends now goes out with the old one.
      frame.onPatchApplied = provider.refreshAll;

      await provider.changeFramePassword('new');

      expect(provider.needsPassword, isFalse);
      expect(provider.deviceOffline, isFalse);
      expect(seen, isNot(contains(predicate<(bool, bool)>((s) => s.$1))));
      expect(seen, isNot(contains(predicate<(bool, bool)>((s) => s.$2))));
    });

    test('turning it off clears the saved password', () async {
      frame = FakeFrame('old');
      await connect('old');

      await provider.changeFramePassword('');

      expect(frame.password, '');
      expect(provider.hasPassword, isFalse);
      expect(provider.config!.httpAuthEnabled, isFalse);
      expect(await savedPassword(), '');
    });

    Future<void> expectKeptOld(Future<void> change, Matcher message) async {
      await expectLater(
        change,
        throwsA(
          isA<FramePasswordException>()
              .having((e) => e.applied, 'applied', isFalse)
              .having((e) => e.message, 'message', message),
        ),
      );
      expect(provider.device!.password, 'old');
      expect(provider.apiClient!.password, 'old');
    }

    test('a rejected password keeps the old one', () async {
      frame = FakeFrame('changed-elsewhere');
      await connect('old');

      await expectKeptOld(
        provider.changeFramePassword('new'),
        contains('rejected the password this app has saved'),
      );
      expect(frame.password, 'changed-elsewhere');
      // Rejected outright, so the banner leads to entering the right one.
      expect(provider.needsPassword, isTrue);
    });

    test('a lockout keeps the old one and says how long to wait', () async {
      frame = FakeFrame('old');
      await connect('old');
      frame.patchResponse = http.Response(
        '{"error":"too many wrong passwords, try again later"}',
        429,
        headers: {'retry-after': '30'},
      );

      await expectKeptOld(
        provider.changeFramePassword('new'),
        contains('30 seconds'),
      );
      expect(frame.password, 'old');
    });

    test('a password the frame refuses keeps the old one', () async {
      frame = FakeFrame('old');
      await connect('old');
      frame.patchResponse = http.Response(
        '{"status":"error",'
        '"message":"Device password is too long (max 63 bytes)"}',
        400,
      );

      await expectKeptOld(
        provider.changeFramePassword('new'),
        contains('max 63 bytes'),
      );
    });

    test('a password over 63 bytes is not sent at all', () async {
      frame = FakeFrame('old');
      await connect('old');

      // 32 two-byte characters: 32 characters, 64 bytes.
      await expectKeptOld(
        provider.changeFramePassword('é' * 32),
        contains('63 bytes'),
      );
      expect(frame.patches, isEmpty);
    });

    test(
      'firmware that ignores the password is not called protected',
      () async {
        frame = FakeFrame('', legacy: true);
        await connect('');

        await expectLater(
          provider.changeFramePassword('new'),
          throwsA(
            isA<FramePasswordException>()
                .having((e) => e.applied, 'applied', isFalse)
                .having((e) => e.message, 'message', contains('firmware')),
          ),
        );
        expect(provider.device!.password, '');
        expect(provider.apiClient!.password, '');
        expect(await savedPassword(), '');
      },
    );

    test('a frame still open afterwards keeps the old one', () async {
      frame = FakeFrame('')..ignorePassword = true;
      await connect('');

      await expectLater(
        provider.changeFramePassword('new'),
        throwsA(
          isA<FramePasswordException>()
              .having((e) => e.applied, 'applied', isFalse)
              .having((e) => e.message, 'message', contains('still off')),
        ),
      );
      expect(provider.device!.password, '');
      expect(await savedPassword(), '');
    });

    test('a password with a NUL is not sent at all', () async {
      frame = FakeFrame('old');
      await connect('old');

      await expectKeptOld(
        provider.changeFramePassword('new\u0000tail'),
        contains('NUL'),
      );
      expect(frame.patches, isEmpty);
    });

    test('a change the frame does not keep goes back to the old one', () async {
      frame = FakeFrame('old');
      await connect('old');
      frame.onPatchApplied = () async => frame.password = 'old';

      await expectKeptOld(
        provider.changeFramePassword('new'),
        contains('did not keep'),
      );
      expect(await savedPassword(), 'old');
      expect(provider.needsPassword, isFalse);
    });

    test('an unreachable frame keeps the old one', () async {
      frame = FakeFrame('old');
      await connect('old');
      frame.failPatch = true;

      await expectKeptOld(
        provider.changeFramePassword('new'),
        contains('Could not reach the frame'),
      );
      expect(frame.password, 'old');
      expect(await savedPassword(), isNot('new'));
    });

    test('a lost reply still switches once the frame confirms it', () async {
      frame = FakeFrame('old');
      await connect('old');
      frame.dropPatchReply = true;

      await provider.changeFramePassword('new');

      expect(frame.password, 'new');
      expect(provider.device!.password, 'new');
      expect(await savedPassword(), 'new');
    });
  });

  // The frame locks a client out after five wrong passwords, for 30 s and
  // then longer each time (esp32-photoframe #130). So a wrong password must
  // cost one refused request, not a burst, and a lockout must not be taken
  // for the frame being offline. Fake time: the keep-alive runs every 30 s.
  group('the lockout after wrong passwords', () {
    /// What the frame has been sent since its [since]th request.
    List<String> sent(int since) => frame.requests
        .skip(since)
        .map((r) => '${r.method} ${r.url.path}')
        .toList();

    test('connecting sends one request, and nothing more until it is '
        'answered', () {
      fakeAsync((async) {
        frame = FakeFrame('right');
        final provider = newProvider();
        Object? error;
        provider
            .connectToDevice(device('wrong'))
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.flushMicrotasks();

        expect(
          error,
          isA<ApiException>().having(
            (e) => e.isUnauthorized,
            'isUnauthorized',
            isTrue,
          ),
        );
        expect(sent(0), ['GET /api/system-info']);
        expect(provider.needsPassword, isTrue);
        // Nothing periodic: each request would be another wrong password.
        async.elapse(const Duration(minutes: 10));
        expect(frame.requests, hasLength(1));
        expect(async.periodicTimerCount, 0);

        // The right one: answered, so the keep-alive and refresh start.
        SystemInfo? info;
        provider.connectToDevice(device('right')).then((i) => info = i);
        async.flushMicrotasks();
        expect(info, isNotNull);
        expect(provider.systemInfo, same(info));
        expect(provider.needsPassword, isFalse);
        expect(sent(1).first, 'GET /api/system-info');
        expect(async.periodicTimerCount, 2);
        final started = frame.requests.length;
        async.elapse(const Duration(seconds: 30));
        expect(sent(started), ['POST /api/keep_alive']);
        provider.dispose();
      });
    });

    test('a 401 stops the keep-alive until a new password is answered', () {
      fakeAsync((async) {
        frame = FakeFrame('old');
        final provider = newProvider();
        provider.connectToDevice(device('old')).ignore();
        async.flushMicrotasks();
        expect(async.periodicTimerCount, 2);

        // The password is changed on the frame.
        frame.password = 'new';
        final changed = frame.requests.length;
        async.elapse(const Duration(seconds: 30));
        expect(sent(changed), ['POST /api/keep_alive']);
        expect(provider.needsPassword, isTrue);
        // No more are sent with it: each would be another wrong password.
        expect(async.periodicTimerCount, 0);
        async.elapse(const Duration(minutes: 10));
        expect(frame.requests, hasLength(changed + 1));

        // A typo costs one request and leaves it stopped.
        provider.setPassword('typo').ignore();
        async.flushMicrotasks();
        expect(sent(changed + 1), ['GET /api/config']);
        expect(provider.needsPassword, isTrue);
        expect(async.periodicTimerCount, 0);

        // The right one: answered, so the keep-alive and refresh resume.
        final entered = frame.requests.length;
        provider.setPassword('new').ignore();
        async.flushMicrotasks();
        expect(sent(entered).first, 'GET /api/config');
        expect(provider.needsPassword, isFalse);
        expect(provider.config, isNotNull);
        expect(async.periodicTimerCount, 2);
        final resumed = frame.requests.length;
        async.elapse(const Duration(seconds: 30));
        expect(sent(resumed), ['POST /api/keep_alive']);
        provider.dispose();
      });
    });

    test('a lockout met by the keep-alive is not offline', () {
      fakeAsync((async) {
        frame = FakeFrame('old');
        final provider = newProvider();
        provider.connectToDevice(device('old')).ignore();
        async.flushMicrotasks();
        final seen = <(bool, bool)>[];
        provider.addListener(
          () => seen.add((provider.deviceOffline, provider.needsPassword)),
        );

        // Something else at this address (a browser, say) got it locked out.
        frame.lockout = const Duration(seconds: 30);
        async.elapse(const Duration(seconds: 30));
        expect(provider.lockedOut, isTrue);
        expect(provider.lockoutWait, const Duration(seconds: 30));
        expect(provider.deviceOffline, isFalse);
        expect(provider.needsPassword, isFalse);
        // Refused through further keep-alives and a settings refresh too.
        async.elapse(const Duration(minutes: 5));
        expect(provider.lockedOut, isTrue);
        expect(seen.where((s) => s.$1 || s.$2), isEmpty);
        expect(async.periodicTimerCount, 2);

        // Over: the next keep-alive is answered and clears it.
        frame.lockout = null;
        async.elapse(const Duration(seconds: 30));
        expect(provider.lockedOut, isFalse);
        expect(provider.deviceOffline, isFalse);
        provider.dispose();
      });
    });

    test('connecting into a lockout reports it, not offline', () {
      fakeAsync((async) {
        frame = FakeFrame('old')..lockout = const Duration(seconds: 30);
        final provider = newProvider();
        Object? error;
        provider
            .connectToDevice(device('old'))
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.flushMicrotasks();

        expect(
          error,
          isA<ApiException>()
              .having((e) => e.isRateLimited, 'isRateLimited', isTrue)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 30),
              ),
        );
        expect(provider.lockedOut, isTrue);
        expect(provider.deviceOffline, isFalse);
        expect(provider.needsPassword, isFalse);
        expect(async.periodicTimerCount, 0);
        expect(
          describeLockout((error as ApiException).retryAfter),
          'The frame is refusing requests for 30 seconds after wrong '
          'passwords.',
        );
        provider.dispose();
      });
    });

    test('a password entered during a lockout is tried once it ends', () {
      fakeAsync((async) {
        frame = FakeFrame('old');
        final provider = newProvider();
        provider.connectToDevice(device('old')).ignore();
        async.flushMicrotasks();
        frame.password = 'new';
        async.elapse(const Duration(seconds: 30));
        expect(provider.needsPassword, isTrue);

        // Entered while the frame refuses everything from this phone.
        frame.lockout = const Duration(seconds: 30);
        final entered = frame.requests.length;
        provider.setPassword('new').ignore();
        async.flushMicrotasks();
        expect(sent(entered), ['GET /api/config']);
        expect(provider.lockedOut, isTrue);
        expect(provider.needsPassword, isFalse);
        expect(provider.deviceOffline, isFalse);
        expect(async.periodicTimerCount, 0);

        // Nothing until the lockout is over, then that one request again.
        async.elapse(const Duration(seconds: 29));
        expect(frame.requests, hasLength(entered + 1));
        frame.lockout = null;
        async.elapse(const Duration(seconds: 2));
        expect(sent(entered + 1).first, 'GET /api/config');
        expect(provider.lockedOut, isFalse);
        expect(provider.config, isNotNull);
        expect(async.periodicTimerCount, 2);
        provider.dispose();
      });
    });

    test('a password the frame does not answer is tried again, one request '
        'at a time', () {
      fakeAsync((async) {
        frame = FakeFrame('old');
        final provider = newProvider();
        provider.connectToDevice(device('old')).ignore();
        async.flushMicrotasks();
        frame.password = 'new';
        async.elapse(const Duration(seconds: 30));
        expect(provider.needsPassword, isTrue);

        // Entered while the frame is asleep.
        frame.unreachable = true;
        final entered = frame.requests.length;
        provider.setPassword('new').ignore();
        async.flushMicrotasks();
        expect(sent(entered), ['GET /api/config']);
        expect(provider.needsPassword, isFalse);
        expect(provider.deviceOffline, isFalse);
        expect(async.periodicTimerCount, 0);

        // Asked again at the keep-alive's pace, and called offline after the
        // second failure as the keep-alive would; still nothing in parallel.
        async.elapse(const Duration(seconds: 30));
        expect(sent(entered), ['GET /api/config', 'GET /api/config']);
        expect(provider.deviceOffline, isTrue);
        expect(async.periodicTimerCount, 0);

        // Back: answered, so the keep-alive and refresh start.
        frame.unreachable = false;
        async.elapse(const Duration(seconds: 30));
        expect(sent(entered)[2], 'GET /api/config');
        expect(provider.deviceOffline, isFalse);
        expect(provider.config, isNotNull);
        expect(async.periodicTimerCount, 2);
        provider.dispose();
      });
    });

    test('a lockout met while retrying an unanswered password is not '
        'offline', () {
      fakeAsync((async) {
        frame = FakeFrame('old');
        final provider = newProvider();
        provider.connectToDevice(device('old')).ignore();
        async.flushMicrotasks();
        frame.password = 'new';
        async.elapse(const Duration(seconds: 30));
        frame.unreachable = true;
        provider.setPassword('new').ignore();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(provider.deviceOffline, isTrue);

        // Back, but locked out by something else at this address: that is
        // an answer, so the offline verdict is stale.
        frame.unreachable = false;
        frame.lockout = const Duration(seconds: 30);
        async.elapse(const Duration(seconds: 30));
        expect(provider.lockedOut, isTrue);
        expect(provider.deviceOffline, isFalse);
        expect(provider.needsPassword, isFalse);

        frame.lockout = null;
        async.elapse(const Duration(seconds: 31));
        expect(provider.lockedOut, isFalse);
        expect(provider.deviceOffline, isFalse);
        expect(async.periodicTimerCount, 2);
        provider.dispose();
      });
    });

    test('describeWait rounds the way the frame counts', () {
      expect(describeWait(null), 'a while');
      expect(describeWait(const Duration(seconds: 1)), '1 second');
      expect(describeWait(const Duration(seconds: 89)), '89 seconds');
      expect(describeWait(const Duration(seconds: 90)), '2 minutes');
      expect(describeWait(const Duration(minutes: 15)), '15 minutes');
    });
  });

  group('DeviceConfig.httpAuthEnabled', () {
    test('reads true and false', () {
      expect(
        DeviceConfig.fromJson({'http_auth_enabled': true}).httpAuthEnabled,
        isTrue,
      );
      expect(
        DeviceConfig.fromJson({'http_auth_enabled': false}).httpAuthEnabled,
        isFalse,
      );
    });

    test('is null on firmware without the setting', () {
      expect(DeviceConfig.fromJson({}).httpAuthEnabled, isNull);
    });
  });

  test('ApiException carries Retry-After', () {
    expect(parseRetryAfter('30'), const Duration(seconds: 30));
    expect(parseRetryAfter(null), isNull);
    expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
  });
}
