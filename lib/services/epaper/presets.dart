// Image processing presets for e-paper displays.

enum ToneMode { contrast, scurve }

enum ColorMethod { rgb, lab }

enum DitherAlgorithm { floydSteinberg, stucki, burkes, sierra }

class ProcessingParams {
  final double exposure;
  final double saturation;
  final ToneMode toneMode;
  final double contrast;
  final double strength;
  final double shadowBoost;
  final double highlightCompress;
  final double midpoint;
  final ColorMethod colorMethod;
  final DitherAlgorithm ditherAlgorithm;
  final bool compressDynamicRange;

  const ProcessingParams({
    this.exposure = 1.0,
    this.saturation = 1.0,
    this.toneMode = ToneMode.contrast,
    this.contrast = 1.0,
    this.strength = 0.9,
    this.shadowBoost = 0.0,
    this.highlightCompress = 1.5,
    this.midpoint = 0.5,
    this.colorMethod = ColorMethod.rgb,
    this.ditherAlgorithm = DitherAlgorithm.floydSteinberg,
    this.compressDynamicRange = true,
  });

  ProcessingParams copyWith({
    double? exposure,
    double? saturation,
    ToneMode? toneMode,
    double? contrast,
    double? strength,
    double? shadowBoost,
    double? highlightCompress,
    double? midpoint,
    ColorMethod? colorMethod,
    DitherAlgorithm? ditherAlgorithm,
    bool? compressDynamicRange,
  }) {
    return ProcessingParams(
      exposure: exposure ?? this.exposure,
      saturation: saturation ?? this.saturation,
      toneMode: toneMode ?? this.toneMode,
      contrast: contrast ?? this.contrast,
      strength: strength ?? this.strength,
      shadowBoost: shadowBoost ?? this.shadowBoost,
      highlightCompress: highlightCompress ?? this.highlightCompress,
      midpoint: midpoint ?? this.midpoint,
      colorMethod: colorMethod ?? this.colorMethod,
      ditherAlgorithm: ditherAlgorithm ?? this.ditherAlgorithm,
      compressDynamicRange: compressDynamicRange ?? this.compressDynamicRange,
    );
  }
}

/// Balanced — general use, prevents overexposure.
const balanced = ProcessingParams();

/// Dynamic — enhanced contrast, more vibrant.
const dynamicPreset = ProcessingParams(
  saturation: 1.3,
  toneMode: ToneMode.scurve,
  strength: 0.9,
  shadowBoost: 0.0,
  highlightCompress: 1.5,
  midpoint: 0.5,
  compressDynamicRange: false,
);

/// Vivid — boosted colors for colorful images.
const vivid = ProcessingParams(
  exposure: 1.1,
  saturation: 1.6,
  toneMode: ToneMode.scurve,
  strength: 0.7,
  shadowBoost: 0.1,
  highlightCompress: 1.3,
  midpoint: 0.5,
  compressDynamicRange: false,
);

/// Soft — lower contrast, better gradient rendering.
const soft = ProcessingParams(
  saturation: 1.1,
  toneMode: ToneMode.contrast,
  contrast: 0.9,
  ditherAlgorithm: DitherAlgorithm.stucki,
);

/// Grayscale — LAB color space for B&W photos.
const grayscale = ProcessingParams(
  saturation: 0.0,
  toneMode: ToneMode.contrast,
  contrast: 1.0,
  colorMethod: ColorMethod.lab,
);

const presets = <String, ProcessingParams>{
  'balanced': balanced,
  'dynamic': dynamicPreset,
  'vivid': vivid,
  'soft': soft,
  'grayscale': grayscale,
};
