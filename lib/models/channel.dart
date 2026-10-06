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

  /// 回看类型（M3U catchup 属性）：default / dvr / flussonic / dash /
  /// append 等；空串表示源未声明回看
  final String catchupType;

  /// 回看地址模板（M3U catchup-source 属性），可能含
  /// {start}/{end}/{utc}/{duration} 占位符（Unix 秒）
  final String catchupSource;

  /// 支持回看的天数（M3U catchup-days 属性），null 表示未声明
  final int? catchupDays;

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
    this.catchupType = '',
    this.catchupSource = '',
    this.catchupDays,
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
    String? catchupType,
    String? catchupSource,
    int? catchupDays,
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
      catchupType: catchupType ?? this.catchupType,
      catchupSource: catchupSource ?? this.catchupSource,
      catchupDays: catchupDays ?? this.catchupDays,
    );
  }

  /// 该频道是否声明了回看能力
  bool get hasCatchup =>
      catchupType.isNotEmpty || catchupSource.trim().isNotEmpty;

  /// 构造某节目的回看播放地址；无法构造（无模板/无地址）时返回 null。
  ///
  /// 模板优先取节目自身的 [epgCatchupSource]（XMLTV catchup-source），
  /// 其次频道的 catchup-source。占位符（Unix 秒）：
  /// [start]/[utc] 开始、[end]/[utcend] 结束、[duration] 时长。
  /// catchup=append 或模板为相对路径时拼到直播地址后。
  String? buildCatchupUrl({
    required DateTime start,
    required DateTime end,
    String? epgCatchupSource,
  }) {
    final template = (epgCatchupSource?.trim().isNotEmpty ?? false)
        ? epgCatchupSource!.trim()
        : catchupSource.trim();
    if (template.isEmpty) return null;
    final startSec = start.millisecondsSinceEpoch ~/ 1000;
    final endSec = end.millisecondsSinceEpoch ~/ 1000;
    final durationSec = endSec - startSec;

    String applyPlaceholders(String t) => t
        .replaceAll('{start}', '$startSec')
        .replaceAll('{utc}', '$startSec')
        .replaceAll('{end}', '$endSec')
        .replaceAll('{utcend}', '$endSec')
        .replaceAll('{duration}', '$durationSec')
        .replaceAll('\$start', '$startSec')
        .replaceAll('\$end', '$endSec');

    if (template.startsWith('http://') || template.startsWith('https://')) {
      return applyPlaceholders(template);
    }
    // append 模式或相对模板：拼到当前直播地址
    if (catchupType.toLowerCase() == 'append' ||
        !template.startsWith('{')) {
      final base = streamUrl;
      if (base.isEmpty) return null;
      // 以 / 开头的相对路径：同源绝对路径，拼到直播地址的源站根
      // （flussonic 常见 /mono/timeshift_rel/... 形式）
      if (template.startsWith('/')) {
        final uri = Uri.tryParse(base);
        if (uri == null ||
            uri.host.isEmpty ||
            !(uri.isScheme('HTTP') || uri.isScheme('HTTPS'))) {
          return null;
        }
        return applyPlaceholders('${uri.origin}$template');
      }
      final sep = base.contains('?') ? '&' : '?';
      return '$base$sep${applyPlaceholders(template)}';
    }
    // 模板以占位符开头（如 {utc}/... 这类残缺声明）：无法可靠构造
    return applyPlaceholders(template);
  }
}
