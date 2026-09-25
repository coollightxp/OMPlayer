import 'dart:convert';

/// EPG 节目单来源
class EpgSource {
  final String id;
  final String name;     // 用户自定义名称
  final String url;      // EPG XMLTV 数据地址
  final DateTime addedAt;
  final DateTime? lastUpdated;

  const EpgSource({
    required this.id,
    required this.name,
    required this.url,
    required this.addedAt,
    this.lastUpdated,
  });

  EpgSource copyWith({
    String? id,
    String? name,
    String? url,
    DateTime? addedAt,
    DateTime? lastUpdated,
  }) {
    return EpgSource(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      addedAt: addedAt ?? this.addedAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'addedAt': addedAt.toIso8601String(),
        'lastUpdated': lastUpdated?.toIso8601String(),
      };

  factory EpgSource.fromJson(Map<String, dynamic> json) {
    return EpgSource(
      id: json['id'] as String,
      name: json['name'] as String,
      url: json['url'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : null,
    );
  }

  static String encodeList(List<EpgSource> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<EpgSource> decodeList(String str) {
    final List<dynamic> decoded = jsonDecode(str) as List<dynamic>;
    return decoded
        .map((e) => EpgSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
