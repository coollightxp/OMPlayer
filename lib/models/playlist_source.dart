import 'dart:convert';

/// 播放列表来源类型
enum PlaylistSourceType {
  url,    // 网络地址
  local,  // 本地文件
}

/// 播放列表文件格式
enum PlaylistFormat {
  m3u,
  txt,
  unknown,
}

/// 播放列表源 - 用户添加的频道列表来源
class PlaylistSource {
  final String id;
  final String name;           // 用户自定义名称
  final String url;            // URL 或本地文件路径
  final PlaylistSourceType type;
  final PlaylistFormat format;
  final DateTime addedAt;
  final DateTime? lastUpdated;

  const PlaylistSource({
    required this.id,
    required this.name,
    required this.url,
    required this.type,
    required this.format,
    required this.addedAt,
    this.lastUpdated,
  });

  PlaylistSource copyWith({
    String? id,
    String? name,
    String? url,
    PlaylistSourceType? type,
    PlaylistFormat? format,
    DateTime? addedAt,
    DateTime? lastUpdated,
  }) {
    return PlaylistSource(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      type: type ?? this.type,
      format: format ?? this.format,
      addedAt: addedAt ?? this.addedAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'type': type.name,
        'format': format.name,
        'addedAt': addedAt.toIso8601String(),
        'lastUpdated': lastUpdated?.toIso8601String(),
      };

  factory PlaylistSource.fromJson(Map<String, dynamic> json) {
    return PlaylistSource(
      id: json['id'] as String,
      name: json['name'] as String,
      url: json['url'] as String,
      type: PlaylistSourceType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => PlaylistSourceType.url,
      ),
      format: PlaylistFormat.values.firstWhere(
        (e) => e.name == json['format'],
        orElse: () => PlaylistFormat.unknown,
      ),
      addedAt: DateTime.parse(json['addedAt'] as String),
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
    );
  }

  static String encodeList(List<PlaylistSource> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<PlaylistSource> decodeList(String str) {
    final List<dynamic> decoded = jsonDecode(str) as List<dynamic>;
    return decoded
        .map((e) => PlaylistSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
