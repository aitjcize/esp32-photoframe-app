// E-paper display color palettes.
//
// Each palette contains a pair:
// - theoretical: Pure RGB values for device output (what gets sent to the display)
// - perceived: Actual RGB values as measured on screen (for dithering calculations)

import 'dart:math' as math;

class PaletteColor {
  final int r, g, b;
  const PaletteColor(this.r, this.g, this.b);
}

class Palette {
  final PaletteColor black;
  final PaletteColor white;
  final PaletteColor yellow;
  final PaletteColor red;
  final PaletteColor blue;
  final PaletteColor green;

  /// Grayscale (GC16) palettes carry an ordered gray ramp ([r,g,b] per level)
  /// here; null for color palettes. When set it drives dithering + packing.
  final List<List<int>>? grays;

  const Palette({
    required this.black,
    required this.white,
    required this.yellow,
    required this.red,
    required this.blue,
    required this.green,
    this.grays,
  });

  PaletteColor? operator [](String name) {
    switch (name) {
      case 'black':
        return black;
      case 'white':
        return white;
      case 'yellow':
        return yellow;
      case 'red':
        return red;
      case 'blue':
        return blue;
      case 'green':
        return green;
      default:
        return null;
    }
  }

  /// Convert to array format: [black, white, yellow, red, reserved, blue, green]
  /// Index 4 is reserved (not used).
  List<List<int>> toArray() {
    if (grays != null) return grays!;
    return [
      [black.r, black.g, black.b],
      [white.r, white.g, white.b],
      [yellow.r, yellow.g, yellow.b],
      [red.r, red.g, red.b],
      [0, 0, 0], // Reserved (index 4)
      [blue.r, blue.g, blue.b],
      [green.r, green.g, green.b],
    ];
  }
}

class PalettePair {
  final Palette theoretical;
  final Palette perceived;
  const PalettePair({required this.theoretical, required this.perceived});
}

/// Spectra 6 (ACeP) — default palette for 6-color e-paper displays.
const spectra6 = PalettePair(
  theoretical: Palette(
    black: PaletteColor(0, 0, 0),
    white: PaletteColor(255, 255, 255),
    yellow: PaletteColor(255, 255, 0),
    red: PaletteColor(255, 0, 0),
    blue: PaletteColor(0, 0, 255),
    green: PaletteColor(0, 255, 0),
  ),
  perceived: Palette(
    black: PaletteColor(2, 2, 2),
    white: PaletteColor(190, 200, 200),
    yellow: PaletteColor(205, 202, 0),
    red: PaletteColor(135, 19, 0),
    blue: PaletteColor(5, 64, 158),
    green: PaletteColor(39, 102, 60),
  ),
);

const defaultPalette = spectra6;

/// 16-level theoretical (device-output) gray ramp ([r,g,b] per level,
/// 255/15 == 17 step). Level index i maps directly to nibble i.
const _gray16Ramp = [
  [0, 0, 0],
  [17, 17, 17],
  [34, 34, 34],
  [51, 51, 51],
  [68, 68, 68],
  [85, 85, 85],
  [102, 102, 102],
  [119, 119, 119],
  [136, 136, 136],
  [153, 153, 153],
  [170, 170, 170],
  [187, 187, 187],
  [204, 204, 204],
  [221, 221, 221],
  [238, 238, 238],
  [255, 255, 255],
];

/// Default measured relative luminance (Y, 0..1) of a GC16 panel's full
/// black / full white. A device that reports its own endpoints overrides these.
const _grayBlackY = 0.02;
const _grayWhiteY = 0.90;

/// CIE L* (0..100) from a relative luminance Y (0..1).
double _lstarFromY(double y) =>
    y > 0.008856 ? 116 * math.pow(y, 1 / 3) - 16 : 903.3 * y;

/// 8-bit sRGB neutral gray for a CIE L*.
int _grayFromLstar(double l) {
  final y = l > 8 ? math.pow((l + 16) / 116, 3).toDouble() : l / 903.3;
  final s = y <= 0.0031308 ? 12.92 * y : 1.055 * math.pow(y, 1 / 2.4) - 0.055;
  return (s * 255).round().clamp(0, 255);
}

/// Perceptually-even (linear in L*) gray ramp between the measured endpoints.
List<List<int>> _buildCalibratedGrayRamp(
  double blackL,
  double whiteL,
  int levels,
) {
  final grays = <List<int>>[];
  for (var i = 0; i < levels; i++) {
    final l = blackL + (i / (levels - 1)) * (whiteL - blackL);
    final v = _grayFromLstar(l);
    grays.add([v, v, v]);
  }
  return grays;
}

const _grayscaleTheoretical = Palette(
  black: PaletteColor(0, 0, 0),
  white: PaletteColor(255, 255, 255),
  // Color entries are unused on a grayscale panel; set to mid-gray.
  yellow: PaletteColor(128, 128, 128),
  red: PaletteColor(128, 128, 128),
  blue: PaletteColor(128, 128, 128),
  green: PaletteColor(128, 128, 128),
  grays: _gray16Ramp,
);

/// Build a 16-level grayscale (GC16) palette from two measured luminance
/// endpoints. The perceived ramp is *derived* (L* interpolation -> sRGB), so
/// only the two endpoints need to be measured/transported — a device reports
/// its Y_black / Y_white and everyone (CLI, webapp, app) derives the same ramp.
///
/// theoretical = the device output ramp (0..255, level i -> nibble i).
/// perceived   = the panel's compressed luminance (drives dithering + dynamic-
/// range compression); the black/white aliases keep the background + CDR code
/// (which reads palette.black/white) working.
PalettePair makeGrayscale16({
  double blackY = _grayBlackY,
  double whiteY = _grayWhiteY,
}) {
  final perceivedGrays = _buildCalibratedGrayRamp(
    _lstarFromY(blackY),
    _lstarFromY(whiteY),
    16,
  );
  final first = perceivedGrays.first;
  final last = perceivedGrays.last;
  final perceived = Palette(
    black: PaletteColor(first[0], first[1], first[2]),
    white: PaletteColor(last[0], last[1], last[2]),
    yellow: const PaletteColor(128, 128, 128),
    red: const PaletteColor(128, 128, 128),
    blue: const PaletteColor(128, 128, 128),
    green: const PaletteColor(128, 128, 128),
    grays: perceivedGrays,
  );
  return PalettePair(theoretical: _grayscaleTheoretical, perceived: perceived);
}

/// Grayscale (GC16 / IT8951) — 16-level gray ramp with a calibrated (default
/// endpoint) perceived ramp. Use [makeGrayscale16] with a device's measured
/// endpoints for a panel-accurate preview.
final grayscale16 = makeGrayscale16();

/// True if [pair] is a grayscale (GC16) palette.
bool isGrayscalePalette(PalettePair pair) => pair.theoretical.grays != null;
