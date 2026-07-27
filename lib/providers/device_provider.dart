import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/album.dart';
import '../models/config.dart';
import '../models/device.dart';
import '../services/api_client.dart';

class DeviceProvider extends ChangeNotifier {
  Device? _device;
  ApiClient? _apiClient;
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
  int _keepAliveFailures = 0;
  bool _deviceOffline = false;

  // Cached device settings (refreshed every 5 min)
  Map<String, dynamic>? _processingSettings;
  Map<String, dynamic>? _paletteSettings;

  bool get deviceOffline => _deviceOffline;
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
  Future<void> connectToDevice(Device device) async {
    _stopKeepAlive();
    _apiClient?.dispose();
    _device = device;

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

    _apiClient = ApiClient(baseUrl: 'http://$apiHost:${device.port}');
    _error = null;
    _keepAliveFailures = 0;
    _deviceOffline = false;
    _startKeepAlive();
    notifyListeners();
  }

  // ChangeNotifier doesn't have mounted, so we track disposal
  bool _disposed = false;
  bool get mounted => !_disposed;

  void connectToHost(String host, {int port = 80}) {
    connectToDevice(Device(name: host, host: host, port: port));
  }

  void disconnect() {
    _stopKeepAlive();
    _keepAliveFailures = 0;
    _deviceOffline = false;
    _apiClient?.dispose();
    _apiClient = null;
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

  void _startKeepAlive() {
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
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
  }

  Future<void> _sendKeepAlive() async {
    if (_apiClient == null) return;
    try {
      await _apiClient!.keepAlive().timeout(const Duration(seconds: 5));
      _keepAliveFailures = 0;
      if (_deviceOffline) {
        _deviceOffline = false;
        notifyListeners();
      }
    } catch (_) {
      _keepAliveFailures++;
      if (_keepAliveFailures >= 2 && !_deviceOffline) {
        _deviceOffline = true;
        notifyListeners();
      }
    }
  }

  Future<void> _refreshSettingsInBackground() async {
    if (_apiClient == null) return;
    try {
      final results = await Future.wait([
        _apiClient!.getProcessingSettings().timeout(const Duration(seconds: 5)),
        _apiClient!.getPaletteSettings().timeout(const Duration(seconds: 5)),
        _apiClient!.getConfig().timeout(const Duration(seconds: 5)),
      ]);
      _processingSettings = results[0] as Map<String, dynamic>;
      _paletteSettings = results[1] as Map<String, dynamic>;
      _config = DeviceConfig.fromJson(results[2] as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {
      // Silently ignore — cached values remain
    }
  }

  Future<void> refreshAll() async {
    if (_apiClient == null) return;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _systemInfo = await _apiClient!.getSystemInfo();
      // Update device name from system info
      if (_systemInfo != null && _device != null) {
        _device = Device(
          name: _systemInfo!.deviceName.isNotEmpty
              ? _systemInfo!.deviceName
              : _device!.host,
          host: _device!.host,
          port: _device!.port,
        );
      }
      await Future.wait([
        _refreshBattery(),
        _refreshConfig(),
        _refreshAlbums(),
        _refreshCurrentImage(),
      ]);
    } catch (e) {
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
