import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../providers/device_provider.dart';
import '../services/cron.dart';
import '../services/saved_devices.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final provider = context.read<DeviceProvider>();
      await provider.refreshAll();
      // Update saved device with real name from system info
      if (provider.device != null && provider.systemInfo != null) {
        await SavedDevices.addDevice(provider.device!);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DeviceProvider>();

    if (provider.loading && provider.systemInfo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Dashboard')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (provider.error != null && provider.systemInfo == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Dashboard'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              provider.disconnect();
              context.go('/devices');
            },
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              Text('Connection failed', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(provider.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => provider.refreshAll(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final sysInfo = provider.systemInfo;
    final battery = provider.batteryInfo;
    final config = provider.config;

    return Scaffold(
      appBar: AppBar(
        title: Text(sysInfo?.deviceName ?? 'PhotoFrame'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            provider.disconnect();
            context.go('/devices');
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => provider.refreshAll(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => provider.refreshAll(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Current image
            if (provider.currentImage != null &&
                provider.currentImage!.isNotEmpty)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: (sysInfo?.displayWidth ?? 800) /
                          (sysInfo?.displayHeight ?? 480),
                      child: CachedNetworkImage(
                        imageUrl: provider.apiClient!
                            .getImageUrl(provider.currentImage!),
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            const Center(child: CircularProgressIndicator()),
                        errorWidget: (_, _, _) =>
                            const Center(child: Icon(Icons.broken_image)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Currently displaying',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),

            // Quick actions
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => provider.rotateImage(),
                    icon: const Icon(Icons.skip_next),
                    label: const Text('Next Image'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => context.go('/gallery'),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Device info card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Device Info',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Divider(),
                    _InfoRow('Name', sysInfo?.deviceName ?? '-'),
                    _InfoRow('Board', sysInfo?.board ?? '-'),
                    _InfoRow('Firmware', sysInfo?.firmwareVersion ?? '-'),
                    _InfoRow(
                      'Display',
                      '${sysInfo?.displayWidth ?? 0} x ${sysInfo?.displayHeight ?? 0}',
                    ),
                    _InfoRow(
                      'Storage',
                      '${((sysInfo?.storageUsed ?? 0) / 1024).toStringAsFixed(0)} / '
                          '${((sysInfo?.storageTotal ?? 0) / 1024).toStringAsFixed(0)} KB',
                    ),
                    if (battery != null) ...[
                      const Divider(),
                      _InfoRow(
                        'Battery',
                        '${battery.level}% (${battery.voltage.toStringAsFixed(2)}V)'
                            '${battery.charging ? ' - Charging' : ''}',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Status card
            if (config != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Status',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Divider(),
                      _InfoRow(
                        'Auto Rotate',
                        config.autoRotate ? 'On' : 'Off',
                      ),
                      _InfoRow(
                        'Schedule',
                        summarizeSchedule(config.rotateCron),
                      ),
                      _InfoRow('Source', config.rotationMode == 'url' ? 'URL' : 'Storage'),
                      _InfoRow(
                        'Deep Sleep',
                        config.deepSleepEnabled ? 'Enabled' : 'Disabled',
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          switch (index) {
            case 0:
              break;
            case 1:
              context.go('/gallery');
            case 2:
              context.go('/settings');
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(
              icon: Icon(Icons.photo_library), label: 'Gallery'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
