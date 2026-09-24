import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/config.dart';
import '../providers/device_provider.dart';
import '../services/cron.dart';
import 'rotation_schedule_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DeviceProvider>();
    final config = provider.config;
    final sysInfo = provider.systemInfo;
    final battery = provider.batteryInfo;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        bottom: provider.needsPassword
            ? _PasswordBanner(
                onEnter: () => _editFramePassword(context, provider),
              )
            : null,
      ),
      body: config == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // === General ===
                _SectionHeader('General'),
                ListTile(
                  title: const Text('Device Name'),
                  subtitle: Text(config.deviceName),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(
                    context,
                    provider,
                    'Device Name',
                    config.deviceName,
                    'device_name',
                  ),
                ),
                ListTile(
                  title: const Text('WiFi SSID'),
                  subtitle: Text(
                    config.wifiSsid.isEmpty ? 'Not set' : config.wifiSsid,
                  ),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editWifi(context, provider),
                ),
                ListTile(
                  title: const Text('Orientation'),
                  subtitle: Text(config.displayOrientation),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPicker(
                    context,
                    provider,
                    'Display Orientation',
                    'display_orientation',
                    {'landscape': 'Landscape', 'portrait': 'Portrait'},
                  ),
                ),
                ListTile(
                  title: const Text('Display Rotation'),
                  subtitle: Text('${config.displayRotationDeg}\u00B0'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPicker(
                    context,
                    provider,
                    'Display Rotation',
                    'display_rotation_deg',
                    {
                      0: '0\u00B0',
                      90: '90\u00B0',
                      180: '180\u00B0',
                      270: '270\u00B0',
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Timezone'),
                  subtitle: Text(
                    config.timezone.isEmpty ? 'Not set' : config.timezone,
                  ),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(
                    context,
                    provider,
                    'Timezone',
                    config.timezone,
                    'timezone',
                  ),
                ),
                // Advanced network settings (#43), collapsed by default. The
                // static IP / DNS entries render only when the firmware
                // reports ip_mode; the NTP server exists on all firmware. The
                // frame's password protection (#130) lives here too, next to
                // the other connection details.
                ExpansionTile(
                  title: const Text('Advanced Network'),
                  shape: const Border(),
                  children: [
                    ListTile(
                      title: const Text('NTP Server'),
                      subtitle: Text(
                        config.ntpServer.isEmpty ? 'Not set' : config.ntpServer,
                      ),
                      trailing: const Icon(Icons.edit),
                      onTap: () => _editText(
                        context,
                        provider,
                        'NTP Server',
                        config.ntpServer,
                        'ntp_server',
                      ),
                    ),
                    if (config.supportsStaticIp) ...[
                      ListTile(
                        title: const Text('IP Configuration'),
                        subtitle: Text(
                          config.ipMode == 'static'
                              ? 'Static IP'
                              : 'Automatic (DHCP)',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showPicker(
                          context,
                          provider,
                          'IP Configuration',
                          'ip_mode',
                          {'dhcp': 'Automatic (DHCP)', 'static': 'Static IP'},
                        ),
                      ),
                      if (config.ipMode == 'static') ...[
                        ListTile(
                          title: const Text('IP Address'),
                          subtitle: Text(
                            config.staticIp.isEmpty
                                ? 'Not set'
                                : config.staticIp,
                          ),
                          trailing: const Icon(Icons.edit),
                          onTap: () => _editText(
                            context,
                            provider,
                            'IP Address',
                            config.staticIp,
                            'static_ip',
                          ),
                        ),
                        ListTile(
                          title: const Text('Netmask'),
                          subtitle: Text(config.staticNetmask),
                          trailing: const Icon(Icons.edit),
                          onTap: () => _editText(
                            context,
                            provider,
                            'Netmask',
                            config.staticNetmask,
                            'static_netmask',
                          ),
                        ),
                        ListTile(
                          title: const Text('Gateway'),
                          subtitle: Text(
                            config.staticGateway.isEmpty
                                ? 'Not set'
                                : config.staticGateway,
                          ),
                          trailing: const Icon(Icons.edit),
                          onTap: () => _editText(
                            context,
                            provider,
                            'Gateway',
                            config.staticGateway,
                            'static_gateway',
                          ),
                        ),
                      ],
                      ListTile(
                        title: const Text('DNS Server'),
                        subtitle: Text(
                          config.dnsServer.isEmpty
                              ? (config.ipMode == 'static'
                                    ? 'Gateway (default)'
                                    : 'Automatic (DHCP)')
                              : config.dnsServer,
                        ),
                        trailing: const Icon(Icons.edit),
                        onTap: () => _editText(
                          context,
                          provider,
                          'DNS Server',
                          config.dnsServer,
                          'dns_server',
                        ),
                      ),
                    ],
                    // Only firmware that has the setting reports it.
                    if (config.httpAuthEnabled != null)
                      ListTile(
                        title: const Text('Password protection'),
                        subtitle: Text(
                          '${config.httpAuthEnabled! ? 'On' : 'Off'} \u2022 '
                          '${provider.hasPassword ? 'password saved in this app' : 'no password saved in this app'}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _passwordProtection(
                          context,
                          provider,
                          config.httpAuthEnabled!,
                        ),
                      ),
                  ],
                ),

                // === Auto Rotate ===
                _SectionHeader('Auto Rotate'),
                SwitchListTile(
                  title: const Text('Auto Rotate'),
                  subtitle: const Text('Automatically cycle through images'),
                  value: config.autoRotate,
                  onChanged: (v) => provider.updateConfig({'auto_rotate': v}),
                ),
                ListTile(
                  title: const Text('Rotation Schedule'),
                  subtitle: Text(summarizeSchedule(config.rotateCron)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editSchedule(context, provider, config),
                ),
                ListTile(
                  title: const Text('Source'),
                  subtitle: Text(
                    config.rotationMode == 'url' ? 'URL' : 'Storage',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPicker(
                    context,
                    provider,
                    'Rotation Source',
                    'rotation_mode',
                    {'storage': 'Storage', 'url': 'URL'},
                  ),
                ),
                if (config.rotationMode == 'storage')
                  ListTile(
                    title: const Text('Storage Rotation Order'),
                    subtitle: Text(config.sdRotationMode),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showPicker(
                      context,
                      provider,
                      'Storage Rotation Order',
                      'sd_rotation_mode',
                      {'sequential': 'Sequential', 'random': 'Random'},
                    ),
                  ),
                if (config.rotationMode == 'url') ...[
                  ListTile(
                    title: const Text('Image URL'),
                    subtitle: Text(
                      config.imageUrl.isEmpty ? 'Not set' : config.imageUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _editText(
                      context,
                      provider,
                      'Image URL',
                      config.imageUrl,
                      'image_url',
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Save Downloaded Images'),
                    value: config.saveDownloadedImages,
                    onChanged: (v) =>
                        provider.updateConfig({'save_downloaded_images': v}),
                  ),
                  ListTile(
                    title: const Text('Access Token'),
                    subtitle: Text(
                      config.accessToken.isEmpty ? 'Not set' : '\u2022' * 8,
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _editText(
                      context,
                      provider,
                      'Access Token',
                      config.accessToken,
                      'access_token',
                    ),
                  ),
                  ListTile(
                    title: const Text('Custom Header'),
                    subtitle: Text(
                      config.httpHeaderKey.isEmpty
                          ? 'Not set'
                          : '${config.httpHeaderKey}: ${config.httpHeaderValue}',
                    ),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _editHeader(context, provider),
                  ),
                ],

                // === Sleep Schedule (legacy quiet-hours, pre-cron firmware
                // only; cron firmware bounds the active hours in the rules) ===
                if (!config.supportsCron) ...[
                  _SectionHeader('Sleep Schedule'),
                  SwitchListTile(
                    title: const Text('Sleep Schedule'),
                    subtitle: config.sleepScheduleEnabled
                        ? Text(
                            '${_formatMinutes(config.sleepScheduleStart)} \u2013 ${_formatMinutes(config.sleepScheduleEnd)}',
                          )
                        : const Text('Disabled'),
                    value: config.sleepScheduleEnabled,
                    onChanged: (v) =>
                        provider.updateConfig({'sleep_schedule_enabled': v}),
                  ),
                  if (config.sleepScheduleEnabled) ...[
                    ListTile(
                      title: const Text('Sleep From'),
                      subtitle: Text(_formatMinutes(config.sleepScheduleStart)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickTime(
                        context,
                        provider,
                        'sleep_schedule_start',
                        config.sleepScheduleStart,
                      ),
                    ),
                    ListTile(
                      title: const Text('Sleep Until'),
                      subtitle: Text(_formatMinutes(config.sleepScheduleEnd)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickTime(
                        context,
                        provider,
                        'sleep_schedule_end',
                        config.sleepScheduleEnd,
                      ),
                    ),
                  ],
                ],

                // === Power ===
                _SectionHeader('Power'),
                SwitchListTile(
                  title: const Text('Deep Sleep'),
                  subtitle: const Text(
                    'Sleep between rotations to save battery',
                  ),
                  value: config.deepSleepEnabled,
                  onChanged: (v) =>
                      provider.updateConfig({'deep_sleep_enabled': v}),
                ),

                // === Home Assistant ===
                _SectionHeader('Home Assistant'),
                ListTile(
                  title: const Text('Home Assistant URL'),
                  subtitle: Text(
                    config.haUrl.isEmpty ? 'Not set' : config.haUrl,
                  ),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(
                    context,
                    provider,
                    'Home Assistant URL',
                    config.haUrl,
                    'ha_url',
                  ),
                ),

                // === AI Generation ===
                _SectionHeader('AI Generation'),
                ListTile(
                  title: const Text('OpenAI API Key'),
                  subtitle: Text(
                    config.openaiApiKey.isEmpty ? 'Not set' : '\u2022' * 8,
                  ),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(
                    context,
                    provider,
                    'OpenAI API Key',
                    config.openaiApiKey,
                    'openai_api_key',
                  ),
                ),
                ListTile(
                  title: const Text('Google Gemini API Key'),
                  subtitle: Text(
                    config.googleApiKey.isEmpty ? 'Not set' : '\u2022' * 8,
                  ),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(
                    context,
                    provider,
                    'Google Gemini API Key',
                    config.googleApiKey,
                    'google_api_key',
                  ),
                ),

                // === Firmware Update ===
                _SectionHeader('Firmware Update'),
                _OtaSection(provider: provider),

                // === Device ===
                _SectionHeader('Device'),
                if (battery != null && battery.batteryConnected)
                  ListTile(
                    leading: Icon(
                      battery.charging
                          ? Icons.battery_charging_full
                          : battery.level > 75
                          ? Icons.battery_full
                          : battery.level > 50
                          ? Icons.battery_5_bar
                          : battery.level > 25
                          ? Icons.battery_3_bar
                          : Icons.battery_1_bar,
                      color: battery.level <= 20
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    title: Text('Battery ${battery.level}%'),
                    subtitle: Text(
                      '${(battery.voltage / 1000).toStringAsFixed(2)}V'
                      '${battery.charging ? ' \u2022 Charging' : ''}'
                      '${battery.usbConnected ? ' \u2022 USB' : ''}',
                    ),
                  ),
                if (sysInfo != null)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(sysInfo.board),
                    subtitle: Text(
                      'Firmware: ${sysInfo.firmwareVersion}\n'
                      'Display: ${sysInfo.displayWidth}\u00D7${sysInfo.displayHeight}\n'
                      'ID: ${sysInfo.deviceId}',
                    ),
                  ),
                ListTile(
                  title: const Text('Export Config'),
                  leading: const Icon(Icons.download),
                  onTap: () => _exportConfig(context, provider),
                ),
                ListTile(
                  title: const Text('Import Config'),
                  leading: const Icon(Icons.upload),
                  onTap: () => _importConfig(context, provider),
                ),
                ListTile(
                  title: const Text('Put Device to Sleep'),
                  leading: const Icon(Icons.bedtime),
                  onTap: () => _sleepDevice(context, provider),
                ),
                ListTile(
                  title: Text(
                    'Factory Reset',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  leading: Icon(
                    Icons.restore,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  onTap: () => _factoryReset(context, provider),
                ),
                const SizedBox(height: 24),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 1,
        onDestinationSelected: (index) {
          switch (index) {
            case 0:
              context.go('/gallery');
            case 1:
              break;
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library),
            label: 'Gallery',
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  Future<void> _editSchedule(
    BuildContext context,
    DeviceProvider provider,
    DeviceConfig config,
  ) async {
    // Quiet hours only apply on pre-cron firmware; cron schedules bound their
    // own active hours, so the preview isn't masked for them.
    final sleep = !config.supportsCron && config.sleepScheduleEnabled
        ? QuietHours(true, config.sleepScheduleStart, config.sleepScheduleEnd)
        : null;
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => RotationScheduleScreen(
          initial: config.rotateCron,
          sleep: sleep,
          supportsCron: config.supportsCron,
        ),
      ),
    );
    if (result == null) return;

    final legacyInterval = cronToInterval(result);
    // Old firmware predates rotate_cron: it only understands rotate_interval
    // and silently ignores a cron schedule. If the new schedule can't be
    // expressed as a simple every-day interval, saving it would do nothing on
    // the device — refuse instead of silently dropping the edit.
    if (!config.supportsCron && legacyInterval == null) {
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Schedule not supported'),
            content: const Text(
              "This frame's firmware only supports a simple repeating "
              'interval. Update the firmware to use day-of-week or '
              'specific-time schedules.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    final updates = <String, dynamic>{'rotate_cron': result};
    // Also send a derived rotate_interval (when the schedule is a simple
    // every-day interval) so older firmware that predates rotate_cron still
    // applies it; newer firmware ignores it in favour of rotate_cron.
    if (legacyInterval != null) {
      updates['rotate_interval'] = legacyInterval;
    }
    provider.updateConfig(updates);
  }

  String _formatMinutes(int minutesFromMidnight) {
    final h = minutesFromMidnight ~/ 60;
    final m = minutesFromMidnight % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  // Generic text editor dialog
  void _editText(
    BuildContext context,
    DeviceProvider provider,
    String title,
    String current,
    String key,
  ) {
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              provider.updateConfig({key: controller.text.trim()});
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Password protection on the frame's own HTTP API (esp32-photoframe #130):
  /// turn it on, change or remove the password on the frame, or just tell the
  /// app a password that was set elsewhere.
  void _passwordProtection(
    BuildContext context,
    DeviceProvider provider,
    bool enabled,
  ) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Password protection'),
        children: [
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(enabled ? 'Change password' : 'Turn on'),
            subtitle: const Text(
              'Set a new password on the frame. Requests without it are '
              'refused.',
            ),
            onTap: () => Navigator.pop(context, 'set'),
          ),
          if (enabled)
            ListTile(
              leading: const Icon(Icons.lock_open),
              title: const Text('Turn off'),
              subtitle: const Text('Remove the password from the frame.'),
              onTap: () => Navigator.pop(context, 'off'),
            ),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text("I already know the frame's password"),
            subtitle: const Text(
              'Save it in this app only. The frame is not changed.',
            ),
            onTap: () => Navigator.pop(context, 'known'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'known') {
      _editFramePassword(context, provider);
      return;
    }

    final turnOff = choice == 'off';
    final result = await showDialog<({String? warning})>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _FramePasswordDialog(provider: provider, turnOff: turnOff),
    );
    if (result == null || !context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          result.warning != null
              ? 'Check password protection'
              : turnOff
              ? 'Password protection is off'
              : 'Password protection is on',
        ),
        content: Text(
          [
            if (result.warning != null) result.warning!,
            turnOff
                ? 'The photoframe server and the Home Assistant integration '
                      'no longer need a password for this frame. You can '
                      'clear it in their settings.'
                : 'The photoframe server and the Home Assistant integration '
                      "keep their own copy of this frame's password. Enter "
                      'the new password in their settings too, or they will '
                      'stop syncing with this frame.',
          ].join('\n\n'),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// The password this app sends to the frame's own HTTP API
  /// (esp32-photoframe #130), for a frame whose password was set elsewhere.
  /// It is kept with the saved device, not pushed to the frame. The field is
  /// write-only: the frame never reports the password back, so there is
  /// nothing to prefill.
  void _editFramePassword(BuildContext context, DeviceProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Frame's password"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the password the frame already has, for example one set '
              'on its own web interface. Stored on this phone and sent with '
              'every request to this frame. The frame is not changed.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (provider.hasPassword)
            TextButton(
              onPressed: () {
                provider.setPassword('');
                Navigator.pop(context);
              },
              child: const Text('Clear'),
            ),
          FilledButton(
            onPressed: () {
              provider.setPassword(controller.text);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _editWifi(BuildContext context, DeviceProvider provider) {
    final ssidCtrl = TextEditingController(
      text: provider.config?.wifiSsid ?? '',
    );
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('WiFi Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ssidCtrl,
              decoration: const InputDecoration(
                labelText: 'SSID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password (leave empty to keep current)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final updates = <String, dynamic>{
                'wifi_ssid': ssidCtrl.text.trim(),
              };
              if (passCtrl.text.isNotEmpty) {
                updates['wifi_password'] = passCtrl.text;
              }
              provider.updateConfig(updates);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // Generic picker dialog
  void _showPicker<T>(
    BuildContext context,
    DeviceProvider provider,
    String title,
    String key,
    Map<T, String> options,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: options.entries.map((e) {
          return SimpleDialogOption(
            onPressed: () {
              provider.updateConfig({key: e.key});
              Navigator.pop(context);
            },
            child: Text(e.value),
          );
        }).toList(),
      ),
    );
  }

  void _pickTime(
    BuildContext context,
    DeviceProvider provider,
    String key,
    int currentMinutes,
  ) async {
    final initial = TimeOfDay(
      hour: currentMinutes ~/ 60,
      minute: currentMinutes % 60,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      provider.updateConfig({key: picked.hour * 60 + picked.minute});
    }
  }

  void _editHeader(BuildContext context, DeviceProvider provider) {
    final keyCtrl = TextEditingController(
      text: provider.config?.httpHeaderKey ?? '',
    );
    final valCtrl = TextEditingController(
      text: provider.config?.httpHeaderValue ?? '',
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom Header'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyCtrl,
              decoration: const InputDecoration(
                labelText: 'Header Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: valCtrl,
              decoration: const InputDecoration(
                labelText: 'Header Value',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              provider.updateConfig({
                'http_header_key': keyCtrl.text.trim(),
                'http_header_value': valCtrl.text.trim(),
              });
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _sleepDevice(BuildContext context, DeviceProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sleep'),
        content: const Text(
          'Put the device to sleep? It will be unreachable until it wakes up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sleep'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await provider.apiClient!.sleep();
      provider.disconnect();
      if (context.mounted) {
        context.go('/devices');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device is going to sleep')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  void _exportConfig(BuildContext context, DeviceProvider provider) async {
    try {
      final config = await provider.apiClient!.getRawConfig();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(config);
      await Clipboard.setData(ClipboardData(text: jsonStr));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Config copied to clipboard')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  void _importConfig(BuildContext context, DeviceProvider provider) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Config'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste a previously exported config JSON:'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '{"device_name": "...", ...}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (confirmed != true || controller.text.trim().isEmpty) return;

    try {
      final config = jsonDecode(controller.text.trim()) as Map<String, dynamic>;
      await provider.apiClient!.setRawConfig(config);
      await provider.refreshConfig();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Config imported successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  void _factoryReset(BuildContext context, DeviceProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Factory Reset'),
        content: const Text(
          'This will erase all settings and WiFi credentials. '
          'The device will restart in setup mode.\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await provider.apiClient!.factoryReset();
      provider.disconnect();
      if (context.mounted) {
        context.go('/devices');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device has been factory reset')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _OtaSection extends StatefulWidget {
  final DeviceProvider provider;
  const _OtaSection({required this.provider});

  @override
  State<_OtaSection> createState() => _OtaSectionState();
}

class _OtaSectionState extends State<_OtaSection> {
  String _state = 'idle';
  String _currentVersion = '';
  String _latestVersion = '';
  int _progress = 0;
  String _errorMessage = '';
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final data = await widget.provider.apiClient!.getOtaStatus();
      if (!mounted) return;
      setState(() {
        _state = data['state'] as String? ?? 'idle';
        _currentVersion = data['current_version'] as String? ?? '';
        _latestVersion = data['latest_version'] as String? ?? '';
        _progress = (data['progress_percent'] as num?)?.toInt() ?? 0;
        _errorMessage = data['error_message'] as String? ?? '';
      });

      // Stop polling on terminal states
      if (_polling &&
          (_state == 'idle' ||
              _state == 'update_available' ||
              _state == 'success' ||
              _state == 'error' ||
              _state == 'up_to_date')) {
        _polling = false;
      } else if (_polling) {
        // Keep polling
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted && _polling) _loadStatus();
        });
      }
    } catch (_) {}
  }

  void _startPolling() {
    _polling = true;
    _loadStatus();
  }

  Future<void> _checkForUpdate() async {
    try {
      await widget.provider.apiClient!.checkOtaUpdate();
      _startPolling();
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = 'error';
          _errorMessage = 'Failed to check: $e';
        });
      }
    }
  }

  Future<void> _installUpdate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Install Update'),
        content: Text(
          'Install firmware $_latestVersion? The device will reboot after installation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.provider.apiClient!.startOtaUpdate();
      _startPolling();
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = 'error';
          _errorMessage = 'Failed to install: $e';
        });
      }
    }
  }

  String get _statusMessage {
    switch (_state) {
      case 'checking':
        return 'Checking for updates...';
      case 'update_available':
        return 'Update available: $_latestVersion';
      case 'downloading':
        return 'Downloading firmware...';
      case 'installing':
        return 'Installing firmware...';
      case 'success':
        return 'Update successful! Device will reboot...';
      case 'error':
        return _errorMessage.isNotEmpty ? _errorMessage : 'Update failed';
      case 'up_to_date':
        return 'You\'re running the latest version.';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isChecking = _state == 'checking';
    final isInstalling = _state == 'downloading' || _state == 'installing';
    final updateAvailable = _state == 'update_available';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('Current Version'),
          subtitle: Text(
            _currentVersion.isEmpty ? 'Loading...' : _currentVersion,
          ),
        ),
        if (_latestVersion.isNotEmpty && _latestVersion != '-')
          ListTile(
            title: const Text('Latest Version'),
            subtitle: Text(_latestVersion),
            trailing: updateAvailable
                ? const Chip(
                    label: Text('New'),
                    backgroundColor: Colors.green,
                    labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                  )
                : null,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: isChecking || isInstalling ? null : _checkForUpdate,
                icon: isChecking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('Check'),
              ),
              if (updateAvailable) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: isInstalling ? null : _installUpdate,
                  icon: isInstalling
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.download),
                  label: const Text('Install'),
                ),
              ],
            ],
          ),
        ),
        if (isInstalling)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                LinearProgressIndicator(value: _progress / 100),
                const SizedBox(height: 4),
                Text(
                  '$_progress%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        if (_statusMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              _statusMessage,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _state == 'error'
                    ? Theme.of(context).colorScheme.error
                    : _state == 'success' || updateAvailable
                    ? Colors.green
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Sets, changes or removes the password on the frame itself, through
/// [DeviceProvider.changeFramePassword]. Stays open on failure so the error
/// can be read and the attempt repeated; pops with a record on success, whose
/// warning is set when the frame took the change but confirming it failed.
class _FramePasswordDialog extends StatefulWidget {
  const _FramePasswordDialog({required this.provider, required this.turnOff});

  final DeviceProvider provider;
  final bool turnOff;

  @override
  State<_FramePasswordDialog> createState() => _FramePasswordDialogState();
}

class _FramePasswordDialogState extends State<_FramePasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Why the typed passwords cannot be used, or null when they can.
  String? _validate() {
    final password = _password.text;
    if (password.isEmpty) return 'Enter a password.';
    if (password.contains('\u0000')) {
      return 'The password cannot contain a NUL character.';
    }
    final bytes = utf8.encode(password).length;
    if (bytes > DeviceProvider.maxFramePasswordBytes) {
      return 'Too long: the frame accepts at most '
          '${DeviceProvider.maxFramePasswordBytes} bytes (this is $bytes).';
    }
    if (password != _confirm.text) return 'The passwords do not match.';
    return null;
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  Future<void> _submit() async {
    final invalid = widget.turnOff ? null : _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? warning;
    try {
      await widget.provider.changeFramePassword(
        widget.turnOff ? '' : _password.text,
      );
    } on FramePasswordException catch (e) {
      if (!e.applied) {
        _fail(e.message);
        return;
      }
      warning = e.message;
    } catch (e) {
      _fail('Failed: $e');
      return;
    }
    if (mounted) Navigator.pop(context, (warning: warning));
  }

  @override
  Widget build(BuildContext context) {
    final changing = widget.provider.config?.httpAuthEnabled ?? false;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          widget.turnOff
              ? 'Turn off password protection?'
              : changing
              ? 'Change password'
              : 'Turn on password protection',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.turnOff)
                const Text(
                  "Anyone on this network will be able to use the frame's "
                  'web interface and API without a password.',
                )
              else ...[
                const Text(
                  'Requests to the frame without this password will be '
                  'refused. It is also saved in this app.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofocus: true,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'New password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Repeat new password',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: widget.turnOff
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.turnOff ? 'Turn off' : 'Save'),
          ),
        ],
      ),
    );
  }
}

/// Shown while the frame is refusing our password. Only the gallery navigates
/// away on a 401, and Settings replaces it, so a password changed on the frame
/// while this screen is open has to be surfaced here -- otherwise every edit
/// just fails. Saving a password clears [DeviceProvider.needsPassword], and
/// with it this banner.
class _PasswordBanner extends StatelessWidget implements PreferredSizeWidget {
  const _PasswordBanner({required this.onEnter});

  final VoidCallback onEnter;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SizedBox(
        height: preferredSize.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.lock_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'The frame wants a password. Changes here fail until it is '
                  'entered.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              TextButton(onPressed: onEnter, child: const Text('Enter')),
            ],
          ),
        ),
      ),
    );
  }
}
