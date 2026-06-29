import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/album.dart' show Album, PhotoInfo;
import '../providers/device_provider.dart';
import '../services/saved_devices.dart';
import 'ai_generation_screen.dart';
import 'preview_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  String? _selectedAlbum;
  List<PhotoInfo> _images = [];
  bool _loadingImages = false;
  final Set<String> _selectedImages = {}; // filepaths of selected images
  bool get _isSelecting => _selectedImages.isNotEmpty;
  bool _navigatingAway = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      if (!mounted) return;
      final provider = context.read<DeviceProvider>();
      await provider.refreshAll();
      // Re-save device with real name from system-info
      if (provider.device != null) {
        await SavedDevices.addDevice(provider.device!);
      }
      if (provider.albums.isNotEmpty) {
        _selectAlbum(provider.albums.first.name);
      }
    });
  }

  Future<void> _selectAlbum(String album) async {
    final provider = context.read<DeviceProvider>();

    // Show cached images immediately
    final cached = await provider.loadCachedImages(album);
    if (mounted) {
      setState(() {
        _selectedAlbum = album;
        _images = cached;
        _loadingImages = cached.isEmpty;
      });
    }

    // Refresh from device in background
    try {
      final api = provider.apiClient;
      if (api == null) {
        if (mounted) setState(() => _loadingImages = false);
        return;
      }
      final images = await api.getImages(album);
      if (mounted && _selectedAlbum == album) {
        setState(() {
          _images = images;
          _loadingImages = false;
        });
      }
      provider.saveCachedImages(album, images);
    } catch (e) {
      if (mounted) {
        setState(() => _loadingImages = false);
        if (_images.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to load images: $e')));
        }
      }
    }
  }

  Future<void> _rotateImage() async {
    final provider = context.read<DeviceProvider>();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Updating display...'),
          ],
        ),
        duration: Duration(seconds: 60),
      ),
    );
    try {
      await provider.rotateImage();
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Display updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _openAiGeneration() async {
    final imageBytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => const AiGenerationScreen()),
    );
    if (imageBytes == null || !mounted) return;

    // Open the image editor with the generated image
    final processingSettings = context
        .read<DeviceProvider>()
        .processingSettings;

    final uploaded = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(
          imageBytes: imageBytes,
          filename: 'ai-generated-${DateTime.now().millisecondsSinceEpoch}.png',
          album: _selectedAlbum,
          initialSettings: processingSettings,
        ),
      ),
    );

    if (uploaded == true && _selectedAlbum != null && mounted) {
      _selectAlbum(_selectedAlbum!);
    }
  }

  Future<void> _showImageSourcePicker() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null) _pickAndProcess(source);
  }

  Future<void> _pickAndProcess(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    // Use cached processing settings from background refresh
    final processingSettings = context
        .read<DeviceProvider>()
        .processingSettings;

    final uploaded = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(
          imageBytes: bytes,
          filename: picked.name,
          album: _selectedAlbum,
          initialSettings: processingSettings,
        ),
      ),
    );

    // Refresh album if image was uploaded
    if (uploaded == true && _selectedAlbum != null && mounted) {
      _selectAlbum(_selectedAlbum!);
    }
  }

  Future<void> _onImageTap(PhotoInfo image) async {
    final provider = context.read<DeviceProvider>();
    final thumbPath = image.thumbnail != null
        ? '${image.album}/${image.thumbnail}'
        : image.filepath;
    final imageUrl = provider.apiClient!.getImageUrl(thumbPath);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display Image'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                placeholder: (_, _) => const SizedBox(
                  height: 100,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (_, _, _) =>
                    const Icon(Icons.broken_image, size: 48),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Display this image on the photoframe?'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Display'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Show persistent updating status
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Updating display...'),
          ],
        ),
        duration: Duration(seconds: 60), // stays until replaced
      ),
    );

    try {
      await provider.apiClient!.displayByPath(image.filepath);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Display updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _createAlbum() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Album'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: 'Album name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;

    try {
      final provider = context.read<DeviceProvider>();
      await provider.apiClient!.createAlbum(name.trim());
      await provider.refreshAlbums();
      _selectAlbum(name.trim());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create album: $e')));
      }
    }
  }

  Future<void> _toggleAlbumEnabled(Album album, bool enabled) async {
    try {
      await context.read<DeviceProvider>().setAlbumEnabled(album.name, enabled);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                enabled
                    ? 'Auto-rotation enabled for "${album.name}"'
                    : 'Auto-rotation disabled for "${album.name}"',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to update album: $e')));
      }
    }
  }

  Future<void> _deleteAlbum(String albumName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Album'),
        content: Text('Delete album "$albumName" and all its images?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    try {
      final provider = context.read<DeviceProvider>();
      await provider.apiClient!.deleteAlbum(albumName);
      await provider.refreshAlbums();
      if (mounted) {
        if (_selectedAlbum == albumName) {
          setState(() {
            _selectedAlbum = null;
            _images = [];
          });
          if (provider.albums.isNotEmpty) {
            _selectAlbum(provider.albums.first.name);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete album: $e')));
      }
    }
  }

  Future<void> _deleteSelectedImages() async {
    final count = _selectedImages.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Images'),
        content: Text('Delete $count selected image(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    final api = context.read<DeviceProvider>().apiClient;
    if (api == null) return;

    int deleted = 0;
    for (final filepath in _selectedImages.toList()) {
      try {
        await api.deleteImage(filepath);
        deleted++;
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _selectedImages.clear());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted $deleted image(s)')));
      if (_selectedAlbum != null) _selectAlbum(_selectedAlbum!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DeviceProvider>();
    final albums = provider.albums;
    final battery = provider.batteryInfo;
    final sysInfo = provider.systemInfo;

    // Navigate back if device goes offline (once only)
    if (provider.deviceOffline && !_navigatingAway) {
      _navigatingAway = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          provider.disconnect();
          context.go('/devices');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Device went offline')));
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: _isSelecting
            ? Text('${_selectedImages.length} selected')
            : Text(sysInfo?.deviceName ?? 'PhotoFrame'),
        leading: _isSelecting
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _selectedImages.clear()),
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  provider.disconnect();
                  context.go('/devices');
                },
              ),
        actions: _isSelecting
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  onPressed: () => setState(() {
                    if (_selectedImages.length == _images.length) {
                      _selectedImages.clear();
                    } else {
                      _selectedImages.addAll(_images.map((i) => i.filepath));
                    }
                  }),
                  tooltip: 'Select all',
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: _deleteSelectedImages,
                  tooltip: 'Delete selected',
                ),
              ]
            : [
                // Rotate button
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => _rotateImage(),
                  tooltip: 'Next image',
                ),
                // Battery icon
                if (battery != null && battery.batteryConnected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message:
                          '${battery.level}% ${battery.charging ? "(charging)" : ""}',
                      child: Icon(
                        battery.charging
                            ? Icons.battery_charging_full
                            : battery.level > 75
                            ? Icons.battery_full
                            : battery.level > 50
                            ? Icons.battery_5_bar
                            : battery.level > 25
                            ? Icons.battery_3_bar
                            : Icons.battery_1_bar,
                        color: battery.level <= 20
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
              ],
      ),
      body: Column(
        children: [
          // Album selector
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              itemCount: albums.length + 1, // +1 for "new album" button
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                if (index == albums.length) {
                  return _NewAlbumButton(onPressed: _createAlbum);
                }
                final album = albums[index];
                return _AlbumChip(
                  album: album,
                  selected: album.name == _selectedAlbum,
                  onTap: () => _selectAlbum(album.name),
                  onToggleEnabled: (value) => _toggleAlbumEnabled(album, value),
                  onDelete: album.name == 'Default'
                      ? null
                      : () => _deleteAlbum(album.name),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),

          // Image grid
          Expanded(
            child: _loadingImages
                ? const Center(child: CircularProgressIndicator())
                : _images.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.photo_library_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        const Text('No images in this album'),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () => _selectAlbum(_selectedAlbum!),
                    child: GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 4,
                          ),
                      itemCount: _images.length,
                      itemBuilder: (context, index) {
                        final image = _images[index];
                        final thumbPath = image.thumbnail != null
                            ? '${image.album}/${image.thumbnail}'
                            : image.filepath;
                        final imageUrl = provider.apiClient!.getImageUrl(
                          thumbPath,
                        );
                        final isSelected = _selectedImages.contains(
                          image.filepath,
                        );
                        return GestureDetector(
                          onTap: _isSelecting
                              ? () => setState(() {
                                  if (isSelected) {
                                    _selectedImages.remove(image.filepath);
                                  } else {
                                    _selectedImages.add(image.filepath);
                                  }
                                })
                              : () => _onImageTap(image),
                          onLongPress: () {
                            if (!_isSelecting) {
                              setState(
                                () => _selectedImages.add(image.filepath),
                              );
                            }
                          },
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                placeholder: (_, _) => Container(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                ),
                                errorWidget: (_, _, _) => Container(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  child: const Icon(Icons.broken_image),
                                ),
                              ),
                              if (isSelected)
                                Container(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.3),
                                  alignment: Alignment.bottomRight,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(
                                      Icons.check_circle,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      size: 24,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'ai',
            onPressed: _openAiGeneration,
            tooltip: 'AI generate image',
            child: const Icon(Icons.auto_awesome),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'pick',
            onPressed: _showImageSourcePicker,
            tooltip: 'Pick & process image',
            child: const Icon(Icons.add_photo_alternate),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          switch (index) {
            case 0:
              break;
            case 1:
              context.go('/settings');
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library),
            label: 'Gallery',
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class _NewAlbumButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _NewAlbumButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 18, color: scheme.onSurface),
              const SizedBox(width: 6),
              Text('New', style: TextStyle(color: scheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumChip extends StatelessWidget {
  final Album album;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback? onDelete;

  const _AlbumChip({
    required this.album,
    required this.selected,
    required this.onTap,
    required this.onToggleEnabled,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = selected
        ? scheme.primary
        : scheme.outline.withValues(alpha: 0.5);
    final background = selected
        ? scheme.primary.withValues(alpha: 0.08)
        : Colors.transparent;

    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: SizedBox(
              width: 20,
              height: 20,
              child: Checkbox(
                value: album.enabled,
                onChanged: (v) => onToggleEnabled(v ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, 6, onDelete == null ? 12 : 4, 6),
              child: Text(
                album.name,
                style: TextStyle(
                  color: selected ? scheme.primary : scheme.onSurface,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
          if (onDelete != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                onTap: onDelete,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
