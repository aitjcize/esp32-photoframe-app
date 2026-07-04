import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

class SavedDevices {
  static const _key = 'saved_devices';

  static Future<List<Device>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getStringList(_key);
    if (json == null) return [];
    return json
        .map((s) => Device.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<Device> devices) async {
    final prefs = await SharedPreferences.getInstance();
    final json = devices.map((d) => jsonEncode(d.toJson())).toList();
    await prefs.setStringList(_key, json);
  }

  static Future<void> addDevice(Device device) async {
    final devices = await load();
    // Update existing or add new
    final index = devices.indexWhere(
      (d) => d.host == device.host && d.port == device.port,
    );
    if (index >= 0) {
      devices[index] = device;
    } else {
      devices.add(device);
    }
    await save(devices);
  }

  static Future<void> removeDevice(Device device) async {
    final devices = await load();
    devices.removeWhere((d) => d.host == device.host && d.port == device.port);
    await save(devices);
  }
}
