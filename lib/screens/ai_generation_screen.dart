import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:provider/provider.dart';

import '../providers/device_provider.dart';

/// AI image generation screen.
/// Supports OpenAI (GPT Image, DALL-E) and Google Gemini.
class AiGenerationScreen extends StatefulWidget {
  const AiGenerationScreen({super.key});

  @override
  State<AiGenerationScreen> createState() => _AiGenerationScreenState();
}

class _AiGenerationScreenState extends State<AiGenerationScreen> {
  final _promptController = TextEditingController();
  int _provider = 0; // 0 = OpenAI, 1 = Google Gemini
  String _model = 'gpt-image-1.5';
  bool _generating = false;
  Uint8List? _generatedImage;

  String? _openaiKey;
  String? _googleKey;

  final _openaiModels = const [
    {'title': 'GPT Image 1.5', 'value': 'gpt-image-1.5'},
    {'title': 'GPT Image 1', 'value': 'gpt-image-1'},
    {'title': 'GPT Image 1 Mini', 'value': 'gpt-image-1-mini'},
  ];

  final _geminiModels = const [
    {
      'title': 'Gemini 3.1 Flash Image',
      'value': 'gemini-3.1-flash-image-preview',
    },
    {'title': 'Gemini 3 Pro Image', 'value': 'gemini-3-pro-image-preview'},
    {'title': 'Gemini 2.5 Flash Image', 'value': 'gemini-2.5-flash-image'},
  ];

  @override
  void initState() {
    super.initState();
    final config = context.read<DeviceProvider>().config;
    _openaiKey = config?.openaiApiKey;
    _googleKey = config?.googleApiKey;

    // Default to whichever key is available
    if (_openaiKey != null && _openaiKey!.isNotEmpty) {
      _provider = 0;
      _model = 'gpt-image-1.5';
    } else if (_googleKey != null && _googleKey!.isNotEmpty) {
      _provider = 1;
      _model = 'gemini-3.1-flash-image-preview';
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  bool get _hasApiKeys =>
      (_openaiKey != null && _openaiKey!.isNotEmpty) ||
      (_googleKey != null && _googleKey!.isNotEmpty);

  List<Map<String, String>> get _currentModels =>
      _provider == 0 ? _openaiModels : _geminiModels;

  Future<void> _generate() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _generating = true;
      _generatedImage = null;
    });

    try {
      final config = context.read<DeviceProvider>().config;
      final isPortrait = config?.displayOrientation == 'portrait';
      final apiKey = _provider == 0 ? _openaiKey! : _googleKey!;

      Uint8List imageBytes;

      if (_provider == 0) {
        imageBytes = await _generateOpenAI(apiKey, prompt, isPortrait);
      } else {
        imageBytes = await _generateGemini(apiKey, prompt, isPortrait);
      }

      if (mounted) {
        setState(() => _generatedImage = imageBytes);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Generation failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<Uint8List> _generateOpenAI(
    String apiKey,
    String prompt,
    bool isPortrait,
  ) async {
    final isDalle3 = _model.contains('dall-e-3');
    final isDalle2 = _model.contains('dall-e-2');

    String size;
    if (isDalle3) {
      size = isPortrait ? '1024x1792' : '1792x1024';
    } else if (isDalle2) {
      size = '1024x1024';
    } else {
      size = isPortrait ? '1024x1536' : '1536x1024';
    }

    final body = <String, dynamic>{
      'model': _model,
      'prompt': prompt,
      'n': 1,
      'size': size,
    };

    if (isDalle3) {
      body['quality'] = 'hd';
      body['style'] = 'vivid';
      body['response_format'] = 'b64_json';
    } else if (isDalle2) {
      body['response_format'] = 'b64_json';
    } else {
      body['quality'] = 'high';
    }

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/images/generations'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'OpenAI API error: ${response.statusCode} - ${response.body}',
      );
    }

    final data = jsonDecode(response.body);
    final b64 = data['data']?[0]?['b64_json'] as String?;
    if (b64 != null) {
      return base64Decode(b64);
    }

    final url = data['data']?[0]?['url'] as String?;
    if (url != null) {
      final imgResponse = await http.get(Uri.parse(url));
      if (imgResponse.statusCode == 200) return imgResponse.bodyBytes;
    }

    throw Exception('No image data in response');
  }

  Future<Uint8List> _generateGemini(
    String apiKey,
    String prompt,
    bool isPortrait,
  ) async {
    final provider = context.read<DeviceProvider>();
    final sysInfo = provider.systemInfo;
    final maxDim = math.max(
      sysInfo?.displayWidth ?? 800,
      sysInfo?.displayHeight ?? 480,
    );

    final imageConfig = <String, dynamic>{
      'aspectRatio': isPortrait ? '3:4' : '4:3',
    };

    if (_model.contains('gemini-3')) {
      if (maxDim > 2048) {
        imageConfig['imageSize'] = '4K';
      } else if (maxDim > 1024) {
        imageConfig['imageSize'] = '2K';
      } else {
        imageConfig['imageSize'] = '1K';
      }
    }

    final response = await http.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$apiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['Image'],
          'imageConfig': imageConfig,
        },
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Gemini API error: ${response.statusCode} - ${response.body}',
      );
    }

    final data = jsonDecode(response.body);
    final b64 =
        data['candidates']?[0]?['content']?['parts']?[0]?['inlineData']?['data']
            as String?;
    if (b64 == null) {
      throw Exception('No image data in Gemini response');
    }
    return base64Decode(b64);
  }

  void _useImage() {
    if (_generatedImage == null) return;
    // Return the generated image bytes to the caller
    Navigator.pop(context, _generatedImage);
  }

  Future<void> _saveToGallery() async {
    if (_generatedImage == null) return;
    try {
      await ImageGallerySaverPlus.saveImage(
        _generatedImage!,
        quality: 95,
        name: 'ai-generated-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved to photo album')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Image Generation')),
      body: !_hasApiKeys
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.key_off, size: 48),
                    const SizedBox(height: 16),
                    const Text(
                      'No API keys configured.\n\nGo to Settings and add an OpenAI or Google Gemini API key.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Go Back'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Provider selector
                if ((_openaiKey?.isNotEmpty ?? false) &&
                    (_googleKey?.isNotEmpty ?? false))
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('OpenAI')),
                      ButtonSegment(value: 1, label: Text('Gemini')),
                    ],
                    selected: {_provider},
                    onSelectionChanged: (v) {
                      setState(() {
                        _provider = v.first;
                        _model = _currentModels.first['value']!;
                      });
                    },
                  ),
                const SizedBox(height: 12),

                // Model selector
                DropdownButtonFormField<String>(
                  value: _model,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    border: OutlineInputBorder(),
                  ),
                  items: _currentModels
                      .map(
                        (m) => DropdownMenuItem(
                          value: m['value'],
                          child: Text(m['title']!),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _model = v);
                  },
                ),
                const SizedBox(height: 12),

                // Prompt
                TextField(
                  controller: _promptController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Prompt',
                    hintText: 'Describe the image you want to generate...',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),

                // Generate button
                FilledButton.icon(
                  onPressed: _generating ? null : _generate,
                  icon: _generating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(_generating ? 'Generating...' : 'Generate'),
                ),
                const SizedBox(height: 16),

                // Generated image preview
                if (_generatedImage != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(_generatedImage!, fit: BoxFit.contain),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _useImage,
                          icon: const Icon(Icons.edit),
                          label: const Text('Edit & Display'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _saveToGallery,
                        icon: const Icon(Icons.save_alt),
                        tooltip: 'Save to photo album',
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}
