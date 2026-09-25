import '../models/channel.dart';

/// 播放列表解析器 - 支持 M3U 和 TXT 格式
class PlaylistParser {
  /// 根据内容判断格式
  static PlaylistFormat detectFormat(String content, String url) {
    if (content.trimLeft().startsWith('#EXTM3U')) {
      return PlaylistFormat.m3u;
    }
    // TXT 格式通常是 "频道名,URL" 或 "分组,频道名,URL"
    final lines = content
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'))
        .toList();
    if (lines.isNotEmpty) {
      final first = lines.first.trim();
      // 检查是否是逗号分隔的 TXT 格式
      if (first.contains(',')) {
        return PlaylistFormat.txt;
      }
    }
    // 根据 URL 扩展名判断
    final lower = url.toLowerCase();
    if (lower.endsWith('.m3u') || lower.endsWith('.m3u8')) {
      return PlaylistFormat.m3u;
    }
    if (lower.endsWith('.txt')) {
      return PlaylistFormat.txt;
    }
    return PlaylistFormat.unknown;
  }

  /// 解析播放列表内容，返回按分类分组的频道列表
  static List<ChannelCategory> parse(
      String content, PlaylistFormat format) {
    switch (format) {
      case PlaylistFormat.m3u:
        return _parseM3U(content);
      case PlaylistFormat.txt:
        return _parseTxt(content);
      case PlaylistFormat.unknown:
        // 尝试两种格式
        final m3uResult = _parseM3U(content);
        if (m3uResult.isNotEmpty) return m3uResult;
        return _parseTxt(content);
    }
  }

  /// 解析 M3U 格式
  /// 格式示例：
  /// #EXTM3U
  /// #EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV-1" tvg-logo="http://..." group-title="新闻",CCTV-1 综合
  /// http://stream.url/cctv1.m3u8
  static List<ChannelCategory> _parseM3U(String content) {
    final lines = content.split('\n');
    final channels = <Channel>[];
    String? pendingInfo;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        pendingInfo = line;
      } else if (!line.startsWith('#')) {
        // 这是一个流地址
        if (pendingInfo != null) {
          final channel = _parseExtInf(pendingInfo, line);
          if (channel != null) channels.add(channel);
          pendingInfo = null;
        } else {
          // 没有 EXTINF 信息，用 URL 作为名称
          channels.add(Channel(
            id: _genId(line),
            name: Uri.tryParse(line)?.pathSegments.lastOrNull ?? line,
            streamUrl: line,
            categoryId: '未分类',
            groupTitle: '未分类',
          ));
        }
      }
    }

    return _groupChannels(channels);
  }

  static Channel? _parseExtInf(String extInf, String url) {
    try {
      // 提取逗号后面的频道名
      final commaIdx = extInf.lastIndexOf(',');
      final name = commaIdx >= 0
          ? extInf.substring(commaIdx + 1).trim()
          : url;
      if (name.isEmpty) return null;

      // 提取属性
      final attrs = <String, String>{};
      final attrStr = extInf.substring(0, commaIdx >= 0 ? commaIdx : extInf.length);
      final regExp = RegExp(r'([a-zA-Z-]+)="([^"]*)"');
      for (final match in regExp.allMatches(attrStr)) {
        attrs[match.group(1)!] = match.group(2) ?? '';
      }

      final groupTitle = attrs['group-title'] ?? '未分类';
      final tvgId = attrs['tvg-id'] ?? '';
      final tvgName = attrs['tvg-name'] ?? name;
      final logo = attrs['tvg-logo'] ?? '';

      return Channel(
        id: _genId(url),
        name: name,
        streamUrl: url,
        logoUrl: logo,
        categoryId: groupTitle,
        groupTitle: groupTitle,
        tvgId: tvgId,
        tvgName: tvgName,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 TXT 格式
  /// 支持两种格式：
  /// 1. "频道名,URL"
  /// 2. "分组,频道名,URL"
  static List<ChannelCategory> _parseTxt(String content) {
    final lines = content.split('\n');
    final channels = <Channel>[];
    String currentGroup = '未分类';

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final parts = line.split(',').map((p) => p.trim()).toList();
      if (parts.length < 2) continue;

      String group, name, url;
      if (parts.length >= 3) {
        // 分组,频道名,URL
        group = parts[0];
        name = parts[1];
        url = parts.sublist(2).join(',');
      } else {
        // 频道名,URL
        group = currentGroup;
        name = parts[0];
        url = parts[1];
      }

      if (name.isEmpty || url.isEmpty) continue;

      channels.add(Channel(
        id: _genId(url),
        name: name,
        streamUrl: url,
        categoryId: group,
        groupTitle: group,
      ));
    }

    return _groupChannels(channels);
  }

  /// 按分类对频道分组
  static List<ChannelCategory> _groupChannels(List<Channel> channels) {
    final map = <String, List<Channel>>{};
    for (final ch in channels) {
      final key = ch.groupTitle.isEmpty ? '未分类' : ch.groupTitle;
      map.putIfAbsent(key, () => []).add(ch);
    }

    return map.entries.map((e) {
      return ChannelCategory(
        id: e.key,
        name: e.key,
        channels: e.value,
      );
    }).toList();
  }

  static String _genId(String url) {
    return 'ch_${url.hashCode.abs()}';
  }
}

enum PlaylistFormat { m3u, txt, unknown }
