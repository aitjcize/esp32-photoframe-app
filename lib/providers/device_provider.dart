import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/album.dart';
import '../models/config.dart';
import '../models/device.dart';
import '../services/api_client.dart';
import '../services/saved_devices.dart';

/// Builds the client for a frame. Tests swap in one backed by a mock.
typedef ApiClientFactory =
    ApiClient Function({required String baseUrl, required String password});

ApiClient _defaultApiClient({
  required String baseUrl,
  required String password,
}) => ApiClient(baseUrl: baseUrl, password: password);

/// For the user: how long the frame said to wait, from the Retry-After of
/// its refusal, or 'a while' when it did not say.
String describeWait(Duration? wait) {
  if (wait == null) return 'a while';
  final seconds = wait.inSeconds;
  if (seconds < 90) return '$seconds second${seconds == 1 ? '' : 's'}';
  return '${(seconds / 60).ceil()} minutes';
}

/// For the user: the frame answered 429 (esp32-photoframe #130). Too many
/// wrong passwords came from this phone's address, and the frame refuses
/// every request, right password or not, until [wait] is over.
String describeLockout(Duration? wait) =>
    'The frame is refusing requests for ${describeWait(wait)} after wrong '
    'passwords.';

/// Why changing the frame's own password failed. [message] is written for the
/// user. [applied] is true when the frame did take the new password and only
/// confirming it afterwards failed: the app then holds the new password, since
/// the old one no longer works.
class FramePasswordException implements Exception {
  const FramePasswordException(this.message, {this.applied = false});

  final String message;
  final bool applied;

  @override
  String toString() => message;
}

class DeviceProvider extends ChangeNotifier {
  DeviceProvider({ApiClientFactory apiClientFactory = _defaultApiClient})
    : _newApiClient = apiClientFactory;

  final ApiClientFactory _newApiClient;

  /// The firmware refuses longer passwords (esp32-photoframe #130).
  static const int maxFramePasswordBytes = 63;

  Device? _device;
  ApiClient? _apiClient;
  String? _apiBaseUrl;
  SystemInfo? _systemInfo;
  BatteryInfo? _batteryInfo;
  SensorInfo? _sensorInfo;
  DeviceConfig? _config;
  List<Album> _albums = [];
  String? _currentImage;
  bool _loading = false;
  String? _error;
  Timer? _keepAliveTimer;
  Timer? _backgroundRefreshTimer;

  /// Sends the first request of a password again when the frame did not
  /// answer it, or refused it with a lockout. See [_firstRequest].
  Timer? _retryTimer;
  int _keepAliveFailures = 0;
  bool _deviceOffline = false;
  bool _needsPassword = false;
  bool _lockedOut = false;
  Duration? _lockoutWait;

  /// Set while [changeFramePassword] waits on the frame. Once the frame
  /// applies the new password, requests still in flight with the old one are
  /// answered 401; those must not raise [needsPassword] for a password that
  /// is being replaced on purpose.
  bool _changingPassword = false;

  // Cached device settings (refreshed every 5 min)
  Map<String, dynamic>? _processingSettings;
  Map<String, dynamic>? _paletteSettings;

  bool get deviceOffline => _deviceOffline;

  /// The frame answered 401: it has a password and the one we hold is missing
  /// or stale. Distinct from [deviceOffline], which means unreachable.
  bool get needsPassword => _needsPassword;

  /// The frame answered 429: too many wrong passwords came from this phone's
  /// address, and it refuses every request, right password or not, until the
  /// lockout ends (esp32-photoframe #130). It is reachable, and the refusal
  /// says nothing about the password held here -- the frame refuses before
  /// looking at it -- so this is neither [deviceOffline] nor [needsPassword].
  /// The keep-alive goes on asking, and the next answer clears it.
  bool get lockedOut => _lockedOut;

  /// How long the frame said to wait when it last refused with 429, from its
  /// Retry-After; null when it did not say. Meaningful while [lockedOut].
  Duration? get lockoutWait => _lockoutWait;

  /// Whether a password is stored for the connected frame.
  bool get hasPassword => _device?.password.isNotEmpty ?? false;
  Map<String, dynamic>? get processingSettings => _processingSettings;
  Map<String, dynamic>? get paletteSettings => _paletteSettings;

  /// Relative luminance (Y, 0..1) of the panel's full black, as reported by a
  /// GC16 device's palette response (`{"black_y": ...}`). Null when absent or
  /// when the panel is color (the palette response carries a grays array
  /// instead). Drives the calibrated grayscale preview ramp.
  double? get grayBlackY => (_paletteSettings?['black_y'] as num?)?.toDouble();

  /// Relative luminance (Y, 0..1) of the panel's full white. See [grayBlackY].
  double? get grayWhiteY => (_paletteSettings?['white_y'] as num?)?.toDouble();

  /// Per-panel grayscale gamma shaping the mid-level perceived ramp, as reported
  /// by a GC16 device's palette response (`{"gamma": ...}`). 1.0 = perceptually
  /// linear; >1 darkens mid-tones, <1 lightens. Null when absent. See
  /// [grayBlackY].
  double? get grayGamma => (_paletteSettings?['gamma'] as num?)?.toDouble();

  Device? get device => _device;
  ApiClient? get apiClient => _apiClient;
  SystemInfo? get systemInfo => _systemInfo;
  BatteryInfo? get batteryInfo => _batteryInfo;
  SensorInfo? get sensorInfo => _sensorInfo;
  DeviceConfig? get config => _config;
  List<Album> get albums => _albums;
  String? get currentImage => _currentImage;
  bool get loading => _loading;
  String? get error => _error;
  bool get isConnected => _device != null && _systemInfo != null;

  /// Connect to a device. If the host is a .local mDNS name,
  /// resolves to IP first for reliable HTTP. The original device
  /// (with mDNS hostname) is kept for persistence.
  ///
  /// Then asks the frame for its system info with the device's password, and
  /// returns it. The keep-alive and the background refresh start only once
  /// that is answered: the frame locks a client out after five wrong
  /// passwords, so a wrong one must cost one refused request, not the four
  /// those would send at once. Throws what that request threw -- an
  /// [ApiException] that [ApiException.isUnauthorized] (the password is
  /// wrong or missing; [needsPassword] is raised) or
  /// [ApiException.isRateLimited] ([lockedOut] is raised), or a timeout or
  /// socket error when the frame cannot be reached. The provider then stays
  /// on the device, sending nothing more than that request again when the
  /// frame may answer later (see [_firstRequest]), so the caller can try
  /// another password or [disconnect].
  Future<SystemInfo> connectToDevice(Device device) async {
    _stopKeepAlive();
    _apiClient?.dispose();
    // Settings shown for the previous frame say nothing about this one, and
    // would offer it options its firmware may not have.
    if (_device != device) _config = null;
    _device = device;
    _systemInfo = null;

    // Resolve .local hostname to IP for API requests. IPv4 only: the
    // firmware also publishes an IPv6 link-local AAAA record, and a bare
    // fe80:: address is unusable here (needs a scope ID, and would have to
    // be bracketed in the URL).
    var apiHost = device.host;
    if (device.host.endsWith('.local')) {
      try {
        final addresses = await InternetAddress.lookup(
          device.host,
          type: InternetAddressType.IPv4,
        );
        if (addresses.isNotEmpty) {
          apiHost = addresses.first.address;
        }
      } catch (_) {
        // Fall back to .local hostname
      }
    }

    _apiBaseUrl = 'http://$apiHost:${device.port}';
    final client = _newApiClient(
      baseUrl: _apiBaseUrl!,
      password: device.password,
    );
    _apiClient = client;
    _error = null;
    _keepAliveFailures = 0;
    _deviceOffline = false;
    _needsPassword = false;
    _clearLockout();
    notifyListeners();

    return _firstRequest(
      client,
      client.getSystemInfo,
      onAnswered: (info) => _systemInfo = info,
    );
  }

  // ChangeNotifier doesn't have mounted, so we track disposal
  bool _disposed = false;
  bool get mounted => !_disposed;

  /// Change the password sent to the connected frame, and persist it with the
  /// saved device so the next connection starts out authenticated. The frame
  /// never hands the password back, so this is the only way it is learned.
  /// The frame itself is left alone; see [changeFramePassword] for that.
  Future<void> setPassword(String password) async {
    final device = _device;
    final baseUrl = _apiBaseUrl;
    if (device == null || baseUrl == null) return;
    _adoptPassword(device, baseUrl, password);
    notifyListeners();
    // Try it straight away rather than leave it to the user to notice, and
    // give Settings the config it may still be waiting on. The keep-alive
    // and the background refresh, stopped by the 401 this answers, start
    // again once the frame has taken it.
    final client = _apiClient!;
    _firstRequest(
      client,
      client.getConfig,
      onAnswered: (config) => _config = config,
    ).ignore();
    await SavedDevices.addDevice(_device!);
  }

  /// Switch to a new client that sends [password], and clear whatever the old
  /// one had flagged. Callers notify and persist. The periodic requests stop
  /// until the frame has answered the new password, so that a wrong one is
  /// refused once, not once per request in flight: callers start them again
  /// through [_firstRequest], or [_startKeepAlive] when the password has
  /// already been answered.
  void _adoptPassword(Device device, String baseUrl, String password) {
    _device = device.copyWith(password: password);
    _apiClient?.dispose();
    _apiClient = _newApiClient(baseUrl: baseUrl, password: password);
    _stopKeepAlive();
    _needsPassword = false;
    _deviceOffline = false;
    _keepAliveFailures = 0;
  }

  static const _firstRequestTimeout = Duration(seconds: 5);
  static const _keepAliveInterval = Duration(seconds: 30);

  /// The firmware's shortest lockout, for a 429 that carries no Retry-After.
  static const _lockoutFallback = Duration(seconds: 30);

  /// Sends the first request of a password, before anything periodic goes
  /// out with it. [onAnswered] takes the reply while [client] is still the
  /// current one; the keep-alive and the background refresh then start. A
  /// 401 raises [needsPassword] and nothing more is sent. A 429 raises
  /// [lockedOut], and the request is sent once more when the lockout ends,
  /// since the refusal says nothing about the password: the frame refuses
  /// before looking at it. No answer, or any other error, says nothing
  /// about it either: the request is sent again at the keep-alive's pace,
  /// still one at a time, and the frame is called offline after two
  /// failures as the keep-alive would. Rethrows whatever [request] threw.
  Future<T> _firstRequest<T>(
    ApiClient client,
    Future<T> Function() request, {
    required void Function(T reply) onAnswered,
  }) async {
    final T reply;
    try {
      reply = await request().timeout(_firstRequestTimeout);
    } catch (e) {
      if (_isCurrent(client)) {
        if (e is ApiException && e.isUnauthorized) {
          if (!_needsPassword && !_changingPassword) {
            _markNeedsPassword();
            notifyListeners();
          }
        } else if (e is ApiException && e.isRateLimited) {
          _markLockedOut(e.retryAfter);
          _retryFirstRequest(
            client,
            request,
            onAnswered,
            after:
                (e.retryAfter ?? _lockoutFallback) + const Duration(seconds: 1),
          );
          notifyListeners();
        } else {
          _keepAliveFailures++;
          if (_keepAliveFailures >= 2 && !_deviceOffline) {
            _deviceOffline = true;
            notifyListeners();
          }
          _retryFirstRequest(
            client,
            request,
            onAnswered,
            after: _keepAliveInterval,
          );
        }
      }
      rethrow;
    }
    if (!_isCurrent(client)) return reply;
    onAnswered(reply);
    _noteAnswered();
    notifyListeners();
    return reply;
  }

  void _retryFirstRequest<T>(
    ApiClient client,
    Future<T> Function() request,
    void Function(T reply) onAnswered, {
    required Duration after,
  }) {
    _retryTimer?.cancel();
    _retryTimer = Timer(after, () {
      if (!_isCurrent(client)) return;
      _firstRequest(client, request, onAnswered: onAnswered).ignore();
    });
  }

  /// Whether [client] is still the one requests go through: not replaced by
  /// a reconnect or a new password, and this provider not disposed. Replies
  /// to any other say nothing about the current password.
  bool _isCurrent(ApiClient client) =>
      !_disposed && identical(client, _apiClient);

  /// Set, change or (with an empty [newPassword]) remove the password on the
  /// frame's own HTTP API, then switch this app over to it.
  ///
  /// The order keeps the app from ever holding a password the frame does not:
  /// the change is sent with the current password, the app switches only once
  /// the frame has accepted it, and the new password is then tried by reading
  /// the config back. If the frame refuses the change or cannot be reached,
  /// the app keeps the old password. Throws [FramePasswordException].
  Future<void> changeFramePassword(String newPassword) async {
    final device = _device;
    final baseUrl = _apiBaseUrl;
    final client = _apiClient;
    if (device == null || baseUrl == null || client == null) {
      throw const FramePasswordException('Not connected to a frame.');
    }
    // The frame keeps the password as a C string: it would keep only what
    // comes before a NUL, and never match the whole one the app then sends.
    if (newPassword.contains('\u0000')) {
      throw const FramePasswordException(
        'The password cannot contain a NUL character.',
      );
    }
    if (utf8.encode(newPassword).length > maxFramePasswordBytes) {
      throw const FramePasswordException(
        'The password is too long: the frame accepts at most '
        '$maxFramePasswordBytes bytes.',
      );
    }

    _changingPassword = true;
    try {
      try {
        await client
            .updateConfig({'http_password': newPassword})
            .timeout(_passwordRequestTimeout);
      } on ApiException catch (e) {
        // The saved password is wrong: raise the banner, as any other request
        // would, so it leads straight to entering the right one.
        if (e.isUnauthorized &&
            identical(client, _apiClient) &&
            !_needsPassword) {
          _markNeedsPassword();
          notifyListeners();
        }
        throw FramePasswordException(_describeRefusal(e));
      } catch (_) {
        // No answer. The frame may still have applied it before the reply
        // was lost; ask it with the new password before giving up on it.
        if (!await _frameUses(baseUrl, newPassword)) {
          throw const FramePasswordException(
            'Could not reach the frame. The app still uses the old password. '
            'If the frame applied the change anyway and starts asking for a '
            "password, enter the new one with \"I already know the frame's "
            'password".',
          );
        }
      }

      // The frame now wants the new password. Switch before anything else
      // can fail, so the app never goes on sending the one it dropped.
      final current = _device;
      final currentBaseUrl = _apiBaseUrl;
      final stillConnected =
          current != null && current == device && currentBaseUrl != null;
      ApiClient? adopted;
      if (stillConnected) {
        _adoptPassword(current, currentBaseUrl, newPassword);
        adopted = _apiClient;
        notifyListeners();
      }
      // Saved even if the user has since moved to another frame, so that
      // frame's entry stays usable.
      try {
        await SavedDevices.addDevice(
          stillConnected ? _device! : device.copyWith(password: newPassword),
        );
      } catch (_) {
        // The frame has the new password and the app holds it, so the
        // periodic requests may go on. The read-back below is skipped, so
        // try the password the way it would have, one request first.
        if (adopted != null && identical(adopted, _apiClient)) {
          _firstRequest(
            adopted,
            adopted.getConfig,
            onAnswered: (config) => _config = config,
          ).ignore();
        }
        throw const FramePasswordException(
          'The frame took the new password, but this app could not save it. '
          "If the frame asks for it later, enter it with \"I already know "
          "the frame's password\".",
          applied: true,
        );
      }
      if (!stillConnected) return;
    } finally {
      _changingPassword = false;
    }

    // Try the new password straight away rather than leave it to the next
    // keep-alive, and pick up the frame's view of protection on or off.
    final confirmClient = _apiClient!;
    final DeviceConfig config;
    try {
      config = await confirmClient.getConfig().timeout(_passwordRequestTimeout);
    } catch (e) {
      // Refused with the new password: if the old one still works, the frame
      // did not keep the change after all, so go back to it.
      if (e is ApiException &&
          e.isUnauthorized &&
          identical(confirmClient, _apiClient) &&
          await _frameUses(_apiBaseUrl!, device.password)) {
        if (identical(confirmClient, _apiClient)) {
          _adoptPassword(_device!, _apiBaseUrl!, device.password);
          // Just answered with the old password, so no need to try it first.
          _startKeepAlive();
          notifyListeners();
          try {
            await SavedDevices.addDevice(_device!);
          } catch (_) {}
        }
        throw const FramePasswordException(
          'The frame did not keep the new password. The app still uses the '
          'old one.',
        );
      }
      if (e is ApiException &&
          e.isUnauthorized &&
          identical(confirmClient, _apiClient) &&
          !_needsPassword) {
        _markNeedsPassword();
        notifyListeners();
      } else if (identical(confirmClient, _apiClient)) {
        // No answer, or refused for another reason. The frame did take the
        // password -- the PATCH, or _frameUses, said so -- so the keep-alive
        // may run with it, and will find out whether the frame is reachable.
        _startKeepAlive();
      }
      throw const FramePasswordException(
        'The frame accepted the new password, but reading its settings back '
        'with it failed.',
        applied: true,
      );
    }
    if (!identical(confirmClient, _apiClient)) return;
    _config = config;
    // The new password is answered: the periodic requests may run with it.
    _noteAnswered();
    notifyListeners();

    if (newPassword.isNotEmpty && config.httpAuthEnabled != true) {
      // The frame took the request but is still open: firmware without the
      // setting ignores the key, and says nothing about it. An open frame
      // takes any password, so going back to the old one is safe, and saying
      // protection is on would not be.
      _adoptPassword(_device!, _apiBaseUrl!, device.password);
      _startKeepAlive();
      notifyListeners();
      try {
        await SavedDevices.addDevice(_device!);
      } catch (_) {}
      throw FramePasswordException(
        config.httpAuthEnabled == null
            ? "This frame's firmware does not support password protection. "
                  'Update the firmware first.'
            : 'The frame answered, but password protection is still off. '
                  'Nothing was changed.',
      );
    }
    // Turning it off cannot land here the other way round: with protection
    // still on, the read-back without a password would have been refused.
  }

  static const _passwordRequestTimeout = Duration(seconds: 10);

  /// Whether the frame at [baseUrl] is now guarded by exactly [password]:
  /// it answers with that password and reports protection on or off to
  /// match. A frame that is open answers any password, so answering alone
  /// proves nothing.
  Future<bool> _frameUses(String baseUrl, String password) async {
    final probe = _newApiClient(baseUrl: baseUrl, password: password);
    try {
      final config = await probe.getConfig().timeout(_passwordRequestTimeout);
      return config.httpAuthEnabled == password.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      probe.dispose();
    }
  }

  static String _describeRefusal(ApiException e) {
    if (e.isRateLimited) {
      return 'The frame is refusing requests after too many wrong '
          'passwords. Wait ${describeWait(e.retryAfter)} and try again. The '
          'password was not changed.';
    }
    if (e.isUnauthorized) {
      return 'The frame rejected the password this app has saved, so the '
          'password was not changed. Enter the current password first '
          "(\"I already know the frame's password\").";
    }
    if (e.statusCode == 400) {
      String? detail;
      try {
        // Config errors come as {"status":"error","message":...}; the auth
        // gate's own refusals as {"error":...}.
        final body = jsonDecode(e.body) as Map<String, dynamic>;
        detail = (body['message'] ?? body['error']) as String?;
      } catch (_) {}
      return 'The frame refused the new password'
          '${detail == null || detail.isEmpty ? '' : ': $detail'}. '
          'The password was not changed.';
    }
    return 'The frame could not change the password (HTTP ${e.statusCode}). '
        'The app still uses the old one.';
  }

  void disconnect() {
    _stopKeepAlive();
    _keepAliveFailures = 0;
    _deviceOffline = false;
    _needsPassword = false;
    _clearLockout();
    _apiClient?.dispose();
    _apiClient = null;
    _apiBaseUrl = null;
    _device = null;
    _systemInfo = null;
    _batteryInfo = null;
    _sensorInfo = null;
    _config = null;
    _albums = [];
    _currentImage = null;
    _error = null;
    _processingSettings = null;
    _paletteSettings = null;
    notifyListeners();
  }

  /// Starts the periodic keep-alive and settings refresh, and refreshes the
  /// settings now. Only once the frame has answered a request with the
  /// current password (see [_firstRequest]); nothing to do while they run.
  void _startKeepAlive() {
    if (_keepAliveTimer != null) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _keepAliveTimer = Timer.periodic(_keepAliveInterval, (_) {
      _sendKeepAlive();
    });
    // Refresh settings in background every 5 minutes
    _refreshSettingsInBackground();
    _backgroundRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _refreshSettingsInBackground();
    });
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _backgroundRefreshTimer?.cancel();
    _backgroundRefreshTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _sendKeepAlive() async {
    final client = _apiClient;
    if (client == null) return;
    try {
      await client.keepAlive().timeout(const Duration(seconds: 5));
      // Answered by a client setPassword or a reconnect has since replaced:
      // says nothing about the current one.
      if (!_isCurrent(client)) return;
      // A success also means the password (if any) is accepted again.
      if (_noteAnswered()) notifyListeners();
    } catch (e) {
      if (!_isCurrent(client)) return;
      // A 401 is definitive -- the frame is up, it just wants a password we do
      // not have. Report it at once instead of burning the retry budget and
      // then calling a reachable frame offline.
      if (e is ApiException && e.isUnauthorized) {
        _keepAliveFailures = 0;
        if (!_needsPassword && !_changingPassword) {
          _markNeedsPassword();
          notifyListeners();
        }
        return;
      }
      // A 429 is the frame's lockout: it answered, so it is not offline, and
      // it refused before looking at the password, so this says nothing
      // about that either. The keep-alive goes on -- a refusal during the
      // lockout does not extend it -- and the first answer after it says
      // whether the password still works.
      if (e is ApiException && e.isRateLimited) {
        _markLockedOut(e.retryAfter);
        notifyListeners();
        return;
      }
      _keepAliveFailures++;
      if (_keepAliveFailures >= 2 && !_deviceOffline) {
        _deviceOffline = true;
        notifyListeners();
      }
    }
  }

  /// The frame answered 401. It is reachable, but nothing works until the
  /// password is fixed, so it is reported through [deviceOffline] as well --
  /// that is what sends the gallery back to the device list, where the
  /// password is asked for -- with [needsPassword] saying why.
  ///
  /// The periodic requests stop: each would be another wrong password to a
  /// frame that locks this phone out after five, for longer each time. They
  /// start again once a new password is answered (see [_firstRequest]).
  void _markNeedsPassword() {
    _needsPassword = true;
    _deviceOffline = true;
    // The frame looked at the password, so any lockout is over.
    _clearLockout();
    _stopKeepAlive();
  }

  /// The frame answered 429; see [lockedOut].
  void _markLockedOut(Duration? wait) {
    _lockedOut = true;
    _lockoutWait = wait;
    // It answered, so it is reachable: an offline verdict from earlier
    // failures is stale. Not when offline stands in for needsPassword, which
    // a 429 says nothing about.
    _keepAliveFailures = 0;
    if (!_needsPassword) _deviceOffline = false;
  }

  void _clearLockout() {
    _lockedOut = false;
    _lockoutWait = null;
  }

  /// A request with the current password was answered: the frame is
  /// reachable and takes the password, so whatever its last refusal said is
  /// over, and the periodic requests may run. Returns whether a flag
  /// changed; the caller notifies.
  bool _noteAnswered() {
    if (_disposed) return false;
    _keepAliveFailures = 0;
    _startKeepAlive();
    if (!_deviceOffline && !_needsPassword && !_lockedOut) return false;
    _deviceOffline = false;
    _needsPassword = false;
    _clearLockout();
    return true;
  }

  Future<void> _refreshSettingsInBackground() async {
    final client = _apiClient;
    if (client == null) return;
    try {
      final results = await Future.wait([
        client.getProcessingSettings().timeout(const Duration(seconds: 5)),
        client.getPaletteSettings().timeout(const Duration(seconds: 5)),
        client.getConfig().timeout(const Duration(seconds: 5)),
      ]);
      // A client since replaced (new password, other frame) may have read
      // settings that no longer hold.
      if (!_isCurrent(client)) return;
      _processingSettings = results[0] as Map<String, dynamic>;
      _paletteSettings = results[1] as Map<String, dynamic>;
      _config = results[2] as DeviceConfig;
      _noteAnswered();
      notifyListeners();
    } catch (e) {
      // A 401 or 429 is reported like the keep-alive's; anything else is
      // ignored and the cached values remain.
      // A refusal of a client since replaced by setPassword says nothing
      // about the new password.
      if (!_isCurrent(client) || e is! ApiException) return;
      if (e.isUnauthorized) {
        if (!_needsPassword && !_changingPassword) {
          _markNeedsPassword();
          notifyListeners();
        }
      } else if (e.isRateLimited) {
        _markLockedOut(e.retryAfter);
        notifyListeners();
      }
    }
  }

  Future<void> refreshAll() async {
    final client = _apiClient;
    if (client == null) return;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _systemInfo = await _apiClient!.getSystemInfo();
      if (identical(client, _apiClient)) _noteAnswered();
      // Update device name from system info
      if (_systemInfo != null && _device != null) {
        // copyWith, so the stored password survives the rename.
        _device = _device!.copyWith(
          name: _systemInfo!.deviceName.isNotEmpty
              ? _systemInfo!.deviceName
              : _device!.host,
        );
      }
      await Future.wait([
        _refreshBattery(),
        _refreshConfig(),
        _refreshAlbums(),
        _refreshCurrentImage(),
      ]);
    } catch (e) {
      // Same as the keep-alive path: raise it now, so the gallery goes back
      // to the device list to ask, rather than sitting on a failing screen
      // until the next keep-alive notices. Not if the client has been
      // replaced meanwhile (new password, other frame): the 401 is stale.
      if (e is ApiException && identical(client, _apiClient)) {
        if (e.isUnauthorized && !_changingPassword) {
          _markNeedsPassword();
        } else if (e.isRateLimited) {
          _markLockedOut(e.retryAfter);
        }
      }
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshBattery() async {
    if (_apiClient == null) return;
    try {
      await _refreshBattery();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> refreshConfig() async {
    if (_apiClient == null) return;
    try {
      await _refreshConfig();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> refreshAlbums() async {
    if (_apiClient == null) return;
    try {
      await _refreshAlbums();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> setAlbumEnabled(String name, bool enabled) async {
    if (_apiClient == null) return;
    final index = _albums.indexWhere((a) => a.name == name);
    if (index < 0) return;
    final previous = _albums[index];
    _albums[index] = Album(name: previous.name, enabled: enabled);
    notifyListeners();
    try {
      await _apiClient!.setAlbumEnabled(name, enabled);
      _saveCachedAlbums();
    } catch (e) {
      _albums[index] = previous;
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateConfig(Map<String, dynamic> updates) async {
    if (_apiClient == null) return;
    try {
      await _apiClient!.updateConfig(updates);
      await _refreshConfig();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> rotateImage() async {
    if (_apiClient == null) return;
    try {
      await _apiClient!.rotate();
      await _refreshCurrentImage();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _refreshBattery() async {
    try {
      _batteryInfo = await _apiClient!.getBattery();
    } catch (_) {
      // Battery endpoint may not be available on all devices
    }
  }

  Future<void> _refreshConfig() async {
    _config = await _apiClient!.getConfig();
  }

  Future<void> _refreshAlbums() async {
    // Load cached albums first for instant display
    if (_albums.isEmpty) {
      await _loadCachedAlbums();
    }
    _albums = await _apiClient!.getAlbums();
    _saveCachedAlbums();
  }

  String get _cachePrefix => 'device_${_device?.host ?? "unknown"}';

  Future<void> _loadCachedAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getStringList('${_cachePrefix}_albums');
      if (json != null && json.isNotEmpty) {
        _albums = json
            .map((s) => Album.fromJson(jsonDecode(s) as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveCachedAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = _albums
          .map((a) => jsonEncode({'name': a.name, 'enabled': a.enabled}))
          .toList();
      await prefs.setStringList('${_cachePrefix}_albums', json);
    } catch (_) {}
  }

  /// Load cached images for an album (per-device).
  Future<List<PhotoInfo>> loadCachedImages(String album) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getStringList('${_cachePrefix}_images_$album');
      if (json != null) {
        return json
            .map(
              (s) => PhotoInfo.fromJson(jsonDecode(s) as Map<String, dynamic>),
            )
            .toList();
      }
    } catch (_) {}
    return [];
  }

  /// Save images list to cache for an album (per-device).
  Future<void> saveCachedImages(String album, List<PhotoInfo> images) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = images
          .map(
            (i) => jsonEncode({
              'filename': i.filename,
              'album': i.album,
              'thumbnail': i.thumbnail,
            }),
          )
          .toList();
      await prefs.setStringList('${_cachePrefix}_images_$album', json);
    } catch (_) {}
  }

  Future<void> _refreshCurrentImage() async {
    try {
      _currentImage = await _apiClient!.getCurrentImage();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _stopKeepAlive();
    _apiClient?.dispose();
    super.dispose();
  }
}
