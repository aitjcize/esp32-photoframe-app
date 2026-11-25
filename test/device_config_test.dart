import 'package:esp32_photoframe_app/models/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mirroring the panel (firmware #161): the switch shows only for firmware
  // that reports the setting.
  group('DeviceConfig.displayMirror', () {
    test('reads true and false', () {
      expect(
        DeviceConfig.fromJson({'display_mirror': true}).displayMirror,
        isTrue,
      );
      expect(
        DeviceConfig.fromJson({'display_mirror': false}).displayMirror,
        isFalse,
      );
    });

    test('is null on firmware without the setting', () {
      expect(DeviceConfig.fromJson({}).displayMirror, isNull);
    });
  });
}
