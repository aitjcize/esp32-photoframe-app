import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/album.dart';
import '../models/config.dart';
import '../models/device.dart';

/// The frame ignores the username; the password is the whole credential.
const String _authUsername = 'photoframe';

/// Basic-auth header for a frame whose HTTP API is password-protected
/// (esp32-photoframe #130). Empty when [password] is empty: the firmware
/// leaves the API open by default and those frames must keep working.
Map<String, String> frameAuthHeaders(String password) => password.isEmpty
    ? const {}
    : {
        'authorization':
            'Basic ${base64Encode(utf8.encode('$_authUsername:$password'))}',
      };

/// Wraps an [http.Client] and attaches the frame's password to everything that
/// passes through it. Doing it here rather than at each call site means a
/// request added later cannot silently go out unauthenticated -- [ApiClient]
/// already makes more than twenty, including multipart uploads that build
/// their request object by hand.
class _AuthenticatedClient extends http.BaseClient {
  _AuthenticatedClient(this._inner, this._headers);

  final http.Client _inner;
  final Map<String, String> _headers;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class ApiClient {
  final String baseUrl;

  /// Password for the frame's own HTTP API. Empty means the frame is open.
  final String password;

  final http.Client _client;

  ApiClient({required this.baseUrl, this.password = '', http.Client? client})
    : _client = password.isEmpty
          ? (client ?? http.Client())
          : _AuthenticatedClient(
              client ?? http.Client(),
              frameAuthHeaders(password),
            );

  /// Headers for fetching a device image from outside this client: the image
  /// widgets are handed [getImageUrl] and do their own fetching, so they never
  /// pass through the wrapper above.
  Map<String, String> get imageHeaders => frameAuthHeaders(password);

  void dispose() {
    _client.close();
  }

  Uri _uri(String path, [Map<String, String>? queryParams]) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: queryParams);
  }

  // --- System ---

  Future<SystemInfo> getSystemInfo() async {
    final response = await _client.get(_uri('/api/system-info'));
    _checkResponse(response);
    return SystemInfo.fromJson(jsonDecode(response.body));
  }

  Future<BatteryInfo> getBattery() async {
    final response = await _client.get(_uri('/api/battery'));
    _checkResponse(response);
    return BatteryInfo.fromJson(jsonDecode(response.body));
  }

  Future<SensorInfo> getSensor() async {
    final response = await _client.get(_uri('/api/sensor'));
    _checkResponse(response);
    return SensorInfo.fromJson(jsonDecode(response.body));
  }

  Future<void> sleep() async {
    final response = await _client.post(_uri('/api/sleep'));
    _checkResponse(response);
  }

  Future<void> keepAlive() async {
    final response = await _client.post(_uri('/api/keep_alive'));
    _checkResponse(response);
  }

  // --- Config ---

  Future<DeviceConfig> getConfig() async {
    final response = await _client.get(_uri('/api/config'));
    _checkResponse(response);
    return DeviceConfig.fromJson(jsonDecode(response.body));
  }

  Future<void> updateConfig(Map<String, dynamic> updates) async {
    final response = await _client.patch(
      _uri('/api/config'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(updates),
    );
    _checkResponse(response);
  }

  // --- Display ---

  Future<void> displayImage(
    Uint8List imageBytes,
    String filename, {
    Uint8List? thumbnailBytes,
    String? thumbnailFilename,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/display-image'));
    request.files.add(
      http.MultipartFile.fromBytes('image', imageBytes, filename: filename),
    );
    if (thumbnailBytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'thumbnail',
          thumbnailBytes,
          filename: thumbnailFilename ?? 'thumb_$filename',
        ),
      );
    }
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _checkResponse(response);
  }

  Future<void> displayByPath(String filepath) async {
    final response = await _client.post(
      _uri('/api/display'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'filepath': filepath}),
    );
    _checkResponse(response);
  }

  Future<String> getCurrentImage() async {
    final response = await _client.get(_uri('/api/current_image'));
    _checkResponse(response);
    final data = jsonDecode(response.body);
    return data['filepath'] as String? ?? '';
  }

  Future<void> rotate() async {
    final response = await _client.post(_uri('/api/rotate'));
    _checkResponse(response);
  }

  // --- Albums ---

  Future<List<Album>> getAlbums() async {
    final response = await _client.get(_uri('/api/albums'));
    _checkResponse(response);
    final List<dynamic> data = jsonDecode(response.body);
    return data.map((e) => Album.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> createAlbum(String name) async {
    final response = await _client.post(
      _uri('/api/albums'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );
    _checkResponse(response);
  }

  Future<void> deleteAlbum(String name) async {
    final response = await _client.delete(_uri('/api/albums', {'name': name}));
    _checkResponse(response);
  }

  Future<void> setAlbumEnabled(String name, bool enabled) async {
    final response = await _client.put(
      _uri('/api/albums/enabled', {'name': name}),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'enabled': enabled}),
    );
    _checkResponse(response);
  }

  // --- Images ---

  Future<List<PhotoInfo>> getImages(String album) async {
    final response = await _client.get(_uri('/api/images', {'album': album}));
    _checkResponse(response);
    final List<dynamic> data = jsonDecode(response.body);
    return data
        .map((e) => PhotoInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  String getImageUrl(String filepath) {
    return _uri('/api/image', {'filepath': filepath}).toString();
  }

  Future<void> uploadImage(
    String album,
    Uint8List imageBytes,
    String filename, {
    Uint8List? thumbnailBytes,
    String? thumbnailFilename,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _uri('/api/upload', {'album': album}),
    );
    request.files.add(
      http.MultipartFile.fromBytes('image', imageBytes, filename: filename),
    );
    if (thumbnailBytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'thumbnail',
          thumbnailBytes,
          filename: thumbnailFilename ?? 'thumb_$filename',
        ),
      );
    }
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _checkResponse(response);
  }

  Future<void> deleteImage(String filepath) async {
    final response = await _client.post(
      _uri('/api/delete'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'filepath': filepath}),
    );
    _checkResponse(response);
  }

  // --- OTA ---

  Future<Map<String, dynamic>> getOtaStatus() async {
    final response = await _client.get(_uri('/api/ota/status'));
    _checkResponse(response);
    return jsonDecode(response.body);
  }

  Future<void> checkOtaUpdate() async {
    final response = await _client.post(_uri('/api/ota/check'));
    _checkResponse(response);
  }

  Future<void> startOtaUpdate() async {
    final response = await _client.post(_uri('/api/ota/update'));
    _checkResponse(response);
  }

  // --- Processing Settings ---

  Future<Map<String, dynamic>> getProcessingSettings() async {
    final response = await _client.get(_uri('/api/settings/processing'));
    _checkResponse(response);
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getPaletteSettings() async {
    final response = await _client.get(_uri('/api/settings/palette'));
    _checkResponse(response);
    return jsonDecode(response.body);
  }

  // --- Config Backup/Restore ---

  Future<Map<String, dynamic>> getRawConfig() async {
    final response = await _client.get(_uri('/api/config'));
    _checkResponse(response);
    return jsonDecode(response.body);
  }

  Future<void> setRawConfig(Map<String, dynamic> config) async {
    final response = await _client.post(
      _uri('/api/config'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config),
    );
    _checkResponse(response);
  }

  // --- Factory Reset ---

  Future<void> factoryReset() async {
    final response = await _client.post(_uri('/api/factory-reset'));
    _checkResponse(response);
  }

  // --- Helpers ---

  void _checkResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        response.body,
        retryAfter: parseRetryAfter(response.headers['retry-after']),
      );
    }
  }
}

/// A Retry-After given in seconds, as the frame's lockout sends it. The
/// HTTP-date form is never sent by the frame and is not parsed.
Duration? parseRetryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}

class ApiException implements Exception {
  final int statusCode;
  final String body;

  /// How long the frame asked us to wait, from its Retry-After header.
  final Duration? retryAfter;

  const ApiException(this.statusCode, this.body, {this.retryAfter});

  /// The frame demands a password (or rejected the one we sent).
  bool get isUnauthorized => statusCode == 401;

  /// The frame is refusing this client for a while after too many wrong
  /// passwords (esp32-photoframe #130).
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => 'ApiException($statusCode): $body';
}
