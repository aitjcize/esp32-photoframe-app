/// Core image processing for e-paper displays.
///
/// Port of epaper-image-convert (Node.js) to Dart.
/// Handles color space conversion, tone mapping, error diffusion dithering,
/// and EPDGZ output.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'palettes.dart';
import 'presets.dart';

// ============================================================
// Color space conversion
// ============================================================

List<double> rgbToXyz(double r, double g, double b) {
  r /= 255;
  g /= 255;
  b /= 255;

  r = r > 0.04045 ? math.pow((r + 0.055) / 1.055, 2.4).toDouble() : r / 12.92;
  g = g > 0.04045 ? math.pow((g + 0.055) / 1.055, 2.4).toDouble() : g / 12.92;
  b = b > 0.04045 ? math.pow((b + 0.055) / 1.055, 2.4).toDouble() : b / 12.92;

  final x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375;
  final y = r * 0.2126729 + g * 0.7151522 + b * 0.072175;
  final z = r * 0.0193339 + g * 0.119192 + b * 0.9503041;

  return [x * 100, y * 100, z * 100];
}

List<double> xyzToLab(double x, double y, double z) {
  x /= 95.047;
  y /= 100.0;
  z /= 108.883;

  x = x > 0.008856
      ? math.pow(x, 1.0 / 3.0).toDouble()
      : 7.787 * x + 16.0 / 116.0;
  y = y > 0.008856
      ? math.pow(y, 1.0 / 3.0).toDouble()
      : 7.787 * y + 16.0 / 116.0;
  z = z > 0.008856
      ? math.pow(z, 1.0 / 3.0).toDouble()
      : 7.787 * z + 16.0 / 116.0;

  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
}

List<double> rgbToLab(double r, double g, double b) {
  final xyz = rgbToXyz(r, g, b);
  return xyzToLab(xyz[0], xyz[1], xyz[2]);
}

List<double> labToXyz(double l, double a, double b) {
  var y = (l + 16) / 116;
  var x = a / 500 + y;
  var z = y - b / 200;

  x = x > 0.206897 ? math.pow(x, 3).toDouble() : (x - 16.0 / 116.0) / 7.787;
  y = y > 0.206897 ? math.pow(y, 3).toDouble() : (y - 16.0 / 116.0) / 7.787;
  z = z > 0.206897 ? math.pow(z, 3).toDouble() : (z - 16.0 / 116.0) / 7.787;

  return [x * 95.047, y * 100.0, z * 108.883];
}

List<int> xyzToRgb(double x, double y, double z) {
  x /= 100;
  y /= 100;
  z /= 100;

  var r = x * 3.2404542 + y * -1.5371385 + z * -0.4985314;
  var g = x * -0.969266 + y * 1.8760108 + z * 0.041556;
  var b = x * 0.0556434 + y * -0.2040259 + z * 1.0572252;

  r = r > 0.0031308 ? 1.055 * math.pow(r, 1.0 / 2.4) - 0.055 : 12.92 * r;
  g = g > 0.0031308 ? 1.055 * math.pow(g, 1.0 / 2.4) - 0.055 : 12.92 * g;
  b = b > 0.0031308 ? 1.055 * math.pow(b, 1.0 / 2.4) - 0.055 : 12.92 * b;

  return [
    (r * 255).round().clamp(0, 255),
    (g * 255).round().clamp(0, 255),
    (b * 255).round().clamp(0, 255),
  ];
}

List<int> labToRgb(double l, double a, double b) {
  final xyz = labToXyz(l, a, b);
  return xyzToRgb(xyz[0], xyz[1], xyz[2]);
}

double deltaE(List<double> lab1, List<double> lab2) {
  final dl = lab1[0] - lab2[0];
  final da = lab1[1] - lab2[1];
  final db = lab1[2] - lab2[2];
  return math.sqrt(dl * dl + da * da + db * db);
}

// ============================================================
// Image adjustment functions (operate on RGBA pixel buffer)
// ============================================================

/// RGBA pixel buffer wrapper for processing.
class PixelBuffer {
  final Uint8List data;
  final int width;
  final int height;

  PixelBuffer(this.data, this.width, this.height);

  /// Create from an [img.Image], converting to RGBA bytes.
  factory PixelBuffer.fromImage(img.Image image) {
    final w = image.width;
    final h = image.height;
    final buf = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final i = (y * w + x) * 4;
        buf[i] = p.r.toInt();
        buf[i + 1] = p.g.toInt();
        buf[i + 2] = p.b.toInt();
        buf[i + 3] = 255;
      }
    }
    return PixelBuffer(buf, w, h);
  }

  /// Write back into an [img.Image].
  img.Image toImage() {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        image.setPixelRgba(x, y, data[i], data[i + 1], data[i + 2], 255);
      }
    }
    return image;
  }
}

void applyExposure(PixelBuffer buf, double exposure) {
  if (exposure == 1.0) return;
  final d = buf.data;
  for (var i = 0; i < d.length; i += 4) {
    d[i] = (d[i] * exposure).round().clamp(0, 255);
    d[i + 1] = (d[i + 1] * exposure).round().clamp(0, 255);
    d[i + 2] = (d[i + 2] * exposure).round().clamp(0, 255);
  }
}

void applyContrast(PixelBuffer buf, double contrast) {
  if (contrast == 1.0) return;
  final d = buf.data;
  for (var i = 0; i < d.length; i += 4) {
    d[i] = ((d[i] - 128) * contrast + 128).round().clamp(0, 255);
    d[i + 1] = ((d[i + 1] - 128) * contrast + 128).round().clamp(0, 255);
    d[i + 2] = ((d[i + 2] - 128) * contrast + 128).round().clamp(0, 255);
  }
}

void applySaturation(PixelBuffer buf, double saturation) {
  if (saturation == 1.0) return;
  final d = buf.data;

  for (var i = 0; i < d.length; i += 4) {
    final r = d[i] / 255.0;
    final g = d[i + 1] / 255.0;
    final b = d[i + 2] / 255.0;

    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final l = (maxC + minC) / 2;

    if (maxC == minC) continue; // grayscale

    final delta = maxC - minC;
    final s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC);

    double h;
    if (maxC == r) {
      h = ((g - b) / delta + (g < b ? 6 : 0)) / 6;
    } else if (maxC == g) {
      h = ((b - r) / delta + 2) / 6;
    } else {
      h = ((r - g) / delta + 4) / 6;
    }

    final newS = (s * saturation).clamp(0.0, 1.0);
    final c = (1 - (2 * l - 1).abs()) * newS;
    final x = c * (1 - ((h * 6) % 2 - 1).abs());
    final m = l - c / 2;

    double rP, gP, bP;
    final hSector = (h * 6).floor();
    switch (hSector) {
      case 0:
        (rP, gP, bP) = (c, x, 0);
      case 1:
        (rP, gP, bP) = (x, c, 0);
      case 2:
        (rP, gP, bP) = (0, c, x);
      case 3:
        (rP, gP, bP) = (0, x, c);
      case 4:
        (rP, gP, bP) = (x, 0, c);
      default:
        (rP, gP, bP) = (c, 0, x);
    }

    d[i] = ((rP + m) * 255).round().clamp(0, 255);
    d[i + 1] = ((gP + m) * 255).round().clamp(0, 255);
    d[i + 2] = ((bP + m) * 255).round().clamp(0, 255);
  }
}

void applyScurveTonemap(
  PixelBuffer buf,
  double strength,
  double shadowBoost,
  double highlightCompress,
  double midpoint,
) {
  if (strength == 0) return;
  final d = buf.data;

  for (var i = 0; i < d.length; i += 4) {
    for (var c = 0; c < 3; c++) {
      final normalized = d[i + c] / 255.0;
      double result;

      if (normalized <= midpoint) {
        final shadowVal = normalized / midpoint;
        result =
            math.pow(shadowVal, 1.0 - strength * shadowBoost).toDouble() *
            midpoint;
      } else {
        final highlightVal = (normalized - midpoint) / (1.0 - midpoint);
        result =
            midpoint +
            math
                    .pow(highlightVal, 1.0 + strength * highlightCompress)
                    .toDouble() *
                (1.0 - midpoint);
      }

      d[i + c] = (result.clamp(0.0, 1.0) * 255).round();
    }
  }
}

// ============================================================
// Color matching
// ============================================================

int _findClosestRGB(
  double r,
  double g,
  double b,
  List<List<int>> paletteArray,
) {
  var minDist = double.infinity;
  var closest = 1;

  for (var i = 0; i < paletteArray.length; i++) {
    if (i == 4) continue; // skip reserved
    final pr = paletteArray[i][0];
    final pg = paletteArray[i][1];
    final pb = paletteArray[i][2];
    final dr = r - pr;
    final dg = g - pg;
    final db = b - pb;
    final dist = dr * dr + dg * dg + db * db;
    if (dist < minDist) {
      minDist = dist;
      closest = i;
    }
  }
  return closest;
}

int _findClosestLAB(
  double r,
  double g,
  double b,
  List<List<int>> paletteArray,
  List<List<double>> paletteLab,
) {
  var minDist = double.infinity;
  var closest = 1;
  final inputLab = rgbToLab(r, g, b);

  for (var i = 0; i < paletteArray.length; i++) {
    if (i == 4) continue;
    final dist = deltaE(inputLab, paletteLab[i]);
    if (dist < minDist) {
      minDist = dist;
      closest = i;
    }
  }
  return closest;
}

int findClosestColor(
  double r,
  double g,
  double b,
  ColorMethod method,
  List<List<int>> paletteArray,
  List<List<double>>? paletteLab,
) {
  return method == ColorMethod.lab
      ? _findClosestLAB(r, g, b, paletteArray, paletteLab!)
      : _findClosestRGB(r, g, b, paletteArray);
}

// ============================================================
// Dithering
// ============================================================

/// Diffusion matrix entries: [dx, dy, weight].
const _diffusionMatrices = <DitherAlgorithm, List<List<double>>>{
  DitherAlgorithm.floydSteinberg: [
    [1, 0, 7 / 16],
    [-1, 1, 3 / 16],
    [0, 1, 5 / 16],
    [1, 1, 1 / 16],
  ],
  DitherAlgorithm.stucki: [
    [1, 0, 8 / 42],
    [2, 0, 4 / 42],
    [-2, 1, 2 / 42],
    [-1, 1, 4 / 42],
    [0, 1, 8 / 42],
    [1, 1, 4 / 42],
    [2, 1, 2 / 42],
    [-2, 2, 1 / 42],
    [-1, 2, 2 / 42],
    [0, 2, 4 / 42],
    [1, 2, 2 / 42],
    [2, 2, 1 / 42],
  ],
  DitherAlgorithm.burkes: [
    [1, 0, 8 / 32],
    [2, 0, 4 / 32],
    [-2, 1, 2 / 32],
    [-1, 1, 4 / 32],
    [0, 1, 8 / 32],
    [1, 1, 4 / 32],
    [2, 1, 2 / 32],
  ],
  DitherAlgorithm.sierra: [
    [1, 0, 5 / 32],
    [2, 0, 3 / 32],
    [-2, 1, 2 / 32],
    [-1, 1, 4 / 32],
    [0, 1, 5 / 32],
    [1, 1, 4 / 32],
    [2, 1, 2 / 32],
    [-1, 2, 2 / 32],
    [0, 2, 3 / 32],
    [1, 2, 2 / 32],
  ],
};

void applyErrorDiffusionDither(
  PixelBuffer buf,
  ColorMethod method,
  List<List<int>> outputPaletteArray,
  List<List<int>> ditherPaletteArray,
  DitherAlgorithm algorithm,
) {
  final width = buf.width;
  final height = buf.height;
  final data = buf.data;

  final errors = Float32List(width * height * 3);
  final matrix = _diffusionMatrices[algorithm]!;

  // Pre-compute LAB values for dither palette if using LAB method
  final ditherPaletteLab = method == ColorMethod.lab
      ? ditherPaletteArray
            .map(
              (c) =>
                  rgbToLab(c[0].toDouble(), c[1].toDouble(), c[2].toDouble()),
            )
            .toList()
      : null;

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final idx = (y * width + x) * 4;
      final errIdx = (y * width + x) * 3;

      final oldR = (data[idx] + errors[errIdx]).clamp(0.0, 255.0);
      final oldG = (data[idx + 1] + errors[errIdx + 1]).clamp(0.0, 255.0);
      final oldB = (data[idx + 2] + errors[errIdx + 2]).clamp(0.0, 255.0);

      final colorIdx = findClosestColor(
        oldR,
        oldG,
        oldB,
        method,
        ditherPaletteArray,
        ditherPaletteLab,
      );

      final newR = outputPaletteArray[colorIdx][0];
      final newG = outputPaletteArray[colorIdx][1];
      final newB = outputPaletteArray[colorIdx][2];

      data[idx] = newR;
      data[idx + 1] = newG;
      data[idx + 2] = newB;

      final ditherR = ditherPaletteArray[colorIdx][0];
      final ditherG = ditherPaletteArray[colorIdx][1];
      final ditherB = ditherPaletteArray[colorIdx][2];
      final errR = oldR - ditherR;
      final errG = oldG - ditherG;
      final errB = oldB - ditherB;

      for (final entry in matrix) {
        final nx = x + entry[0].toInt();
        final ny = y + entry[1].toInt();
        final weight = entry[2];

        if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
          final nextIdx = (ny * width + nx) * 3;
          errors[nextIdx] += errR * weight;
          errors[nextIdx + 1] += errG * weight;
          errors[nextIdx + 2] += errB * weight;
        }
      }
    }
  }
}

// ============================================================
// Preprocessing pipeline
// ============================================================

void preprocessImage(
  PixelBuffer buf,
  ProcessingParams params,
  Palette perceived,
) {
  // 1. Exposure
  if (params.exposure != 1.0) {
    applyExposure(buf, params.exposure);
  }

  // 2. Saturation
  if (params.saturation != 1.0) {
    applySaturation(buf, params.saturation);
  }

  // 3. Tone mapping
  if (params.toneMode == ToneMode.contrast) {
    if (params.contrast != 1.0) {
      applyContrast(buf, params.contrast);
    }
  } else {
    applyScurveTonemap(
      buf,
      params.strength,
      params.shadowBoost,
      params.highlightCompress,
      params.midpoint,
    );
  }

  // 4. Compress dynamic range to display's actual luminance range
  if (params.compressDynamicRange) {
    final blackL = rgbToLab(
      perceived.black.r.toDouble(),
      perceived.black.g.toDouble(),
      perceived.black.b.toDouble(),
    )[0];
    final whiteL = rgbToLab(
      perceived.white.r.toDouble(),
      perceived.white.g.toDouble(),
      perceived.white.b.toDouble(),
    )[0];

    final d = buf.data;
    for (var i = 0; i < d.length; i += 4) {
      final lab = rgbToLab(
        d[i].toDouble(),
        d[i + 1].toDouble(),
        d[i + 2].toDouble(),
      );
      final compressedL = blackL + (lab[0] / 100) * (whiteL - blackL);
      final rgb = labToRgb(compressedL, lab[1], lab[2]);
      d[i] = rgb[0];
      d[i + 1] = rgb[1];
      d[i + 2] = rgb[2];
    }
  }
}

// ============================================================
// EPDGZ output
// ============================================================

/// Map theoretical palette RGB to a 4-bit palette index. For grayscale (GC16)
/// the value maps to a 0-15 gray level; otherwise to the Spectra-6 index.
int rgbToPaletteIndex(int r, int g, int b, {bool grayscale = false}) {
  if (grayscale) {
    return ((r / 255.0) * 15).round().clamp(0, 15);
  }
  if (r == 0 && g == 0 && b == 0) return 0; // Black
  if (r == 255 && g == 255 && b == 255) return 1; // White
  if (r == 255 && g == 255 && b == 0) return 2; // Yellow
  if (r == 255 && g == 0 && b == 0) return 3; // Red
  if (r == 0 && g == 0 && b == 255) return 5; // Blue
  if (r == 0 && g == 255 && b == 0) return 6; // Green
  return 1; // Default white
}

/// Create EPDGZ (4-bit gzipped raw e-paper data) from processed pixel buffer.
Uint8List createEpdgz(PixelBuffer buf, {bool grayscale = false}) {
  final width = buf.width;
  final height = buf.height;
  final data = buf.data;

  final rawBuffer = Uint8List((width * height + 1) ~/ 2);
  var byteIdx = 0;
  final padIndex = grayscale ? 15 : 1; // white padding

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x += 2) {
      final idx1 = (y * width + x) * 4;
      final p1 = rgbToPaletteIndex(
        data[idx1],
        data[idx1 + 1],
        data[idx1 + 2],
        grayscale: grayscale,
      );

      var p2 = padIndex;
      if (x + 1 < width) {
        final idx2 = (y * width + x + 1) * 4;
        p2 = rgbToPaletteIndex(
          data[idx2],
          data[idx2 + 1],
          data[idx2 + 2],
          grayscale: grayscale,
        );
      }

      rawBuffer[byteIdx++] = (p1 << 4) | (p2 & 0x0f);
    }
  }

  return Uint8List.fromList(gzip.encode(rawBuffer));
}

// ============================================================
// Main processing function
// ============================================================

class ProcessResult {
  /// The processed image (dithered to e-paper palette).
  final img.Image processed;

  /// The original image resized to display dimensions (before dithering).
  final img.Image original;

  /// EPDGZ data ready to send to the device.
  final Uint8List epdgz;

  const ProcessResult({
    required this.processed,
    required this.original,
    required this.epdgz,
  });
}

/// Prepared (decoded + resized) image ready for processing.
/// Cached between parameter changes to avoid re-decoding and re-resizing.
class PreparedImage {
  final Uint8List rgbaData;
  final int width;
  final int height;
  final Uint8List? bgMask; // 1 = background pixel, 0 = image pixel

  const PreparedImage({
    required this.rgbaData,
    required this.width,
    required this.height,
    this.bgMask,
  });
}

class _ProcessParams {
  final Uint8List rgbaData;
  final int width;
  final int height;
  final Uint8List? bgMask;
  final ProcessingParams params;
  final bool usePerceivedOutput;
  final int nativeWidth;
  final int nativeHeight;
  final String? orientation;
  final String backgroundColor;
  final PalettePair palette;

  const _ProcessParams({
    required this.rgbaData,
    required this.width,
    required this.height,
    this.bgMask,
    required this.params,
    required this.usePerceivedOutput,
    required this.nativeWidth,
    required this.nativeHeight,
    this.orientation,
    required this.backgroundColor,
    required this.palette,
  });
}

/// Prepare from an already-decoded [img.Image] (no JPEG decode needed).
/// Resize/crop to display dimensions based on scale mode.
PreparedImage prepareFromImage(
  img.Image source, {
  required int displayWidth,
  required int displayHeight,
  ScaleMode scaleMode = ScaleMode.cover,
  String backgroundColor = 'white',
  double zoom = 1.0,
  double panX = 0,
  double panY = 0,
  PalettePair palette = defaultPalette,
}) {
  img.Image resized;
  List<bool>? bgMaskBool;

  switch (scaleMode) {
    case ScaleMode.cover:
      resized = _resizeCover(source, displayWidth, displayHeight);
    case ScaleMode.fit:
      final bgColor =
          palette.theoretical[backgroundColor] ?? palette.theoretical.black;
      final result = _resizeFit(source, displayWidth, displayHeight, bgColor);
      resized = result.$1;
      bgMaskBool = result.$2;
    case ScaleMode.custom:
      final bgColor =
          palette.theoretical[backgroundColor] ?? palette.theoretical.black;
      final result = _resizeCustom(
        source,
        displayWidth,
        displayHeight,
        bgColor,
        zoom,
        panX,
        panY,
      );
      resized = result.$1;
      bgMaskBool = result.$2;
  }

  final buf = PixelBuffer.fromImage(resized);

  Uint8List? bgMask;
  if (bgMaskBool != null) {
    bgMask = Uint8List(bgMaskBool.length);
    for (var i = 0; i < bgMaskBool.length; i++) {
      if (bgMaskBool[i]) bgMask[i] = 1;
    }
  }

  return PreparedImage(
    rgbaData: buf.data,
    width: buf.width,
    height: buf.height,
    bgMask: bgMask,
  );
}

/// Process a prepared image for preview (perceived output).
/// Runs synchronously on the calling isolate — the buffer is small enough
/// (display resolution) that isolate spawn + data copy overhead exceeds
/// the compute cost.  Returns PNG bytes of the dithered preview.
Uint8List processPreview(
  PreparedImage prepared, {
  ProcessingParams params = const ProcessingParams(),
  String backgroundColor = 'white',
  PalettePair palette = defaultPalette,
}) {
  return _processInIsolate(
    _ProcessParams(
      rgbaData: prepared.rgbaData,
      width: prepared.width,
      height: prepared.height,
      bgMask: prepared.bgMask,
      params: params,
      usePerceivedOutput: true,
      nativeWidth: prepared.width,
      nativeHeight: prepared.height,
      backgroundColor: backgroundColor,
      palette: palette,
    ),
  );
}

/// Process a prepared image for device output in a background isolate.
/// Returns EPDGZ bytes ready to send to the device.
Future<Uint8List> processForDeviceInBackground(
  PreparedImage prepared, {
  ProcessingParams params = const ProcessingParams(),
  required int nativeWidth,
  required int nativeHeight,
  String? orientation,
  String backgroundColor = 'white',
  PalettePair palette = defaultPalette,
}) {
  return Isolate.run(
    () => _processInIsolate(
      _ProcessParams(
        rgbaData: prepared.rgbaData,
        width: prepared.width,
        height: prepared.height,
        bgMask: prepared.bgMask,
        params: params,
        usePerceivedOutput: false,
        nativeWidth: nativeWidth,
        nativeHeight: nativeHeight,
        orientation: orientation,
        backgroundColor: backgroundColor,
        palette: palette,
      ),
    ),
  );
}

/// Encode a prepared image as a JPEG thumbnail in a background isolate.
///
/// The thumbnail uses the post-layout RGBA buffer from [PreparedImage],
/// which means scaleMode (cover / fit / custom), zoom+pan, and the chosen
/// background colour are already baked in — gallery thumbnails match what
/// the device actually displays. Dithering is skipped so the thumbnail
/// stays clean at small sizes.
Future<Uint8List> generateThumbnailJpegInBackground(
  PreparedImage prepared, {
  int maxDimension = 400,
  int quality = 85,
}) {
  return Isolate.run(
    () => _encodeThumbnailJpeg(
      rgbaData: prepared.rgbaData,
      width: prepared.width,
      height: prepared.height,
      maxDimension: maxDimension,
      quality: quality,
    ),
  );
}

Uint8List _encodeThumbnailJpeg({
  required Uint8List rgbaData,
  required int width,
  required int height,
  required int maxDimension,
  required int quality,
}) {
  // Reconstruct an img.Image from the RGBA buffer (post-layout, pre-dither).
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      image.setPixelRgba(
        x,
        y,
        rgbaData[i],
        rgbaData[i + 1],
        rgbaData[i + 2],
        255,
      );
    }
  }

  // Downscale so the longest side is <= maxDimension, preserving aspect.
  final scale = math.min(maxDimension / width, maxDimension / height);
  final img.Image output = scale < 1.0
      ? img.copyResize(
          image,
          width: (width * scale).round(),
          height: (height * scale).round(),
        )
      : image;

  return Uint8List.fromList(img.encodeJpg(output, quality: quality));
}

/// Unified processing: preprocess, dither, and encode.
/// Returns PNG bytes for preview or EPDGZ bytes for device.
dynamic _processInIsolate(_ProcessParams p) {
  // Copy buffer since preprocessing modifies in place
  final buf = PixelBuffer(Uint8List.fromList(p.rgbaData), p.width, p.height);

  preprocessImage(buf, p.params, p.palette.perceived);

  final outputPalette = p.usePerceivedOutput
      ? p.palette.perceived
      : p.palette.theoretical;
  final outputPaletteArray = outputPalette.toArray();
  final ditherPaletteArray = p.palette.perceived.toArray();

  applyErrorDiffusionDither(
    buf,
    p.params.colorMethod,
    outputPaletteArray,
    ditherPaletteArray,
    p.params.ditherAlgorithm,
  );

  // Clean background pixels after dithering
  if (p.bgMask != null) {
    final cleanBg = outputPalette[p.backgroundColor] ?? outputPalette.black;
    final d = buf.data;
    for (var i = 0; i < p.bgMask!.length; i++) {
      if (p.bgMask![i] == 1) {
        d[i * 4] = cleanBg.r;
        d[i * 4 + 1] = cleanBg.g;
        d[i * 4 + 2] = cleanBg.b;
      }
    }
  }

  if (p.usePerceivedOutput) {
    // Preview: encode as PNG
    return Uint8List.fromList(img.encodePng(buf.toImage()));
  } else {
    // Device: rotate to native layout if needed, encode as EPDGZ
    final nativeIsLandscape = p.nativeWidth > p.nativeHeight;
    final orientIsLandscape = p.orientation == null
        ? nativeIsLandscape
        : p.orientation != 'portrait';
    final needsRotation = nativeIsLandscape != orientIsLandscape;
    final grayscale = isGrayscalePalette(p.palette);

    if (needsRotation) {
      final rotated = img.copyRotate(buf.toImage(), angle: 90);
      return createEpdgz(PixelBuffer.fromImage(rotated), grayscale: grayscale);
    } else {
      return createEpdgz(buf, grayscale: grayscale);
    }
  }
}

enum ScaleMode { cover, fit, custom }

/// Resize image with "fit" mode (letterbox). Returns image + background mask.
/// Background pixels are filled with [bgColor], mask[i]=true for background pixels.
(img.Image, List<bool>) _resizeFit(
  img.Image source,
  int outW,
  int outH,
  PaletteColor bgColor,
) {
  final scale = math.min(outW / source.width, outH / source.height);
  final scaledW = (source.width * scale).round();
  final scaledH = (source.height * scale).round();
  final offsetX = (outW - scaledW) ~/ 2;
  final offsetY = (outH - scaledH) ~/ 2;

  final output = img.Image(width: outW, height: outH);
  img.fill(output, color: img.ColorUint8.rgb(bgColor.r, bgColor.g, bgColor.b));

  final scaled = img.copyResize(
    source,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.linear,
  );
  img.compositeImage(output, scaled, dstX: offsetX, dstY: offsetY);

  // Build background mask
  final mask = List<bool>.filled(outW * outH, false);
  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      if (x < offsetX ||
          x >= offsetX + scaledW ||
          y < offsetY ||
          y >= offsetY + scaledH) {
        mask[y * outW + x] = true;
      }
    }
  }

  return (output, mask);
}

/// Resize image with "custom" mode (zoom + pan). Returns image + background mask.
///
/// Places the source at (panX, panY) scaled to (srcW*zoom, srcH*zoom) in
/// an outW x outH frame, clipping as needed (matching JS ctx.drawImage behavior).
(img.Image, List<bool>) _resizeCustom(
  img.Image source,
  int outW,
  int outH,
  PaletteColor bgColor,
  double zoom,
  double panX,
  double panY,
) {
  final scaledW = (source.width * zoom).round();
  final scaledH = (source.height * zoom).round();
  final px = panX.round();
  final py = panY.round();

  final output = img.Image(width: outW, height: outH);
  img.fill(output, color: img.ColorUint8.rgb(bgColor.r, bgColor.g, bgColor.b));

  // Scale source, then blit with clipping (handles negative offsets and overflow)
  if (scaledW > 0 && scaledH > 0) {
    final scaled = img.copyResize(
      source,
      width: scaledW,
      height: scaledH,
      interpolation: img.Interpolation.linear,
    );
    // Compute visible region
    final srcX0 = math.max(0, -px);
    final srcY0 = math.max(0, -py);
    final dstX0 = math.max(0, px);
    final dstY0 = math.max(0, py);
    final copyW = math.min(scaledW - srcX0, outW - dstX0);
    final copyH = math.min(scaledH - srcY0, outH - dstY0);

    for (var y = 0; y < copyH; y++) {
      for (var x = 0; x < copyW; x++) {
        final p = scaled.getPixel(srcX0 + x, srcY0 + y);
        output.setPixel(dstX0 + x, dstY0 + y, p);
      }
    }
  }

  // Build background mask
  final mask = List<bool>.filled(outW * outH, false);
  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      if (x < px || x >= px + scaledW || y < py || y >= py + scaledH) {
        mask[y * outW + x] = true;
      }
    }
  }

  return (output, mask);
}

/// Resize image with "cover" mode (scale + center crop).
img.Image _resizeCover(img.Image source, int outW, int outH) {
  final srcAspect = source.width / source.height;
  final dstAspect = outW / outH;

  int scaledW, scaledH;
  if (srcAspect > dstAspect) {
    scaledH = outH;
    scaledW = (source.width * outH / source.height).round();
  } else {
    scaledW = outW;
    scaledH = (source.height * outW / source.width).round();
  }

  final scaled = img.copyResize(
    source,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.linear,
  );
  final cropX = (scaledW - outW) ~/ 2;
  final cropY = (scaledH - outH) ~/ 2;
  return img.copyCrop(scaled, x: cropX, y: cropY, width: outW, height: outH);
}

/// Process an image for e-paper display.
///
/// [nativeWidth]/[nativeHeight] are the panel's native dimensions.
/// [orientation] is "landscape", "portrait", or null (native).
/// [scaleMode] is cover (crop), fit (letterbox), or custom (zoom/pan).
/// [backgroundColor] palette color name for fit/custom background.
ProcessResult processImage(
  Uint8List imageBytes, {
  int nativeWidth = 800,
  int nativeHeight = 480,
  String? orientation,
  PalettePair palette = defaultPalette,
  ProcessingParams params = const ProcessingParams(),
  bool usePerceivedOutput = false,
  ScaleMode scaleMode = ScaleMode.cover,
  String backgroundColor = 'white',
  double zoom = 1.0,
  double panX = 0,
  double panY = 0,
}) {
  // Decode image
  var source = img.decodeImage(imageBytes);
  if (source == null) {
    throw ArgumentError('Failed to decode image');
  }

  // Apply EXIF orientation and clear the tag so copyResize doesn't re-apply
  source = img.bakeOrientation(source);
  source.exif.imageIfd.orientation = 1;

  // Determine if we need to swap processing dimensions.
  final nativeIsLandscape = nativeWidth > nativeHeight;
  final orientIsLandscape = orientation == null
      ? nativeIsLandscape
      : orientation != 'portrait';
  final needsRotation = nativeIsLandscape != orientIsLandscape;

  var displayWidth = nativeWidth;
  var displayHeight = nativeHeight;
  if (needsRotation) {
    displayWidth = nativeHeight;
    displayHeight = nativeWidth;
  }

  // Resize based on scale mode
  img.Image resized;
  List<bool>? bgMask;

  switch (scaleMode) {
    case ScaleMode.cover:
      resized = _resizeCover(source, displayWidth, displayHeight);

    case ScaleMode.fit:
      final bgColor =
          palette.theoretical[backgroundColor] ?? palette.theoretical.black;
      final result = _resizeFit(source, displayWidth, displayHeight, bgColor);
      resized = result.$1;
      bgMask = result.$2;

    case ScaleMode.custom:
      final bgColor =
          palette.theoretical[backgroundColor] ?? palette.theoretical.black;
      final result = _resizeCustom(
        source,
        displayWidth,
        displayHeight,
        bgColor,
        zoom,
        panX,
        panY,
      );
      resized = result.$1;
      bgMask = result.$2;
  }

  // Save original for preview
  final originalImage = resized.clone();

  // Convert to pixel buffer for processing
  final buf = PixelBuffer.fromImage(resized);

  // Preprocess (exposure, saturation, tone mapping, dynamic range compression)
  preprocessImage(buf, params, palette.perceived);

  // Dither
  final outputPalette = usePerceivedOutput
      ? palette.perceived
      : palette.theoretical;
  final outputPaletteArray = outputPalette.toArray();
  final ditherPaletteArray = palette.perceived.toArray();

  applyErrorDiffusionDither(
    buf,
    params.colorMethod,
    outputPaletteArray,
    ditherPaletteArray,
    params.ditherAlgorithm,
  );

  // Replace background pixels with clean palette color after dithering.
  // Dithering can introduce artifacts in uniform background areas.
  if (bgMask != null) {
    final cleanPal = usePerceivedOutput
        ? palette.perceived
        : palette.theoretical;
    final cleanBg = cleanPal[backgroundColor] ?? cleanPal.black;
    final d = buf.data;
    for (var i = 0; i < bgMask.length; i++) {
      if (bgMask[i]) {
        d[i * 4] = cleanBg.r;
        d[i * 4 + 1] = cleanBg.g;
        d[i * 4 + 2] = cleanBg.b;
      }
    }
  }

  // Build output image (in user's orientation)
  final processedImage = buf.toImage();

  // For EPDGZ: rotate to native panel layout if needed
  Uint8List epdgz;
  final grayscale = isGrayscalePalette(palette);
  if (needsRotation) {
    final rotated = img.copyRotate(processedImage, angle: 90);
    final outputBuf = PixelBuffer.fromImage(rotated);
    epdgz = createEpdgz(outputBuf, grayscale: grayscale);
  } else {
    epdgz = createEpdgz(buf, grayscale: grayscale);
  }

  return ProcessResult(
    processed: processedImage,
    original: originalImage,
    epdgz: epdgz,
  );
}
