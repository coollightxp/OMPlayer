/// 频道分类 - 用于左侧两级抽屉的第一级
class ChannelCategory {
  final String id;
  final String name;
  final String iconUrl;
  final List<Channel> channels;

  const ChannelCategory({
    required this.id,
    required this.name,
    this.iconUrl = '',
    this.channels = const [],
  });

  ChannelCategory copyWith({
    String? id,
    String? name,
    String? iconUrl,
    List<Channel>? channels,
  }) {
    return ChannelCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      iconUrl: iconUrl ?? this.iconUrl,
      channels: channels ?? this.channels,
    );
  }
}

/// 直播频道
class Channel {
  final String id;
  final String name;
  final String logoUrl;
  final String streamUrl;
  final String categoryId;
  final bool isFavorite;
  /// EPG 频道标识（用于匹配 XMLTV 节目单）
  final String tvgId;
  /// 节目单中的频道名称（tvg-name）
  final String tvgName;
  /// 分组标题（group-title）
  final String groupTitle;

  const Channel({
    required this.id,
    required this.name,
    this.logoUrl = '',
    required this.streamUrl,
    required this.categoryId,
    this.isFavorite = false,
    this.tvgId = '',
    this.tvgName = '',
    this.groupTitle = '',
  });

  Channel copyWith({
    String? id,
    String? name,
    String? logoUrl,
    String? streamUrl,
    String? categoryId,
    bool? isFavorite,
    String? tvgId,
    String? tvgName,
    String? groupTitle,
  }) {
    return Channel(
      id: id ?? this.id,
      name: name ?? this.name,
      logoUrl: logoUrl ?? this.logoUrl,
      streamUrl: streamUrl ?? this.streamUrl,
      categoryId: categoryId ?? this.categoryId,
      isFavorite: isFavorite ?? this.isFavorite,
      tvgId: tvgId ?? this.tvgId,
      tvgName: tvgName ?? this.tvgName,
      groupTitle: groupTitle ?? this.groupTitle,
    );
  }
}
