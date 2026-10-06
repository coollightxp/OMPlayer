import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';

/// XMLTV 解析结果
typedef XmltvResult = ({
  Map<String, List<EpgProgram>> programs,
  Map<String, List<String>> channelNames,
  Map<String, String> channelIcons,
});

/// XMLTV 格式 EPG 解析器
class XmltvEpgParser {
  /// 解析 XMLTV 内容
  static XmltvResult parse(String xmlContent) {
    final result = <String, List<EpgProgram>>{};
    final channelNames = <String, List<String>>{};
    final channelIcons = <String, String>{};
    try {
      final document = XmlDocument.parse(xmlContent);
      final tvElement = document.findElements('tv').firstOrNull;
      if (tvElement == null) {
        return (
          programs: result,
          channelNames: channelNames,
          channelIcons: channelIcons,
        );
      }

      // 频道 id -> 所有显示名 + 台标
      for (final ch in tvElement.findElements('channel')) {
        final id = ch.getAttribute('id') ?? '';
        final names = ch
            .findElements('display-name')
            .map((e) => e.innerText.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (names.isEmpty && id.isNotEmpty) names.add(id);
        channelNames[id] = names;
        final icon = ch.findElements('icon').firstOrNull?.getAttribute('src');
        if (icon != null && icon.isNotEmpty) channelIcons[id] = icon;
      }

      // 解析节目
      for (final prog in tvElement.findElements('programme')) {
        final channelId = prog.getAttribute('channel') ?? '';
        if (channelId.isEmpty) continue;

        final startTime = _parseXmltvDate(prog.getAttribute('start') ?? '');
        final endTime = _parseXmltvDate(prog.getAttribute('stop') ?? '');
        if (startTime == null || endTime == null) continue;

        final title =
            prog.findElements('title').firstOrNull?.innerText ?? '未知节目';
        final desc = prog.findElements('desc').firstOrNull?.innerText ?? '';

        // 回看地址模板：优先子元素 <catchup-source>，其次同名属性
        final catchupSource = (prog
                    .findElements('catchup-source')
                    .firstOrNull
                    ?.innerText
                    .trim()
                    .isNotEmpty ??
                false)
            ? prog.findElements('catchup-source').first.innerText.trim()
            : prog.getAttribute('catchup-source')?.trim();

        result.putIfAbsent(channelId, () => []).add(EpgProgram(
              id: '${channelId}_${startTime.millisecondsSinceEpoch}',
              channelId: channelId,
              title: title,
              description: desc,
              startTime: startTime,
              endTime: endTime,
              catchupUrl:
                  (catchupSource != null && catchupSource.isNotEmpty)
                      ? catchupSource
                      : null,
            ));
      }

      for (final list in result.values) {
        list.sort((a, b) => a.startTime.compareTo(b.startTime));
      }
    } catch (e) {
      debugPrintEpg('解析 XMLTV 失败: $e');
    }
    return (
      programs: result,
      channelNames: channelNames,
      channelIcons: channelIcons,
    );
  }

  /// 归一化名称：忽略大小写、空格、标点、括号差异。
  /// 注意不删 '+'：CCTV5+ 必须与 CCTV5 区分开，否则两者在
  /// 「完整原名精确匹配」一步互相撞车（CCTV5+ 显示 CCTV5 的节目）
  static String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s\-_（）()\[\].·、,，]'), '');

  // '+'、'plus' 两种加号写法（CCTV5+ / CCTV5Plus / CCTV-5Plus 均常见）
  static final _cctvRe = RegExp(r'cctv[-\s]*(\d+)\s*(\+|plus)?');

  /// 仅当名称里包含 "CCTV+数字"（如 CCTV4中文国际、CCTV-1综合、CCTV5+体育赛事、
  /// CCTV5Plus）时，提取英文核心 "cctv4"/"cctv1"/"cctv5+"；其他频道一律返回 null，
  /// 仍按完整原名匹配（湖南卫视、北京卫视等不去汉字）
  static String? cctvCore(String s) {
    final m = _cctvRe.firstMatch(s.toLowerCase());
    if (m == null) return null;
    final g2 = m.group(2) ?? '';
    final plus = g2 == '+' || g2 == 'plus';
    return 'cctv${m.group(1)}${plus ? '+' : ''}';
  }

  /// 找到频道对应的 EPG 频道 id
  /// 顺序：tvgId 精确 → 完整原名归一化相等 → CCTV编号核心相等 → 原名包含匹配
  static String? matchChannelId(
    Channel channel,
    Map<String, List<EpgProgram>> epgData,
    Map<String, List<String>> channelNames,
  ) {
    // 1. tvg-id 精确匹配
    if (channel.tvgId.isNotEmpty && epgData.containsKey(channel.tvgId)) {
      return channel.tvgId;
    }

    final wantFull = <String>{
      norm(channel.name),
      if (channel.tvgName.isNotEmpty) norm(channel.tvgName),
    }..removeWhere((e) => e.isEmpty);

    // 只有 CCTV+数字 频道才计算英文核心
    final wantCctvCores = <String>{};
    final c1 = cctvCore(channel.name);
    if (c1 != null) wantCctvCores.add(c1);
    if (channel.tvgName.isNotEmpty) {
      final c2 = cctvCore(channel.tvgName);
      if (c2 != null) wantCctvCores.add(c2);
    }

    String? fallback;
    for (final entry in epgData.entries) {
      final id = entry.key;
      final names = channelNames[id] ?? [id];
      final fulls = names.map(norm).toList();

      // 2. 完整原名精确（非 CCTV 频道主要走这里）
      if (fulls.any(wantFull.contains)) return id;

      // 3. CCTV 编号核心精确：CCTV4中文国际 == CCTV4
      if (wantCctvCores.isNotEmpty) {
        for (final n in names) {
          final core = cctvCore(n);
          if (core != null && wantCctvCores.contains(core)) return id;
        }
        // CCTV 频道必须精确到编号（防止 CCTV5+ 误撞 CCTV5、CCTV1 撞 CCTV13），
        // 不参与第 4 步模糊匹配
        continue;
      }

      // 4. 其他频道：按完整原名包含模糊匹配（长度 ≥4，避免单字误撞）
      if (fallback == null) {
        for (final want in wantFull) {
          if (want.length < 4) continue;
          if (fulls.any((fn) => fn.contains(want) || want.contains(fn))) {
            fallback = id;
          }
        }
      }
    }
    return fallback;
  }

  /// 根据频道查找 EPG 节目列表
  static List<EpgProgram> findProgramsForChannel(
    Channel channel,
    Map<String, List<EpgProgram>> epgData,
    Map<String, List<String>> channelNames,
  ) {
    final id = matchChannelId(channel, epgData, channelNames);
    return id == null ? [] : (epgData[id] ?? const []);
  }

  /// 解析 XMLTV 日期 "20240101190000 +0800"
  static DateTime? _parseXmltvDate(String str) {
    if (str.isEmpty) return null;
    try {
      final parts = str.trim().split(RegExp(r'\s+'));
      final datePart = parts[0].padRight(14, '0');
      if (datePart.length < 14) return null;

      final dt = DateTime(
        int.parse(datePart.substring(0, 4)),
        int.parse(datePart.substring(4, 6)),
        int.parse(datePart.substring(6, 8)),
        int.parse(datePart.substring(8, 10)),
        int.parse(datePart.substring(10, 12)),
        int.parse(datePart.substring(12, 14)),
      );

      if (parts.length > 1 && parts[1].length >= 5) {
        final tz = parts[1];
        final sign = tz.startsWith('-') ? -1 : 1;
        final offset = Duration(
          hours: sign * (int.tryParse(tz.substring(1, 3)) ?? 0),
          minutes: sign * (int.tryParse(tz.substring(3, 5)) ?? 0),
        );
        // 转为本地时间
        return dt.subtract(offset).add(DateTime.now().timeZoneOffset);
      }
      return dt;
    } catch (_) {
      return null;
    }
  }
}

void debugPrintEpg(String msg) {
  // ignore: avoid_print
  print('[EPG] $msg');
}
