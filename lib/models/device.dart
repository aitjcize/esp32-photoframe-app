class Device {
  final String name;
  final String host;
  final int port;

  const Device({required this.name, required this.host, this.port = 80});

  String get baseUrl => 'http://$host:$port';

  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port};

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int? ?? 80,
  );

  @override
  bool operator ==(Object other) =>
      other is Device && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

class SystemInfo {
  final String deviceName;
  final String deviceId;
  final String firmwareVersion;
  final String board;
  final int displayWidth;
  final int displayHeight;
  final int storageTotal;
  final int storageUsed;

  /// Display color model: "gc16" (16-level grayscale), "spectra6" (6-color), or
  /// "" for legacy firmware (treated as color).
  final String displayType;

  const SystemInfo({
    required this.deviceName,
    required this.deviceId,
    required this.firmwareVersion,
    required this.board,
    required this.displayWidth,
    required this.displayHeight,
    required this.storageTotal,
    required this.storageUsed,
    this.displayType = '',
  });

  double get storageUsedPercent =>
      storageTotal > 0 ? storageUsed / storageTotal : 0;

  /// True for grayscale (GC16 and any future gc*) panels.
  bool get isGrayscale => displayType.startsWith('gc');

  factory SystemInfo.fromJson(Map<String, dynamic> json) {
    return SystemInfo(
      deviceName: json['device_name'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      firmwareVersion: json['version'] as String? ?? '',
      board: json['board_name'] as String? ?? '',
      displayWidth: (json['width'] as num?)?.toInt() ?? 0,
      displayHeight: (json['height'] as num?)?.toInt() ?? 0,
      storageTotal: (json['storage_total'] as num?)?.toInt() ?? 0,
      storageUsed: (json['storage_used'] as num?)?.toInt() ?? 0,
      displayType: json['display_type'] as String? ?? '',
    );
  }
}

class BatteryInfo {
  final int voltage; // millivolts
  final int level;
  final bool charging;
  final bool usbConnected;
  final bool batteryConnected;

  const BatteryInfo({
    required this.voltage,
    required this.level,
    required this.charging,
    required this.usbConnected,
    required this.batteryConnected,
  });

  factory BatteryInfo.fromJson(Map<String, dynamic> json) {
    return BatteryInfo(
      voltage: (json['battery_voltage'] as num?)?.toInt() ?? 0,
      level: (json['battery_level'] as num?)?.toInt() ?? 0,
      charging: json['charging'] as bool? ?? false,
      usbConnected: json['usb_connected'] as bool? ?? false,
      batteryConnected: json['battery_connected'] as bool? ?? false,
    );
  }
}

class SensorInfo {
  final double temperature;
  final double humidity;

  const SensorInfo({required this.temperature, required this.humidity});

  factory SensorInfo.fromJson(Map<String, dynamic> json) {
    return SensorInfo(
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
      humidity: (json['humidity'] as num?)?.toDouble() ?? 0,
    );
  }
}
