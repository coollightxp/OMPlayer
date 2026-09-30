import 'dart:convert';

import '../models/channel.dart';

/// 播放列表解析器
/// 支持：
/// - M3U/M3U8（#EXTM3U/#EXTINF，group-title/tvg-logo 等属性）
/// - TVBox / DIYP TXT（"分组,#genre#" 分组行 + "频道名,URL"）
/// - 一行多源（"频道名,URL1#URL2" 或 "频道名,URL1,URL2"）
/// - 旧式 "分组,频道名,URL" 三段格式
class PlaylistParser {
  /// 常见直播流协议前缀
  static final _urlScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// 去掉 UTF-8 BOM（解码后是 U+FEFF）
  static String _stripBom(String s) {
    if (s.startsWith('\uFEFF')) return s.substring(1);
    return s;
  }

  /// 裸地址判定：host:port/path（DIYP/盒子源经常省略 http://）
  static final _bareHost = RegExp(r'^[\w.\-]+:\d{2,5}(/[^\s]*)?$');

  /// 规范化流地址：合法 URL 原样返回；裸 host:port 地址补 http://；
  /// 无法识别返回 null
  static String? _asStreamUrl(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    if (_urlScheme.hasMatch(t)) return t;
    if (_bareHost.hasMatch(t)) return 'http://$t';
    return null;
  }

  /// 无逗号连写行兜底："电台直播http://host/path" → ("电台直播", url)
  static final _gluedUrl =
      RegExp(r'^(.+?)([a-zA-Z][a-zA-Z0-9+.\-]*://\S+)$');

  /// 根据【内容】判断格式（后缀名不可靠：.php 可能返回 M3U 也可能返回
  /// TXT，.nzk 等自定义后缀实际是 TXT）
  static PlaylistFormat detectFormat(String content, String url) {
    final text = _stripBom(content);
    if (text.trimLeft().startsWith('#EXTM3U')) {
      return PlaylistFormat.m3u;
    }

    final lines = const LineSplitter()
        .convert(text)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    bool hasGenre = false;
    bool hasNameUrl = false;
    for (final line in lines) {
      if (line.startsWith('#')) continue;
      // TVBox/DIYP 分组行：分组名,#genre#
      if (line.endsWith(',#genre#') || line.contains(',#genre#')) {
        hasGenre = true;
        continue;
      }
      final idx = line.indexOf(',');
      if (idx > 0) {
        final rest = line.substring(idx + 1).trim();
        final first = rest.split(RegExp(r'[,#]')).first.trim();
        if (rest.isNotEmpty && _asStreamUrl(first) != null) {
          hasNameUrl = true;
        }
      } else if (_gluedUrl.hasMatch(line)) {
        hasNameUrl = true;
      }
    }
    if (hasGenre || hasNameUrl) return PlaylistFormat.txt;

    // 内容无法判定时按 URL 后缀兜底
    final lower = url.toLowerCase();
    if (lower.endsWith('.m3u') || lower.endsWith('.m3u8')) {
      return PlaylistFormat.m3u;
    }
    if (lower.endsWith('.txt') ||
        lower.endsWith('.nzk') ||
        lower.endsWith('.conf') ||
        lower.endsWith('.list')) {
      return PlaylistFormat.txt;
    }
    return PlaylistFormat.unknown;
  }

  /// 解析播放列表内容，返回按分类分组的频道列表
  static List<ChannelCategory> parse(
      String content, PlaylistFormat format) {
    final text = _stripBom(content);
    switch (format) {
      case PlaylistFormat.m3u:
        return _parseM3U(text);
      case PlaylistFormat.txt:
        return _parseTxt(text);
      case PlaylistFormat.unknown:
        // 内容嗅探后再决定
        final detected = detectFormat(text, '');
        if (detected == PlaylistFormat.m3u) return _parseM3U(text);
        if (detected == PlaylistFormat.txt) return _parseTxt(text);
        // 仍然未知：两种都试，取解析结果较多的
        final m = _parseM3U(text);
        final t = _parseTxt(text);
        return _channelCount(m) >= _channelCount(t) ? m : t;
    }
  }

  static int _channelCount(List<ChannelCategory> cats) =>
      cats.fold(0, (n, c) => n + c.channels.length);

  /// 解析 M3U 格式
  /// #EXTM3U
  /// #EXTINF:-1 tvg-id=".." tvg-logo=".." group-title="新闻",CCTV-1
  /// http://stream/cctv1.m3u8
  static List<ChannelCategory> _parseM3U(String content) {
    final lines = const LineSplitter().convert(content);
    final channels = <Channel>[];
    String? pendingInfo;
    String? pendingGroup; // #EXTGRP:分组名

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        pendingInfo = line;
      } else if (line.startsWith('#EXTGRP:')) {
        pendingGroup = line.substring('#EXTGRP:'.length).trim();
      } else if (!line.startsWith('#')) {
        // 流地址（规范化裸 host:port 地址；非法行跳过）
        final url = _asStreamUrl(line);
        if (url == null) continue;
        // 一条 EXTINF 后可连续跟多个备用源，全部收下
        if (pendingInfo != null) {
          final channel = _parseExtInf(pendingInfo, url, pendingGroup);
          if (channel != null) channels.add(channel);
          pendingInfo = null;
          // group 保留，作用于后续无 EXTGRP 的条目更符合直觉，
          // 但大多数源每条都有 group-title，这里在消费后清掉
          pendingGroup = null;
        } else {
          final fallbackName =
              Uri.tryParse(url)?.pathSegments.lastOrNull ?? url;
          channels.add(Channel(
            id: _genId(url, fallbackName),
            name: fallbackName,
            streamUrls: [url],
            categoryId: '未分类',
            groupTitle: '未分类',
          ));
        }
      }
    }

    return _groupChannels(channels);
  }

  static Channel? _parseExtInf(String extInf, String url, String? extGroup) {
    try {
      final commaIdx = extInf.lastIndexOf(',');
      final name = commaIdx >= 0
          ? extInf.substring(commaIdx + 1).trim()
          : url;
      if (name.isEmpty) return null;

      final attrs = <String, String>{};
      final attrStr =
          extInf.substring(0, commaIdx >= 0 ? commaIdx : extInf.length);
      final regExp = RegExp(r'([a-zA-Z-]+)="([^"]*)"');
      for (final match in regExp.allMatches(attrStr)) {
        attrs[match.group(1)!] = match.group(2) ?? '';
      }

      var groupTitle = attrs['group-title']?.trim();
      if (groupTitle == null || groupTitle.isEmpty) {
        groupTitle = (extGroup?.trim().isNotEmpty ?? false)
            ? extGroup!.trim()
            : '未分类';
      }
      final tvgId = attrs['tvg-id'] ?? '';
      final tvgName = attrs['tvg-name'] ?? name;
      final logo = attrs['tvg-logo'] ?? '';
      // 部分源要求特定 UA 才能播放（如 APTV 的 AptvPlayer-UA）
      final ua = (attrs['http-user-agent'] ?? '').trim();

      return Channel(
        id: _genId(url, name),
        name: name,
        streamUrls: [url],
        logoUrl: logo,
        categoryId: groupTitle,
        groupTitle: groupTitle,
        tvgId: tvgId,
        tvgName: tvgName,
        userAgent: ua,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 TVBox / DIYP TXT 格式
  /// 央视频道,#genre#
  /// CCTV1,http://a/x.m3u8#http://b/y.m3u8
  /// 卫视,#genre#
  /// 湖南卫视,http://...
  static List<ChannelCategory> _parseTxt(String content) {
    final lines = const LineSplitter().convert(content);
    final channels = <Channel>[];
    String currentGroup = '未分类';

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      // 分组行："分组名,#genre#"（个别源带空格，trim 后比较）
      if (line.endsWith(',#genre#')) {
        final g = line.substring(0, line.length - ',#genre#'.length).trim();
        if (g.isNotEmpty) currentGroup = g;
        continue;
      }

      final commaIdx = line.indexOf(',');
      if (commaIdx <= 0) {
        // 兜底：名称与地址连写漏了逗号（"电台直播http://host/..."）
        final m = _gluedUrl.firstMatch(line);
        if (m != null) {
          final gluedName = m.group(1)!.trim();
          final gluedUrl = _asStreamUrl(m.group(2)!);
          if (gluedName.isNotEmpty && gluedUrl != null) {
            channels.add(Channel(
              id: _genId(gluedUrl, gluedName),
              name: gluedName,
              streamUrls: [gluedUrl],
              categoryId: currentGroup,
              groupTitle: currentGroup,
            ));
          }
        }
        continue;
      }
      final name = line.substring(0, commaIdx).trim();
      final rest = line.substring(commaIdx + 1).trim();
      if (name.isEmpty || rest.isEmpty) continue;

      // 兼容旧式 "分组,频道名,地址(,备用地址...)" 三段：
      // 第一段 name 是分组；rest 中逗号前不是地址、逗号后是地址
      final restComma = rest.indexOf(',');
      if (restComma > 0) {
        final mid = rest.substring(0, restComma).trim();
        final tail = rest.substring(restComma + 1).trim();
        final tailFirst =
            tail.split(RegExp(r'[,#]')).first.trim();
        if (_asStreamUrl(mid) == null &&
            _asStreamUrl(tailFirst) != null) {
          final urls3 = _splitSources(tail);
          if (urls3.isNotEmpty) {
            channels.add(Channel(
              id: _genId(urls3.first, mid),
              name: mid,
              streamUrls: urls3,
              categoryId: name,
              groupTitle: name,
            ));
            continue;
          }
        }
      }

      final urls = _splitSources(rest);
      if (urls.isEmpty) continue;

      channels.add(Channel(
        id: _genId(urls.first, name),
        name: name,
        streamUrls: urls,
        categoryId: currentGroup,
        groupTitle: currentGroup,
      ));
    }

    return _groupChannels(channels);
  }

  /// 拆分一行中的多个备用源：
  /// "http://a#http://b"（DIYP 约定 # 分隔）、"http://a,http://b"
  /// 若拆分后不是合法流地址则原样返回（# 也可能是 URL fragment）
  static List<String> _splitSources(String rest) {
    final urls = <String>[];
    final parts = rest.split(RegExp(r'[,#]'));
    for (final p in parts) {
      final u = _asStreamUrl(p);
      if (u != null) {
        urls.add(u);
      } else {
        // 含非 URL 段：说明逗号/井号是地址自身内容，整体作为一个地址
        final whole = _asStreamUrl(rest);
        return whole != null ? [whole] : const [];
      }
    }
    return urls;
  }

  /// 按分类对频道分组（先合并同名频道为多个播放源）
  static List<ChannelCategory> _groupChannels(List<Channel> channels) {
    // 同名频道（忽略大小写、空格、横线、括号差异）合并为一个频道的多个源
    final mergedByKey = <String, Channel>{};
    final order = <String>[];
    for (final ch in channels) {
      final key = _mergeKey(ch.name);
      final existing = mergedByKey[key];
      if (existing == null) {
        mergedByKey[key] = ch;
        order.add(key);
      } else {
        for (final u in ch.streamUrls) {
          if (!existing.streamUrls.contains(u)) existing.streamUrls.add(u);
        }
      }
    }
    final map = <String, List<Channel>>{};
    for (final key in order) {
      final ch = mergedByKey[key]!;
      final gk = ch.groupTitle.isEmpty ? '未分类' : ch.groupTitle;
      map.putIfAbsent(gk, () => []).add(ch);
    }

    return map.entries.map((e) {
      return ChannelCategory(
        id: e.key,
        name: e.key,
        channels: e.value,
      );
    }).toList();
  }

  /// 合并键：归一化频道名，"CCTV-1 综合"/"cctv1综合" 视为同一频道
  static String _mergeKey(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_（）()\[\]]'), '');
  }

  /// 频道 id：URL + 名称双重哈希。
  /// 只用 URL 时，同一网站地址下不同名的网页频道（webview://）
  /// 会得到相同 id，导致列表里一大片同时显示选中态。
  static String _genId(String url, String name) {
    return 'ch_${name.hashCode.abs()}_${url.hashCode.abs()}';
  }
}

enum PlaylistFormat { m3u, txt, unknown }
