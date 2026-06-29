// E-paper display color palettes.
//
// Each palette contains a pair:
// - theoretical: Pure RGB values for device output (what gets sent to the display)
// - perceived: Actual RGB values as measured on screen (for dithering calculations)

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

/// 16-level grayscale ramp ([r,g,b] per level, 255/15 == 17 step).
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

const _grayscalePalette = Palette(
  black: PaletteColor(0, 0, 0),
  white: PaletteColor(255, 255, 255),
  // Color entries are unused on a grayscale panel; set to mid-gray.
  yellow: PaletteColor(128, 128, 128),
  red: PaletteColor(128, 128, 128),
  blue: PaletteColor(128, 128, 128),
  green: PaletteColor(128, 128, 128),
  grays: _gray16Ramp,
);

/// Grayscale (GC16 / IT8951) — 16-level gray ramp. theoretical == perceived.
const grayscale16 = PalettePair(
  theoretical: _grayscalePalette,
  perceived: _grayscalePalette,
);

/// True if [pair] is a grayscale (GC16) palette.
bool isGrayscalePalette(PalettePair pair) => pair.theoretical.grays != null;
