import '../services/cron.dart';

class DeviceConfig {
  // General
  final String deviceName;
  final String wifiSsid;
  final String displayOrientation;
  final int displayRotationDeg;
  final String timezone;
  final String ntpServer;

  // Advanced network settings (#43). Old firmware doesn't have these keys;
  // supportsStaticIp gates the UI so old devices render as before.
  final bool supportsStaticIp;
  final String ipMode; // "dhcp" or "static"
  final String staticIp;
  final String staticNetmask;
  final String staticGateway;
  final String dnsServer;

  // Auto Rotate
  final bool autoRotate;
  final List<String>
  rotateCron; // 3-field cron rules: "minute hour day-of-week"
  // Whether the device firmware understands rotate_cron. Old firmware only has
  // rotate_interval, so it silently ignores cron rules it can't express.
  final bool supportsCron;
  final String rotationMode; // "storage" or "url"
  final String sdRotationMode; // "sequential" or "random"
  final String imageUrl;
  final bool saveDownloadedImages;
  final String accessToken;
  final String httpHeaderKey;
  final String httpHeaderValue;

  // Sleep
  final bool sleepScheduleEnabled;
  final int sleepScheduleStart; // minutes from midnight
  final int sleepScheduleEnd;

  // Power
  final bool deepSleepEnabled;

  // Home Assistant
  final String haUrl;

  // AI
  final String openaiApiKey;
  final String googleApiKey;

  const DeviceConfig({
    required this.deviceName,
    required this.wifiSsid,
    required this.displayOrientation,
    required this.displayRotationDeg,
    required this.timezone,
    required this.ntpServer,
    this.supportsStaticIp = false,
    this.ipMode = 'dhcp',
    this.staticIp = '',
    this.staticNetmask = '255.255.255.0',
    this.staticGateway = '',
    this.dnsServer = '',
    required this.autoRotate,
    required this.rotateCron,
    this.supportsCron = true,
    required this.rotationMode,
    required this.sdRotationMode,
    required this.imageUrl,
    required this.saveDownloadedImages,
    required this.accessToken,
    required this.httpHeaderKey,
    required this.httpHeaderValue,
    required this.sleepScheduleEnabled,
    required this.sleepScheduleStart,
    required this.sleepScheduleEnd,
    required this.deepSleepEnabled,
    required this.haUrl,
    required this.openaiApiKey,
    required this.googleApiKey,
  });

  factory DeviceConfig.fromJson(Map<String, dynamic> json) {
    return DeviceConfig(
      deviceName: json['device_name'] as String? ?? '',
      wifiSsid: json['wifi_ssid'] as String? ?? '',
      displayOrientation: json['display_orientation'] as String? ?? 'landscape',
      displayRotationDeg: (json['display_rotation_deg'] as num?)?.toInt() ?? 0,
      timezone: json['timezone'] as String? ?? '',
      ntpServer: json['ntp_server'] as String? ?? '',
      // Old firmware has no static IP / DNS support and no ip_mode key.
      supportsStaticIp: json.containsKey('ip_mode'),
      ipMode: json['ip_mode'] as String? ?? 'dhcp',
      staticIp: json['static_ip'] as String? ?? '',
      staticNetmask: (json['static_netmask'] as String?)?.isNotEmpty == true
          ? json['static_netmask'] as String
          : '255.255.255.0',
      staticGateway: json['static_gateway'] as String? ?? '',
      dnsServer: json['dns_server'] as String? ?? '',
      autoRotate: json['auto_rotate'] as bool? ?? false,
      // Prefer rotate_cron; fall back to a legacy rotate_interval (older
      // firmware) so the schedule still shows correctly, else the default.
      rotateCron:
          (json['rotate_cron'] as List?)?.map((e) => e.toString()).toList() ??
          (json['rotate_interval'] is num
              ? [intervalToCron((json['rotate_interval'] as num).toInt())]
              : const ['0 */12 *']),
      // Old firmware reports rotate_interval and no rotate_cron.
      supportsCron: json.containsKey('rotate_cron'),
      rotationMode: json['rotation_mode'] as String? ?? 'storage',
      sdRotationMode: json['sd_rotation_mode'] as String? ?? 'sequential',
      imageUrl: json['image_url'] as String? ?? '',
      saveDownloadedImages: json['save_downloaded_images'] as bool? ?? false,
      accessToken: json['access_token'] as String? ?? '',
      httpHeaderKey: json['http_header_key'] as String? ?? '',
      httpHeaderValue: json['http_header_value'] as String? ?? '',
      sleepScheduleEnabled: json['sleep_schedule_enabled'] as bool? ?? false,
      sleepScheduleStart: (json['sleep_schedule_start'] as num?)?.toInt() ?? 0,
      sleepScheduleEnd: (json['sleep_schedule_end'] as num?)?.toInt() ?? 0,
      deepSleepEnabled: json['deep_sleep_enabled'] as bool? ?? false,
      haUrl: json['ha_url'] as String? ?? '',
      openaiApiKey: json['openai_api_key'] as String? ?? '',
      googleApiKey: json['google_api_key'] as String? ?? '',
    );
  }
}
