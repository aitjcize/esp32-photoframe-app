import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/device_provider.dart';
import 'package:image/image.dart' as img;

import '../services/epaper/image_processor.dart' as epaper;
import '../services/epaper/presets.dart';
import '../services/epaper/palettes.dart';

/// Full image processing preview screen with adjustable parameters.
class PreviewScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final String filename;
  final String? album;
  final Map<String, dynamic>? initialSettings;

  const PreviewScreen({
    super.key,
    required this.imageBytes,
    required this.filename,
    this.album,
    this.initialSettings,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  // Scale mode
  epaper.ScaleMode _scaleMode = epaper.ScaleMode.cover;
  String _backgroundColor = 'white';
  double _zoom = 1.0;
  double _panX = 0;
  double _panY = 0;

  // Processing params
  String _presetName = 'balanced';
  double _exposure = 1.0;
  double _saturation = 1.0;
  double _contrast = 1.0;
  ToneMode _toneMode = ToneMode.contrast;
  double _strength = 0.9;
  double _shadowBoost = 0.0;
  double _highlightCompress = 1.5;
  double _midpoint = 0.5;
  ColorMethod _colorMethod = ColorMethod.rgb;
  DitherAlgorithm _ditherAlgorithm = DitherAlgorithm.floydSteinberg;
  bool _compressDynamicRange = true;

  // Source image (decoded once natively via dart:ui)
  int _srcWidth = 0;
  int _srcHeight = 0;
  Uint8List? _orientedSourceBytes; // Original bytes for live preview
  img.Image? _decodedSource; // Natively decoded, cached for reuse

  // Cached prepared (resized to display dims) image — reused across param changes
  epaper.PreparedImage? _prepared;

  // State
  bool _initializing = true; // true until settings loaded and image decoded
  bool _processing = false;
  bool _uploading = false;
  int _processGeneration =
      0; // increments each processImage call to ignore stale results
  bool _isTouching = false; // true while finger is down in custom mode
  bool _isDragging =
      false; // true from first touch until dithered result arrives
  Uint8List? _previewBytes;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadDeviceSettings();
  }

  Future<void> _loadDeviceSettings() async {
    // Apply pre-fetched settings if available
    if (widget.initialSettings != null) {
      _applyFromJson(widget.initialSettings!);
    } else if (_isGrayscale) {
      // New grayscale frame with no saved settings: default to the grayscale
      // preset (tuned for monochrome) rather than the color default.
      _applyPreset('grayscale');
    }

    // Use original bytes for live preview — Flutter handles EXIF natively
    _orientedSourceBytes = widget.imageBytes;

    // Show editor immediately, decode dimensions in background
    if (mounted) setState(() => _initializing = false);

    // Decode image natively via dart:ui at ~2x display resolution.
    // This uses the platform's native JPEG decoder (libjpeg-turbo/ImageIO)
    // which is orders of magnitude faster than the pure Dart image package.
    final (fw, fh) = _displayDims;
    final targetDim = math.max(fw, fh) * 2;

    // Get original dimensions to determine which axis to constrain
    final dimsCodec = await ui.instantiateImageCodec(widget.imageBytes);
    final dimsFrame = await dimsCodec.getNextFrame();
    final origW = dimsFrame.image.width;
    final origH = dimsFrame.image.height;
    dimsFrame.image.dispose();
    dimsCodec.dispose();

    // Decode at reduced resolution — constrain the longer side
    final codec = await ui.instantiateImageCodec(
      widget.imageBytes,
      targetWidth: origW > origH ? targetDim : null,
      targetHeight: origH >= origW ? targetDim : null,
    );
    final frame = await codec.getNextFrame();
    final uiImage = frame.image;
    _srcWidth = uiImage.width;
    _srcHeight = uiImage.height;

    // Extract raw RGBA pixels and create img.Image for processing
    final byteData = await uiImage.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    uiImage.dispose();
    codec.dispose();

    if (byteData != null) {
      _decodedSource = img.Image.fromBytes(
        width: _srcWidth,
        height: _srcHeight,
        bytes: byteData.buffer,
        numChannels: 4,
      );
    }

    // Auto-select scale mode based on image vs display orientation
    if (_srcWidth > 0 && _srcHeight > 0) {
      final imageIsLandscape = _srcWidth > _srcHeight;
      final displayIsLandscape = fw > fh;
      if (imageIsLandscape != displayIsLandscape) {
        _scaleMode = epaper.ScaleMode.fit;
      }
    }

    if (mounted) setState(() {});

    // Prepare and start dithering
    _prepareAndProcess();
  }

  void _applyFromJson(Map<String, dynamic> json) {
    setState(() {
      _presetName = 'custom';
      _exposure = (json['exposure'] as num?)?.toDouble() ?? 1.0;
      _saturation = (json['saturation'] as num?)?.toDouble() ?? 1.0;
      _contrast = (json['contrast'] as num?)?.toDouble() ?? 1.0;
      _toneMode = json['toneMode'] == 'scurve'
          ? ToneMode.scurve
          : ToneMode.contrast;
      _strength = (json['strength'] as num?)?.toDouble() ?? 0.9;
      _shadowBoost = (json['shadowBoost'] as num?)?.toDouble() ?? 0.0;
      _highlightCompress =
          (json['highlightCompress'] as num?)?.toDouble() ?? 1.5;
      _midpoint = (json['midpoint'] as num?)?.toDouble() ?? 0.5;
      _colorMethod = json['colorMethod'] == 'lab'
          ? ColorMethod.lab
          : ColorMethod.rgb;
      _ditherAlgorithm = _parseDitherAlgorithm(
        json['ditherAlgorithm'] as String? ?? 'floyd-steinberg',
      );
      _compressDynamicRange = json['compressDynamicRange'] as bool? ?? true;

      // Check if this matches a preset. Compare floats with a tolerance: the
      // device persists them as 32-bit, so e.g. 1.4 round-trips as 1.39999998
      // and an exact compare would always fall back to "custom".
      bool approx(double a, double b) => (a - b).abs() < 1e-3;
      for (final entry in presets.entries) {
        final p = entry.value;
        if (approx(p.exposure, _exposure) &&
            approx(p.saturation, _saturation) &&
            approx(p.contrast, _contrast) &&
            p.toneMode == _toneMode &&
            p.colorMethod == _colorMethod &&
            p.ditherAlgorithm == _ditherAlgorithm &&
            p.compressDynamicRange == _compressDynamicRange) {
          _presetName = entry.key;
          break;
        }
      }
    });
  }

  DitherAlgorithm _parseDitherAlgorithm(String name) {
    switch (name) {
      case 'stucki':
        return DitherAlgorithm.stucki;
      case 'burkes':
        return DitherAlgorithm.burkes;
      case 'sierra':
        return DitherAlgorithm.sierra;
      default:
        return DitherAlgorithm.floydSteinberg;
    }
  }

  /// True when the target device is a grayscale (GC16) panel.
  bool get _isGrayscale =>
      context.read<DeviceProvider>().systemInfo?.isGrayscale ?? false;

  /// Palette to process with: the 16-level gray ramp for grayscale panels,
  /// otherwise the default 6-color Spectra palette. For grayscale panels the
  /// perceived ramp is calibrated to the device's measured luminance endpoints
  /// (falling back to the package defaults when the device doesn't report them).
  PalettePair get _palette {
    if (!_isGrayscale) return defaultPalette;
    final provider = context.read<DeviceProvider>();
    // makeGrayscale16 defaults each endpoint independently, so any subset the
    // device reports is honored and the rest fall back to the package defaults.
    return makeGrayscale16(
      blackY: provider.grayBlackY,
      whiteY: provider.grayWhiteY,
      gamma: provider.grayGamma,
    );
  }

  /// Get the effective display dimensions (accounting for orientation swap).
  (int, int) get _displayDims {
    final provider = context.read<DeviceProvider>();
    final sysInfo = provider.systemInfo;
    final config = provider.config;
    var w = sysInfo?.displayWidth ?? 800;
    var h = sysInfo?.displayHeight ?? 480;
    final isPortrait = config?.displayOrientation == 'portrait';
    if (isPortrait == (w > h)) {
      final tmp = w;
      w = h;
      h = tmp;
    }
    return (w, h);
  }

  /// Initialize zoom/pan for custom mode: fit-inside-frame, centered.
  void _initCustomZoomPan() {
    if (_srcWidth == 0 || _srcHeight == 0) return;
    final (fw, fh) = _displayDims;
    final fitScale = math.min(fw / _srcWidth, fh / _srcHeight).toDouble();
    _zoom = fitScale;
    _panX = (fw - _srcWidth * fitScale) / 2;
    _panY = (fh - _srcHeight * fitScale) / 2;
  }

  double _lastScale = 1.0;

  /// Build the dithered preview with fixed container matching display aspect ratio.
  Widget _buildDitheredPreview() {
    final (fw, fh) = _displayDims;
    final containerWidth = MediaQuery.of(context).size.width - 32;
    final containerHeight = containerWidth * fh / fw;

    return SizedBox(
      width: containerWidth,
      height: containerHeight,
      child: Image.memory(
        _previewBytes!,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.none,
      ),
    );
  }

  /// Build a live source preview for cover/fit modes while processing.
  /// Shows the original image fitted to the display aspect ratio.
  Widget _buildLiveSourcePreview() {
    final (fw, fh) = _displayDims;
    final containerWidth = MediaQuery.of(context).size.width - 32;
    final containerHeight = containerWidth * fh / fw;

    final bgColor = _backgroundColor == 'black' ? Colors.black : Colors.white;

    return SizedBox(
      width: containerWidth,
      height: containerHeight,
      child: ColoredBox(
        color: bgColor,
        child: Image.memory(
          _orientedSourceBytes ?? widget.imageBytes,
          fit: _scaleMode == epaper.ScaleMode.cover
              ? BoxFit.cover
              : BoxFit.contain,
        ),
      ),
    );
  }

  /// Build a live preview showing the original image at current zoom/pan.
  /// Used during custom mode dragging for instant visual feedback.
  ///
  /// The processor places the image at (panX, panY) with size
  /// (srcW * zoom, srcH * zoom) in a (displayW x displayH) frame.
  /// We map this to screen coordinates proportionally.
  Widget _buildLiveCustomPreview() {
    final (fw, fh) = _displayDims;
    // Container fills available width, height follows aspect ratio
    final containerWidth = MediaQuery.of(context).size.width - 32;
    final containerHeight = containerWidth * fh / fw;
    // display-to-screen ratio
    final s = containerWidth / fw;

    final bgColor = _backgroundColor == 'black' ? Colors.black : Colors.white;

    // Image size and position in screen coords
    final imgW = _srcWidth * _zoom * s;
    final imgH = _srcHeight * _zoom * s;
    final imgX = _panX * s;
    final imgY = _panY * s;

    return SizedBox(
      width: containerWidth,
      height: containerHeight,
      child: ClipRect(
        child: ColoredBox(
          color: bgColor,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: imgX,
                top: imgY,
                width: imgW,
                height: imgH,
                child: Image.memory(
                  _orientedSourceBytes ?? widget.imageBytes,
                  fit: BoxFit.fill,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onCustomScaleUpdate(ScaleUpdateDetails details) {
    final (fw, fh) = _displayDims;
    final screenWidth = MediaQuery.of(context).size.width - 32;
    // Screen-to-display ratio
    final ratio = fw / screenWidth;

    setState(() {
      _isDragging = true;

      // Pan: convert screen delta to display coords
      _panX += details.focalPointDelta.dx * ratio;
      _panY += details.focalPointDelta.dy * ratio;

      // Pinch zoom around focal point
      if (details.scale != 1.0) {
        final zoomFactor = details.scale / _lastScale;
        final fitScale = math.min(fw / _srcWidth, fh / _srcHeight).toDouble();
        final maxZoom =
            math.max(fw / _srcWidth, fh / _srcHeight).toDouble() * 5;
        final newZoom = (_zoom * zoomFactor).clamp(fitScale * 0.25, maxZoom);

        // Adjust pan to keep the focal point fixed
        // Focal point in display coords
        final focalX = details.localFocalPoint.dx * ratio;
        final focalY = details.localFocalPoint.dy * ratio;

        // The focal point maps to (focalX - panX) / (srcW * zoom) in image space
        // After zoom change, we want this ratio preserved:
        // (focalX - newPanX) / (srcW * newZoom) = (focalX - panX) / (srcW * zoom)
        // => newPanX = focalX - (focalX - panX) * newZoom / zoom
        _panX = focalX - (focalX - _panX) * newZoom / _zoom;
        _panY = focalY - (focalY - _panY) * newZoom / _zoom;
        _zoom = newZoom;
      }
      _lastScale = details.scale;
    });
    // No debounce — only process on finger lift (onScaleEnd)
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _applyPreset(String name) {
    final preset = presets[name];
    if (preset == null) return;
    setState(() {
      _presetName = name;
      _exposure = preset.exposure;
      _saturation = preset.saturation;
      _contrast = preset.contrast;
      _toneMode = preset.toneMode;
      _strength = preset.strength;
      _shadowBoost = preset.shadowBoost;
      _highlightCompress = preset.highlightCompress;
      _midpoint = preset.midpoint;
      _colorMethod = preset.colorMethod;
      _ditherAlgorithm = preset.ditherAlgorithm;
      _compressDynamicRange = preset.compressDynamicRange;
    });
  }

  ProcessingParams _buildParams() {
    return ProcessingParams(
      exposure: _exposure,
      saturation: _saturation,
      contrast: _contrast,
      toneMode: _toneMode,
      strength: _strength,
      shadowBoost: _shadowBoost,
      highlightCompress: _highlightCompress,
      midpoint: _midpoint,
      colorMethod: _colorMethod,
      ditherAlgorithm: _ditherAlgorithm,
      compressDynamicRange: _compressDynamicRange,
    );
  }

  void _onParamChanged() {
    _presetName = 'custom';
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _processPreview);
  }

  /// Trigger full re-prepare + process (for layout/scale/background changes).
  void _onLayoutChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _prepareAndProcess);
  }

  /// Prepare (resize/crop) then process preview.
  /// Called on initial load and layout changes (scale mode, zoom, pan, bg color).
  Future<void> _prepareAndProcess({bool force = false}) async {
    if (_isTouching && !force) return;
    if (_decodedSource == null) return;

    final generation = ++_processGeneration;
    setState(() => _processing = true);

    final (fw, fh) = _displayDims;

    try {
      // Resize/crop the cached decoded image (no JPEG decode, synchronous)
      final prepared = epaper.prepareFromImage(
        _decodedSource!,
        displayWidth: fw,
        displayHeight: fh,
        scaleMode: _scaleMode,
        backgroundColor: _backgroundColor,
        zoom: _zoom,
        panX: _panX,
        panY: _panY,
        palette: _palette,
      );

      if (!mounted || generation != _processGeneration) return;

      _prepared = prepared;

      // Process preview (preprocess + dither, synchronous)
      await _processPreviewWith(prepared, generation);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        if (!_isTouching) _isDragging = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Processing failed: $e')));
    }
  }

  /// Process preview only, reusing the cached prepared image.
  /// Called on processing parameter changes (exposure, saturation, etc.).
  Future<void> _processPreview() async {
    if (_prepared == null) {
      // No cached image yet, do full prepare + process
      return _prepareAndProcess();
    }

    final generation = ++_processGeneration;
    setState(() => _processing = true);

    try {
      await _processPreviewWith(_prepared!, generation);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        if (!_isTouching) _isDragging = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Processing failed: $e')));
    }
  }

  /// Run preview processing on a prepared image.
  Future<void> _processPreviewWith(
    epaper.PreparedImage prepared,
    int generation,
  ) async {
    final params = _buildParams();

    final previewPng = epaper.processPreview(
      prepared,
      params: params,
      backgroundColor: _backgroundColor,
      palette: _palette,
    );

    if (!mounted || generation != _processGeneration) return;

    setState(() {
      _previewBytes = previewPng;
      _processing = false;
      if (!_isTouching) _isDragging = false;
    });
  }

  void _showSendingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(message),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Process for device output on demand.
  Future<Uint8List?> _processForDevice() async {
    if (_prepared == null) return null;

    final provider = context.read<DeviceProvider>();
    final sysInfo = provider.systemInfo;
    final config = provider.config;

    return epaper.processForDeviceInBackground(
      _prepared!,
      params: _buildParams(),
      nativeWidth: sysInfo?.displayWidth ?? 800,
      nativeHeight: sysInfo?.displayHeight ?? 480,
      orientation: config?.displayOrientation,
      backgroundColor: _backgroundColor,
      palette: _palette,
    );
  }

  /// Display on frame — stays in editor after completion.
  Future<void> _displayImage() async {
    if (_prepared == null) return;
    final api = context.read<DeviceProvider>().apiClient;
    if (api == null) return;

    setState(() => _uploading = true);
    _showSendingDialog('Sending to display...');

    try {
      final epdgz = await _processForDevice();
      if (epdgz == null || !mounted) return;

      await api.displayImage(epdgz, '${widget.filename}.epdgz');
      if (!mounted) return;
      Navigator.pop(context); // dismiss spinner
      setState(() => _uploading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Image displayed')));
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // dismiss spinner
      setState(() => _uploading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  /// Upload to album — closes editor after completion.
  Future<void> _uploadToAlbum() async {
    if (_prepared == null) return;
    final api = context.read<DeviceProvider>().apiClient;
    if (api == null) return;

    final album = widget.album ?? 'Default';

    setState(() => _uploading = true);
    _showSendingDialog('Uploading to album...');

    try {
      // Process for device and generate thumbnail in parallel.
      // The thumbnail is encoded from the post-layout prepared image so
      // cover / fit / custom scale modes (and zoom+pan) are reflected in
      // the gallery preview, matching what the device actually shows.
      if (_prepared == null) return;
      final results = await Future.wait([
        _processForDevice(),
        epaper.generateThumbnailJpegInBackground(
          _prepared!,
          maxDimension: 400,
          quality: 85,
        ),
      ]);

      final epdgz = results[0];
      final thumbnailJpg = results[1]!;
      if (epdgz == null || !mounted) return;

      // Derive a short, unique basename from (filename + upload timestamp)
      // so two photos that share a name (e.g. "IMG_1234.jpg") don't collide
      // in the device album. 32-bit FNV-1a over the payload, padded with a
      // base-36 millisecond suffix for 12 chars total. Matches the webapp
      // and CLI algorithms so the scheme stays consistent across clients.
      final uploadTs = DateTime.now().millisecondsSinceEpoch;
      final payload = '${widget.filename}:$uploadTs';
      var fnv = 0x811c9dc5;
      for (var i = 0; i < payload.length; i++) {
        fnv ^= payload.codeUnitAt(i);
        fnv = (fnv * 0x01000193) & 0xffffffff;
      }
      final tsSuffix = uploadTs
          .toRadixString(36)
          .substring(math.max(0, uploadTs.toRadixString(36).length - 4));
      final baseName = fnv.toRadixString(16).padLeft(8, '0') + tsSuffix;

      await api.uploadImage(
        album,
        epdgz,
        '$baseName.epdgz',
        thumbnailBytes: thumbnailJpg,
        thumbnailFilename: '$baseName.jpg',
      );
      if (!mounted) return;
      Navigator.pop(context); // dismiss spinner
      Navigator.pop(context, true); // close editor
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Image uploaded')));
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // dismiss spinner
      setState(() => _uploading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Image Processing')),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading...'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Image Processing'),
        actions: [
          IconButton(
            onPressed: _prepared != null && !_uploading && !_processing
                ? _displayImage
                : null,
            icon: const Icon(Icons.cast),
            tooltip: 'Display on frame',
          ),
          IconButton(
            onPressed: _prepared != null && !_uploading && !_processing
                ? _uploadToAlbum
                : null,
            icon: const Icon(Icons.upload),
            tooltip: 'Upload to album',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        physics: _isTouching ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.all(16),
        children: [
          // Preview image — always show something
          if (true) ...[
            Stack(
              alignment: Alignment.topRight,
              children: [
                GestureDetector(
                  onScaleStart: _scaleMode == epaper.ScaleMode.custom
                      ? (_) {
                          _debounce?.cancel();
                          setState(() {
                            _isTouching = true;
                            _isDragging = true;
                            _lastScale = 1.0;
                          });
                        }
                      : null,
                  onScaleUpdate: _scaleMode == epaper.ScaleMode.custom
                      ? _onCustomScaleUpdate
                      : null,
                  onScaleEnd: _scaleMode == epaper.ScaleMode.custom
                      ? (_) {
                          _debounce?.cancel();
                          setState(() => _isTouching = false);
                          _prepareAndProcess(force: true);
                        }
                      : null,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: () {
                      // Custom mode drag: show live pan/zoom preview
                      if (_isDragging &&
                          _scaleMode == epaper.ScaleMode.custom &&
                          _srcWidth > 0) {
                        return _buildLiveCustomPreview();
                      }
                      // Show previous/current dithered result (spinner overlays during processing)
                      if (_previewBytes != null) {
                        return _buildDitheredPreview();
                      }
                      // No dithered result yet (initial load): show live source preview
                      if (_srcWidth > 0) {
                        if (_scaleMode == epaper.ScaleMode.custom) {
                          return _buildLiveCustomPreview();
                        }
                        return _buildLiveSourcePreview();
                      }
                      // Nothing decoded yet: show raw image at display aspect ratio
                      final (fw, fh) = _displayDims;
                      final cw = MediaQuery.of(context).size.width - 32;
                      return SizedBox(
                        width: cw,
                        height: cw * fh / fw,
                        child: Image.memory(
                          widget.imageBytes,
                          fit: BoxFit.cover,
                        ),
                      );
                    }(),
                  ),
                ),
                if (_processing && !_isTouching)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(6),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Scale mode
          Text('Layout', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<epaper.ScaleMode>(
            segments: const [
              ButtonSegment(
                value: epaper.ScaleMode.cover,
                label: Text('Cover'),
                icon: Icon(Icons.crop),
              ),
              ButtonSegment(
                value: epaper.ScaleMode.fit,
                label: Text('Fit'),
                icon: Icon(Icons.fit_screen),
              ),
              ButtonSegment(
                value: epaper.ScaleMode.custom,
                label: Text('Custom'),
                icon: Icon(Icons.pan_tool),
              ),
            ],
            selected: {_scaleMode},
            onSelectionChanged: (v) {
              _debounce?.cancel();
              final mode = v.first;
              setState(() {
                _scaleMode = mode;
                if (mode == epaper.ScaleMode.custom) {
                  _initCustomZoomPan();
                  _isDragging = true; // show live preview immediately
                  _processGeneration++; // invalidate any in-flight processing
                }
              });
              // For cover/fit, prepare + dither immediately. For custom, wait for finger lift.
              if (mode != epaper.ScaleMode.custom) {
                _prepareAndProcess();
              }
            },
          ),
          // Custom mode: drag & pinch instructions
          if (_scaleMode == epaper.ScaleMode.custom)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Drag to pan, pinch to zoom on the preview above',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          // Background color (only for fit/custom)
          if (_scaleMode != epaper.ScaleMode.cover) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Background',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const Spacer(),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'white', label: Text('White')),
                    ButtonSegment(value: 'black', label: Text('Black')),
                  ],
                  selected: {_backgroundColor},
                  onSelectionChanged: (v) {
                    setState(() => _backgroundColor = v.first);
                    _onLayoutChanged();
                  },
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),

          // Preset selector
          Text('Preset', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              // Show every preset regardless of panel type (matching the web
              // app): grayscale frames just default to the grayscale preset, but
              // the others stay available -- they also differ in contrast, tone,
              // and exposure, which GC16 panels do render.
              ...presets.keys.map(
                (name) => FilterChip(
                  label: Text(name[0].toUpperCase() + name.substring(1)),
                  selected: _presetName == name,
                  onSelected: (_) {
                    _applyPreset(name);
                    _processPreview();
                  },
                ),
              ),
              FilterChip(
                label: const Text('Custom'),
                selected: _presetName == 'custom',
                onSelected: null,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Dithering algorithm
          _buildDropdown<DitherAlgorithm>(
            'Dithering Algorithm',
            _ditherAlgorithm,
            {
              DitherAlgorithm.floydSteinberg: 'Floyd-Steinberg',
              DitherAlgorithm.stucki: 'Stucki',
              DitherAlgorithm.burkes: 'Burkes',
              DitherAlgorithm.sierra: 'Sierra',
            },
            (v) {
              setState(() => _ditherAlgorithm = v);
              _onParamChanged();
            },
          ),
          const SizedBox(height: 8),

          // Color method
          _buildDropdown<ColorMethod>(
            'Color Matching',
            _colorMethod,
            {ColorMethod.rgb: 'RGB', ColorMethod.lab: 'LAB'},
            (v) {
              setState(() => _colorMethod = v);
              _onParamChanged();
            },
          ),
          const SizedBox(height: 16),

          // Exposure
          _buildSlider('Exposure', _exposure, 0.5, 2.0, (v) {
            setState(() => _exposure = v);
            _onParamChanged();
          }),

          // Saturation (hidden on grayscale panels — has no effect)
          if (!_isGrayscale)
            _buildSlider('Saturation', _saturation, 0.0, 2.0, (v) {
              setState(() => _saturation = v);
              _onParamChanged();
            }),

          // Tone mode
          _buildDropdown<ToneMode>(
            'Tone Mapping',
            _toneMode,
            {ToneMode.contrast: 'Contrast', ToneMode.scurve: 'S-Curve'},
            (v) {
              setState(() => _toneMode = v);
              _onParamChanged();
            },
          ),
          const SizedBox(height: 8),

          // Contrast (only in contrast mode)
          if (_toneMode == ToneMode.contrast)
            _buildSlider('Contrast', _contrast, 0.5, 2.0, (v) {
              setState(() => _contrast = v);
              _onParamChanged();
            }),

          // S-curve params (only in scurve mode)
          if (_toneMode == ToneMode.scurve) ...[
            _buildSlider('Strength', _strength, 0.0, 1.0, (v) {
              setState(() => _strength = v);
              _onParamChanged();
            }),
            _buildSlider('Shadow Boost', _shadowBoost, 0.0, 1.0, (v) {
              setState(() => _shadowBoost = v);
              _onParamChanged();
            }),
            _buildSlider('Highlight Compress', _highlightCompress, 0.5, 5.0, (
              v,
            ) {
              setState(() => _highlightCompress = v);
              _onParamChanged();
            }),
            _buildSlider('Midpoint', _midpoint, 0.3, 0.7, (v) {
              setState(() => _midpoint = v);
              _onParamChanged();
            }),
          ],

          // Compress dynamic range
          SwitchListTile(
            title: const Text('Compress Dynamic Range'),
            subtitle: const Text(
              'Map brightness to display\'s actual white/black point',
            ),
            value: _compressDynamicRange,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) {
              setState(() => _compressDynamicRange = v);
              _onParamChanged();
            },
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            Text(
              value.toStringAsFixed(2),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: (_) {}, // debounce handles reprocess
        ),
      ],
    );
  }

  Widget _buildDropdown<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T> onChanged,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        DropdownButton<T>(
          value: value,
          underline: const SizedBox(),
          items: options.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}
