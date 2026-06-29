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
      appBar: AppBar(title: const Text('Settings')),
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
                  onTap: () => _editText(context, provider, 'Device Name',
                      config.deviceName, 'device_name'),
                ),
                ListTile(
                  title: const Text('WiFi SSID'),
                  subtitle: Text(config.wifiSsid.isEmpty
                      ? 'Not set'
                      : config.wifiSsid),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editWifi(context, provider),
                ),
                ListTile(
                  title: const Text('Orientation'),
                  subtitle: Text(config.displayOrientation),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPicker(context, provider,
                      'Display Orientation', 'display_orientation',
                      {'landscape': 'Landscape', 'portrait': 'Portrait'}),
                ),
                ListTile(
                  title: const Text('Display Rotation'),
                  subtitle: Text('${config.displayRotationDeg}\u00B0'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPicker(context, provider,
                      'Display Rotation', 'display_rotation_deg',
                      {0: '0\u00B0', 90: '90\u00B0', 180: '180\u00B0', 270: '270\u00B0'}),
                ),
                ListTile(
                  title: const Text('Timezone'),
                  subtitle: Text(config.timezone.isEmpty
                      ? 'Not set'
                      : config.timezone),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(context, provider, 'Timezone',
                      config.timezone, 'timezone'),
                ),
                ListTile(
                  title: const Text('NTP Server'),
                  subtitle: Text(config.ntpServer.isEmpty
                      ? 'Not set'
                      : config.ntpServer),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(context, provider, 'NTP Server',
                      config.ntpServer, 'ntp_server'),
                ),

                // === Auto Rotate ===
                _SectionHeader('Auto Rotate'),
                SwitchListTile(
                  title: const Text('Auto Rotate'),
                  subtitle: const Text('Automatically cycle through images'),
                  value: config.autoRotate,
                  onChanged: (v) =>
                      provider.updateConfig({'auto_rotate': v}),
                ),
                ListTile(
                  title: const Text('Rotation Schedule'),
                  subtitle: Text(summarizeSchedule(config.rotateCron)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editSchedule(context, provider, config),
                ),
                ListTile(
                  title: const Text('Source'),
                  subtitle: Text(config.rotationMode == 'url'
                      ? 'URL'
                      : 'Storage'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showPicker(context, provider,
                      'Rotation Source', 'rotation_mode',
                      {'storage': 'Storage', 'url': 'URL'}),
                ),
                if (config.rotationMode == 'storage')
                  ListTile(
                    title: const Text('Storage Rotation Order'),
                    subtitle: Text(config.sdRotationMode),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showPicker(context, provider,
                        'Storage Rotation Order', 'sd_rotation_mode',
                        {'sequential': 'Sequential', 'random': 'Random'}),
                  ),
                if (config.rotationMode == 'url') ...[
                  ListTile(
                    title: const Text('Image URL'),
                    subtitle: Text(config.imageUrl.isEmpty
                        ? 'Not set'
                        : config.imageUrl,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _editText(context, provider, 'Image URL',
                        config.imageUrl, 'image_url'),
                  ),
                  SwitchListTile(
                    title: const Text('Save Downloaded Images'),
                    value: config.saveDownloadedImages,
                    onChanged: (v) =>
                        provider.updateConfig({'save_downloaded_images': v}),
                  ),
                  ListTile(
                    title: const Text('Access Token'),
                    subtitle: Text(config.accessToken.isEmpty
                        ? 'Not set'
                        : '\u2022' * 8),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _editText(context, provider,
                        'Access Token', config.accessToken, 'access_token'),
                  ),
                  ListTile(
                    title: const Text('Custom Header'),
                    subtitle: Text(config.httpHeaderKey.isEmpty
                        ? 'Not set'
                        : '${config.httpHeaderKey}: ${config.httpHeaderValue}'),
                    trailing: const Icon(Icons.edit),
                    onTap: () => _editHeader(context, provider),
                  ),
                ],

                // === Sleep Schedule ===
                _SectionHeader('Sleep Schedule'),
                SwitchListTile(
                  title: const Text('Sleep Schedule'),
                  subtitle: config.sleepScheduleEnabled
                      ? Text(
                          '${_formatMinutes(config.sleepScheduleStart)} \u2013 ${_formatMinutes(config.sleepScheduleEnd)}')
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
                    onTap: () => _pickTime(context, provider,
                        'sleep_schedule_start', config.sleepScheduleStart),
                  ),
                  ListTile(
                    title: const Text('Sleep Until'),
                    subtitle: Text(_formatMinutes(config.sleepScheduleEnd)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickTime(context, provider,
                        'sleep_schedule_end', config.sleepScheduleEnd),
                  ),
                ],

                // === Power ===
                _SectionHeader('Power'),
                SwitchListTile(
                  title: const Text('Deep Sleep'),
                  subtitle:
                      const Text('Sleep between rotations to save battery'),
                  value: config.deepSleepEnabled,
                  onChanged: (v) =>
                      provider.updateConfig({'deep_sleep_enabled': v}),
                ),

                // === Home Assistant ===
                _SectionHeader('Home Assistant'),
                ListTile(
                  title: const Text('Home Assistant URL'),
                  subtitle: Text(config.haUrl.isEmpty
                      ? 'Not set'
                      : config.haUrl),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(context, provider,
                      'Home Assistant URL', config.haUrl, 'ha_url'),
                ),

                // === AI Generation ===
                _SectionHeader('AI Generation'),
                ListTile(
                  title: const Text('OpenAI API Key'),
                  subtitle: Text(config.openaiApiKey.isEmpty
                      ? 'Not set'
                      : '\u2022' * 8),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(context, provider,
                      'OpenAI API Key', config.openaiApiKey, 'openai_api_key'),
                ),
                ListTile(
                  title: const Text('Google Gemini API Key'),
                  subtitle: Text(config.googleApiKey.isEmpty
                      ? 'Not set'
                      : '\u2022' * 8),
                  trailing: const Icon(Icons.edit),
                  onTap: () => _editText(context, provider,
                      'Google Gemini API Key', config.googleApiKey, 'google_api_key'),
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
                  title: Text('Factory Reset',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  leading: Icon(Icons.restore,
                      color: Theme.of(context).colorScheme.error),
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
              icon: Icon(Icons.photo_library), label: 'Gallery'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  Future<void> _editSchedule(
      BuildContext context, DeviceProvider provider, DeviceConfig config) async {
    final sleep = config.sleepScheduleEnabled
        ? QuietHours(true, config.sleepScheduleStart, config.sleepScheduleEnd)
        : null;
    final result = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) =>
            RotationScheduleScreen(initial: config.rotateCron, sleep: sleep),
      ),
    );
    if (result != null) {
      final updates = <String, dynamic>{'rotate_cron': result};
      // Also send a derived rotate_interval (when the schedule is a simple
      // every-day interval) so older firmware that predates rotate_cron still
      // applies it; newer firmware ignores it in favour of rotate_cron.
      final legacyInterval = cronToInterval(result);
      if (legacyInterval != null) {
        updates['rotate_interval'] = legacyInterval;
      }
      provider.updateConfig(updates);
    }
  }

  String _formatMinutes(int minutesFromMidnight) {
    final h = minutesFromMidnight ~/ 60;
    final m = minutesFromMidnight % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  // Generic text editor dialog
  void _editText(BuildContext context, DeviceProvider provider,
      String title, String current, String key) {
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

  void _editWifi(BuildContext context, DeviceProvider provider) {
    final ssidCtrl =
        TextEditingController(text: provider.config?.wifiSsid ?? '');
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
                  labelText: 'SSID', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Password (leave empty to keep current)',
                  border: OutlineInputBorder()),
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
  void _showPicker<T>(BuildContext context, DeviceProvider provider,
      String title, String key, Map<T, String> options) {
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

  void _pickTime(BuildContext context, DeviceProvider provider,
      String key, int currentMinutes) async {
    final initial = TimeOfDay(
        hour: currentMinutes ~/ 60, minute: currentMinutes % 60);
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked != null) {
      provider.updateConfig({key: picked.hour * 60 + picked.minute});
    }
  }

  void _editHeader(BuildContext context, DeviceProvider provider) {
    final keyCtrl =
        TextEditingController(text: provider.config?.httpHeaderKey ?? '');
    final valCtrl =
        TextEditingController(text: provider.config?.httpHeaderValue ?? '');
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
                  labelText: 'Header Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: valCtrl,
              decoration: const InputDecoration(
                  labelText: 'Header Value', border: OutlineInputBorder()),
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
            'Put the device to sleep? It will be unreachable until it wakes up.'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
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
            'This cannot be undone.'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
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
            'Install firmware $_latestVersion? The device will reboot after installation.'),
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
              _currentVersion.isEmpty ? 'Loading...' : _currentVersion),
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
                              strokeWidth: 2, color: Colors.white),
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
                Text('$_progress%',
                    style: Theme.of(context).textTheme.bodySmall),
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
