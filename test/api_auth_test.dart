import 'dart:convert';
import 'dart:typed_data';

import 'package:esp32_photoframe_app/models/device.dart';
import 'package:esp32_photoframe_app/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The credential the firmware expects: it ignores the username, so the
/// password is the whole secret (esp32-photoframe #130).
String expectedHeader(String password) =>
    'Basic ${base64Encode(utf8.encode('photoframe:$password'))}';

void main() {
  group('ApiClient auth', () {
    test('attaches Basic auth to a plain request', () async {
      String? seen;
      final client = ApiClient(
        baseUrl: 'http://frame.local',
        password: 'hunter2',
        client: MockClient((request) async {
          seen = request.headers['authorization'];
          return http.Response('{"filepath":"a/b.jpg"}', 200);
        }),
      );
      await client.getCurrentImage();
      expect(seen, expectedHeader('hunter2'));
    });

    test('attaches Basic auth to a multipart upload', () async {
      String? seen;
      final client = ApiClient(
        baseUrl: 'http://frame.local',
        password: 'hunter2',
        client: MockClient((request) async {
          seen = request.headers['authorization'];
          return http.Response('{}', 200);
        }),
      );
      await client.uploadImage(
        'album',
        Uint8List.fromList([1, 2, 3]),
        'photo.jpg',
      );
      expect(seen, expectedHeader('hunter2'));
    });

    test('sends nothing when the frame has no password', () async {
      String? seen;
      final client = ApiClient(
        baseUrl: 'http://frame.local',
        client: MockClient((request) async {
          seen = request.headers['authorization'];
          return http.Response('{"filepath":""}', 200);
        }),
      );
      await client.getCurrentImage();
      expect(seen, isNull);
    });

    test('reports a 401 as an authentication failure', () async {
      final client = ApiClient(
        baseUrl: 'http://frame.local',
        client: MockClient(
          (request) async =>
              http.Response('{"error":"authentication required"}', 401),
        ),
      );
      await expectLater(
        client.getCurrentImage(),
        throwsA(
          isA<ApiException>().having((e) => e.isUnauthorized, 'is401', isTrue),
        ),
      );
    });

    test('image headers carry the credential for the image widgets', () {
      final client = ApiClient(baseUrl: 'http://frame.local', password: 'pw');
      expect(client.imageHeaders['authorization'], expectedHeader('pw'));
      expect(ApiClient(baseUrl: 'http://frame.local').imageHeaders, isEmpty);
    });
  });

  group('Device persistence', () {
    test('round-trips the password', () {
      const device = Device(name: 'Study', host: 'frame.local', password: 'pw');
      expect(Device.fromJson(device.toJson()).password, 'pw');
    });

    test('writes no password entry when the frame is open', () {
      const device = Device(name: 'Study', host: 'frame.local');
      expect(device.toJson().containsKey('password'), isFalse);
      expect(Device.fromJson(device.toJson()).password, '');
    });

    test('copyWith keeps the password across a rename', () {
      const device = Device(
        name: 'frame.local',
        host: 'frame.local',
        password: 'pw',
      );
      expect(device.copyWith(name: 'Study').password, 'pw');
    });
  });
}
