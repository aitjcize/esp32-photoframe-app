class Album {
  final String name;
  final bool enabled;

  const Album({required this.name, required this.enabled});

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

class PhotoInfo {
  final String filename;
  final String album;
  final String? thumbnail;

  const PhotoInfo({
    required this.filename,
    required this.album,
    this.thumbnail,
  });

  factory PhotoInfo.fromJson(Map<String, dynamic> json) {
    return PhotoInfo(
      filename: json['filename'] as String? ?? '',
      album: json['album'] as String? ?? '',
      thumbnail: json['thumbnail'] as String?,
    );
  }

  /// Full path as "album/filename" for API calls.
  String get filepath => '$album/$filename';
}
