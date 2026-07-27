import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:wifi_iot/wifi_iot.dart';
import 'package:wifi_scan/wifi_scan.dart';

/// WiFi provisioning flow for new ESP32 PhotoFrame devices.
///
/// Android: Scan for hotspots → connect → configure
/// iOS: Ask user to connect manually in Settings → detect connection → configure
class ProvisioningScreen extends StatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  State<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

enum _ProvisionStep {
  scanning,
  waitingForManualConnect,
  connecting,
  configuring,
  saving,
  done,
  error,
}

class _ProvisioningScreenState extends State<ProvisioningScreen>
    with WidgetsBindingObserver {
  _ProvisionStep _step = _ProvisionStep.scanning;
  String _statusMessage = '';
  String? _errorMessage;

  // Step 1: Hotspot scan results (Android only)
  List<WiFiAccessPoint> _hotspots = [];

  // Step 3: WiFi networks from device
  List<dynamic> _wifiNetworks = [];
  String? _selectedSsid;
  final _passwordController = TextEditingController();
  final _deviceNameController = TextEditingController(text: 'PhotoFrame');
  bool _obscurePassword = true;

  // Advanced network settings (#43), collapsed by default.
  bool _showAdvanced = false;
  String _ipMode = 'dhcp';
  final _staticIpController = TextEditingController();
  final _staticNetmaskController = TextEditingController(text: '255.255.255.0');
  final _staticGatewayController = TextEditingController();
  final _dnsServerController = TextEditingController();

  bool get _isIOS => Platform.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startProvisioning();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _passwordController.dispose();
    _deviceNameController.dispose();
    _staticIpController.dispose();
    _staticNetmaskController.dispose();
    _staticGatewayController.dispose();
    _dnsServerController.dispose();
    super.dispose();
  }

  // Detect when user returns from Settings (iOS)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _step == _ProvisionStep.waitingForManualConnect) {
      _checkIfConnectedToPhotoFrame();
    }
  }

  void _startProvisioning() {
    if (_isIOS) {
      _startIOSFlow();
    } else {
      _startAndroidScan();
    }
  }

  // === iOS Flow ===

  void _startIOSFlow() {
    setState(() {
      _step = _ProvisionStep.waitingForManualConnect;
      _statusMessage = 'Connect to your PhotoFrame\'s WiFi hotspot';
    });
  }

  Future<void> _checkIfConnectedToPhotoFrame() async {
    setState(() {
      _statusMessage = 'Checking connection...';
    });

    // Try to reach the device at the AP address
    try {
      final response = await http
          .get(Uri.parse('http://192.168.4.1/api/keep_alive'))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        // Connected to PhotoFrame!
        await _fetchWifiNetworks();
      } else {
        if (mounted) {
          setState(() {
            _statusMessage = 'Connect to your PhotoFrame\'s WiFi hotspot';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Not connected to a PhotoFrame hotspot yet'),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Connect to your PhotoFrame\'s WiFi hotspot';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not connected to a PhotoFrame hotspot yet'),
          ),
        );
      }
    }
  }

  // === Android Flow ===

  Future<void> _startAndroidScan() async {
    setState(() {
      _step = _ProvisionStep.scanning;
      _statusMessage = 'Scanning for PhotoFrame devices...';
      _hotspots = [];
    });

    final scanner = WiFiScan.instance;
    final canScan = await scanner.canStartScan();
    if (canScan != CanStartScan.yes) {
      setState(() {
        _step = _ProvisionStep.error;
        _errorMessage =
            'Cannot start WiFi scan. Please enable WiFi and location services.';
      });
      return;
    }

    await scanner.startScan();
    await Future.delayed(const Duration(seconds: 3));
    final results = await scanner.getScannedResults();

    final photoframeHotspots = results
        .where((ap) => ap.ssid.startsWith('PhotoFrame - '))
        .toList();

    if (!mounted) return;

    if (photoframeHotspots.isEmpty) {
      setState(() {
        _step = _ProvisionStep.error;
        _errorMessage =
            'No PhotoFrame setup hotspots found.\n\n'
            'Make sure your PhotoFrame is in setup mode '
            '(not yet configured or factory reset).';
      });
    } else {
      setState(() {
        _hotspots = photoframeHotspots;
        _statusMessage = 'Found ${photoframeHotspots.length} device(s)';
      });
    }
  }

  // === Common Flow ===

  Future<void> _connectToHotspot(WiFiAccessPoint hotspot) async {
    setState(() {
      _step = _ProvisionStep.connecting;
      _statusMessage = 'Connecting to ${hotspot.ssid}...';
    });

    try {
      final connected = await WiFiForIoTPlugin.connect(
        hotspot.ssid,
        security: NetworkSecurity.NONE,
        joinOnce: true,
        withInternet: false,
      );

      if (!connected) {
        if (mounted) {
          setState(() {
            _step = _ProvisionStep.error;
            _errorMessage = 'Failed to connect to ${hotspot.ssid}';
          });
        }
        return;
      }

      await Future.delayed(const Duration(seconds: 3));
      await WiFiForIoTPlugin.forceWifiUsage(true);
      await _fetchWifiNetworks();
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _ProvisionStep.error;
          _errorMessage = 'Connection error: $e';
        });
      }
    }
  }

  Future<void> _fetchWifiNetworks() async {
    setState(() {
      _step = _ProvisionStep.connecting;
      _statusMessage = 'Scanning WiFi networks...';
    });

    try {
      final response = await http
          .get(Uri.parse('http://192.168.4.1/api/wifi/scan'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final networks = jsonDecode(response.body) as List<dynamic>;
        networks.sort(
          (a, b) =>
              (b['rssi'] as int? ?? -100).compareTo(a['rssi'] as int? ?? -100),
        );

        if (mounted) {
          setState(() {
            _wifiNetworks = networks;
            _step = _ProvisionStep.configuring;
            _statusMessage = 'Select your WiFi network';
          });
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _ProvisionStep.error;
          _errorMessage = 'Failed to fetch WiFi networks from device: $e';
        });
      }
    }
  }

  Future<void> _submitCredentials() async {
    if (_selectedSsid == null || _selectedSsid!.isEmpty) return;

    setState(() {
      _step = _ProvisionStep.saving;
      _statusMessage = 'Configuring device...';
    });

    try {
      final response = await http
          .post(
            Uri.parse('http://192.168.4.1/save'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'ssid': _selectedSsid!,
              'password': _passwordController.text,
              'deviceName': _deviceNameController.text.trim().isEmpty
                  ? 'PhotoFrame'
                  : _deviceNameController.text.trim(),
              // Advanced network settings (#43); the firmware falls back to
              // DHCP unless ipMode is exactly "static". Older firmware
              // ignores the extra fields.
              'ipMode': _ipMode,
              if (_ipMode == 'static') ...{
                'staticIp': _staticIpController.text.trim(),
                'staticNetmask': _staticNetmaskController.text.trim(),
                'staticGateway': _staticGatewayController.text.trim(),
              },
              'dnsServer': _dnsServerController.text.trim(),
            },
          )
          .timeout(const Duration(seconds: 20));

      if (!_isIOS) {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }

      if (!mounted) return;

      if (response.statusCode == 200 &&
          response.body.toLowerCase().contains('success')) {
        setState(() {
          _step = _ProvisionStep.done;
          _statusMessage =
              'Device configured successfully!\n\n'
              'The device will restart and connect to your WiFi network. '
              'It should appear in your device list shortly.';
        });
      } else {
        setState(() {
          _step = _ProvisionStep.error;
          _errorMessage =
              'Device returned an error. '
              'Please check the credentials and try again.';
        });
      }
    } catch (e) {
      if (!_isIOS) {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      }

      if (mounted) {
        setState(() {
          _step = _ProvisionStep.done;
          _statusMessage =
              'Credentials sent!\n\n'
              'The device should restart and connect to your WiFi network. '
              'It should appear in your device list shortly.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set Up New Device')),
      body: Padding(padding: const EdgeInsets.all(16), child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case _ProvisionStep.scanning:
        return _hotspots.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(_statusMessage),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusMessage,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('Tap a device to begin setup:'),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _hotspots.length,
                      itemBuilder: (context, index) {
                        final ap = _hotspots[index];
                        return ListTile(
                          leading: const Icon(Icons.image),
                          title: Text(ap.ssid),
                          subtitle: Text('Signal: ${ap.level} dBm'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _connectToHotspot(ap),
                        );
                      },
                    ),
                  ),
                ],
              );

      case _ProvisionStep.waitingForManualConnect:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_find, size: 64),
              const SizedBox(height: 24),
              Text(
                _statusMessage,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'Go to Settings → Wi-Fi and connect to a network\n'
                'starting with "PhotoFrame - ", then return here.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _checkIfConnectedToPhotoFrame,
                icon: const Icon(Icons.refresh),
                label: const Text('I\'ve Connected'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );

      case _ProvisionStep.connecting:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_statusMessage),
            ],
          ),
        );

      case _ProvisionStep.configuring:
        return ListView(
          children: [
            Text(
              'WiFi Network',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ..._wifiNetworks.map((network) {
              final ssid = network['ssid'] as String? ?? '';
              final rssi = network['rssi'] as int?;
              final authMode = network['authmode'] as int? ?? 0;
              if (ssid.isEmpty) return const SizedBox.shrink();
              final isSelected = _selectedSsid == ssid;
              return ListTile(
                leading: Icon(
                  rssi != null && rssi >= -60
                      ? Icons.wifi
                      : rssi != null && rssi >= -70
                      ? Icons.wifi_2_bar
                      : Icons.wifi_1_bar,
                ),
                title: Text(ssid),
                subtitle: Text(
                  '${rssi ?? "?"} dBm${authMode > 0 ? ' \u2022 Secured' : ''}',
                ),
                trailing: isSelected
                    ? Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                selected: isSelected,
                onTap: () => setState(() => _selectedSsid = ssid),
              );
            }),
            const SizedBox(height: 16),
            if (_selectedSsid != null) ...[
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'WiFi Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _deviceNameController,
                decoration: const InputDecoration(
                  labelText: 'Device Name',
                  border: OutlineInputBorder(),
                  hintText: 'PhotoFrame',
                ),
              ),
              const SizedBox(height: 8),
              // Advanced network settings (#43), collapsed by default.
              TextButton.icon(
                onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                icon: Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                ),
                label: const Text('Advanced network settings'),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _ipMode,
                  decoration: const InputDecoration(
                    labelText: 'IP Configuration',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'dhcp',
                      child: Text('Automatic (DHCP)'),
                    ),
                    DropdownMenuItem(value: 'static', child: Text('Static IP')),
                  ],
                  onChanged: (v) => setState(() => _ipMode = v ?? 'dhcp'),
                ),
                if (_ipMode == 'static') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _staticIpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'IP Address',
                      border: OutlineInputBorder(),
                      hintText: '192.168.1.50',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _staticNetmaskController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Netmask',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _staticGatewayController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Gateway',
                      border: OutlineInputBorder(),
                      hintText: '192.168.1.1',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _dnsServerController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'DNS Server',
                    border: const OutlineInputBorder(),
                    hintText: _ipMode == 'static'
                        ? 'Leave empty to use the gateway'
                        : 'Optional; leave empty for DHCP-provided DNS',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _submitCredentials,
                icon: const Icon(Icons.send),
                label: const Text('Configure Device'),
              ),
            ],
          ],
        );

      case _ProvisionStep.saving:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_statusMessage),
            ],
          ),
        );

      case _ProvisionStep.done:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(_statusMessage, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        );

      case _ProvisionStep.error:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage ?? 'Unknown error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _startProvisioning,
                child: const Text('Retry'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
    }
  }
}
