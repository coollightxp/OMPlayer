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
  /// 所有播放源地址（同名频道合并后可能有多个）
  final List<String> streamUrls;
  final String categoryId;
  final bool isFavorite;
  /// EPG 频道标识（用于匹配 XMLTV 节目单）
  final String tvgId;
  /// 节目单中的频道名称（tvg-name）
  final String tvgName;
  /// 分组标题（group-title）
  final String groupTitle;
  /// 播放该频道流时要求的 HTTP User-Agent（M3U 的 http-user-agent 属性，
  /// 例如 APTV 源必须带 AptvPlayer-UA，否则服务器返回 404）
  final String userAgent;

  /// 默认播放源（第一个）
  String get streamUrl => streamUrls.first;

  /// 是否为网页频道（TVBox 等源里的 webview:// 链接，
  /// 如 webview://https://www.yangshipin.cn/...）
  bool get isWebPage =>
      streamUrls.isNotEmpty &&
      streamUrls.first.trim().toLowerCase().startsWith('webview://');

  /// 网页频道要打开的真实网址（剥掉 webview:// 前缀）
  String get webPageUrl {
    var inner = streamUrls.first.trim().substring('webview://'.length);
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(inner)) {
      inner = 'https://$inner';
    }
    return inner;
  }

  const Channel({
    required this.id,
    required this.name,
    this.logoUrl = '',
    required this.streamUrls,
    required this.categoryId,
    this.isFavorite = false,
    this.tvgId = '',
    this.tvgName = '',
    this.groupTitle = '',
    this.userAgent = '',
  });

  Channel copyWith({
    String? id,
    String? name,
    String? logoUrl,
    List<String>? streamUrls,
    String? categoryId,
    bool? isFavorite,
    String? tvgId,
    String? tvgName,
    String? groupTitle,
    String? userAgent,
  }) {
    return Channel(
      id: id ?? this.id,
      name: name ?? this.name,
      logoUrl: logoUrl ?? this.logoUrl,
      streamUrls: streamUrls ?? this.streamUrls,
      categoryId: categoryId ?? this.categoryId,
      isFavorite: isFavorite ?? this.isFavorite,
      tvgId: tvgId ?? this.tvgId,
      tvgName: tvgName ?? this.tvgName,
      groupTitle: groupTitle ?? this.groupTitle,
      userAgent: userAgent ?? this.userAgent,
    );
  }
}
