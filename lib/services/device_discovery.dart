import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nsd/nsd.dart' as nsd;

import '../models/device.dart';

class DeviceDiscovery {
  nsd.Discovery? _discovery;
  final _devicesController = StreamController<List<Device>>.broadcast();
  final Map<String, Device> _found = {};

  // Online status tracking for saved devices
  final _onlineDevices = <String>{}; // hosts that responded to ping
  final _onlineController = StreamController<Set<String>>.broadcast();
  Timer? _pingTimer;

  Stream<List<Device>> get devices => _devicesController.stream;
  Stream<Set<String>> get onlineHosts => _onlineController.stream;
  List<Device> get currentDevices => _found.values.toList();
  Set<String> get currentOnlineHosts => Set.unmodifiable(_onlineDevices);

  Future<void> startDiscovery() async {
    _found.clear();
    _devicesController.add([]);

    debugPrint('Starting mDNS discovery for _esp32-pframe._tcp');

    _discovery = await nsd.startDiscovery(
      '_esp32-pframe._tcp',
      ipLookupType: nsd.IpLookupType.v4,
    );
    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        _onServiceFound(service);
      }
    });
  }

  /// Start periodic pinging of saved devices to check online status.
  void startOnlineCheck(List<Device> savedDevices) {
    _pingTimer?.cancel();
    // Ping immediately, then every 15 seconds
    _pingDevices(savedDevices);
    _pingTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pingDevices(savedDevices),
    );
  }

  /// Update the list of devices to ping.
  void updateSavedDevices(List<Device> savedDevices) {
    _pingTimer?.cancel();
    _pingDevices(savedDevices);
    _pingTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pingDevices(savedDevices),
    );
  }

  Future<void> _pingDevices(List<Device> devices) async {
    final online = <String>{};
    final client = http.Client();
    try {
      await Future.wait(
        devices.map((device) async {
          try {
            final uri = Uri.parse(
              'http://${device.host}:${device.port}/api/time',
            );
            final response = await client
                .get(uri)
                .timeout(const Duration(seconds: 3));
            if (response.statusCode == 200) {
              online.add(device.host);
            }
          } catch (_) {
            // Device offline or unreachable
          }
        }),
      );
    } finally {
      client.close();
    }

    _onlineDevices
      ..clear()
      ..addAll(online);
    _onlineController.add(Set.unmodifiable(_onlineDevices));
  }

  void _onServiceFound(nsd.Service service) {
    final host = service.host;
    final port = service.port;
    if (host == null || port == null) return;

    final txt = service.txt;
    final nameBytes = txt?['name'];
    final hostBytes = txt?['host'];
    final displayName = nameBytes != null
        ? utf8.decode(nameBytes)
        : service.name ?? host;
    final persistHost = hostBytes != null ? utf8.decode(hostBytes) : host;

    debugPrint(
      'mDNS found: name=$displayName host=$persistHost (resolved=$host) port=$port',
    );

    final device = Device(name: displayName, host: persistHost, port: port);
    _found[persistHost] = device;
    _devicesController.add(_found.values.toList());

    // Mark as online immediately
    _onlineDevices.add(persistHost);
    _onlineController.add(Set.unmodifiable(_onlineDevices));
  }

  Future<void> stopDiscovery() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    if (_discovery != null) {
      try {
        await nsd.stopDiscovery(_discovery!);
      } catch (_) {}
      _discovery = null;
    }
  }

  void dispose() {
    stopDiscovery();
    _devicesController.close();
    _onlineController.close();
  }
}
