import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../providers/device_provider.dart';
import '../services/device_discovery.dart';
import '../services/saved_devices.dart';
import 'provisioning_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final _discovery = DeviceDiscovery();
  List<Device> _discoveredDevices = [];
  List<Device> _savedDevices = [];
  Set<String> _onlineHosts = {};
  StreamSubscription<List<Device>>? _sub;
  StreamSubscription<Set<String>>? _onlineSub;

  @override
  void initState() {
    super.initState();
    _loadSavedDevices();
    _sub = _discovery.devices.listen((devices) {
      setState(() => _discoveredDevices = devices);
    });
    _onlineSub = _discovery.onlineHosts.listen((hosts) {
      setState(() => _onlineHosts = hosts);
    });
    _startScan();
  }

  Future<void> _loadSavedDevices() async {
    final devices = await SavedDevices.load();
    if (mounted) {
      setState(() => _savedDevices = devices);
      _discovery.startOnlineCheck(devices);
    }
  }

  Future<void> _startScan() async {
    try {
      await _discovery.startDiscovery();
    } catch (e) {
      debugPrint('Discovery error: $e');
    }
  }

  Future<void> _connectToDevice(Device device) async {
    // Show connecting spinner
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Connecting...'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Resolve hostname and check if device is online
    final provider = context.read<DeviceProvider>();
    await provider.connectToDevice(device);
    try {
      final sysInfo = await provider.apiClient!.getSystemInfo().timeout(
        const Duration(seconds: 5),
      );
      if (!mounted) return;
      Navigator.pop(context); // dismiss spinner
      // Save with original host (mDNS name), not resolved IP
      await SavedDevices.addDevice(
        Device(
          name: sysInfo.deviceName.isNotEmpty
              ? sysInfo.deviceName
              : device.name,
          host: device.host,
          port: device.port,
        ),
      );
      if (!mounted) return;
      context.go('/gallery');
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context); // dismiss spinner
      provider.disconnect();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device is offline or unreachable')),
      );
    }
  }

  void _connectManual(String host) {
    if (host.isEmpty) return;
    final device = Device(name: host, host: host);
    _connectToDevice(device);
  }

  void _showManualConnectDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Manual Connection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'IP address or hostname',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            Navigator.pop(context);
            _connectManual(v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _connectManual(controller.text.trim());
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeSavedDevice(Device device) async {
    await SavedDevices.removeDevice(device);
    await _loadSavedDevices();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _onlineSub?.cancel();
    _discovery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 PhotoFrame'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Set up new device',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProvisioningScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Saved devices
            if (_savedDevices.isNotEmpty) ...[
              Text('Devices', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...List.generate(_savedDevices.length, (index) {
                final device = _savedDevices[index];
                final isOnline = _onlineHosts.contains(device.host);
                return ListTile(
                  leading: Icon(
                    isOnline ? Icons.wifi : Icons.wifi_off,
                    color: isOnline ? Colors.green : null,
                  ),
                  title: Text(device.name),
                  subtitle: Text(device.host),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _removeSavedDevice(device),
                    tooltip: 'Remove',
                  ),
                  onTap: () => _connectToDevice(device),
                );
              }),
              const Divider(),
              const SizedBox(height: 8),
            ],

            // Discovered devices
            Text(
              'Discovered Devices',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: () {
                // Filter out devices already in saved list
                final savedHosts = _savedDevices.map((d) => d.host).toSet();
                final filtered = _discoveredDevices
                    .where((d) => !savedHosts.contains(d.host))
                    .toList();
                return filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'No new devices found.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _showManualConnectDialog,
                              child: const Text('Enter IP address manually'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final device = filtered[index];
                          return ListTile(
                            leading: const Icon(Icons.image),
                            title: Text(device.name),
                            subtitle: Text('${device.host}:${device.port}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _connectToDevice(device),
                          );
                        },
                      );
              }(),
            ),
          ],
        ),
      ),
    );
  }
}
