import 'package:xml/xml.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';

/// XMLTV 解析结果：节目表 + 频道 id 到显示名的映射
typedef XmltvResult = ({
  Map<String, List<EpgProgram>> programs,
  Map<String, String> channelNames,
});

/// XMLTV 格式 EPG 解析器
/// XMLTV 是 EPG 数据的标准格式，XML 结构
class XmltvEpgParser {
  /// 解析 XMLTV 内容，返回频道ID -> 节目列表的映射 + 频道ID -> 显示名
  static XmltvResult parse(String xmlContent) {
    final result = <String, List<EpgProgram>>{};
    final channelNames = <String, String>{};
    try {
      final document = XmlDocument.parse(xmlContent);
      final tvElement = document.findElements('tv').firstOrNull;
      if (tvElement == null) {
        return (programs: result, channelNames: channelNames);
      }

      // 先建立频道 id -> 显示名 的映射
      for (final ch in tvElement.findElements('channel')) {
        final id = ch.getAttribute('id') ?? '';
        final displayName =
            ch.findElements('display-name').firstOrNull?.innerText ?? id;
        channelNames[id] = displayName;
      }

      // 解析节目
      for (final prog in tvElement.findElements('programme')) {
        final channelId = prog.getAttribute('channel') ?? '';
        if (channelId.isEmpty) continue;

        final startStr = prog.getAttribute('start') ?? '';
        final stopStr = prog.getAttribute('stop') ?? '';
        final startTime = _parseXmltvDate(startStr);
        final endTime = _parseXmltvDate(stopStr);
        if (startTime == null || endTime == null) continue;

        final title = prog.findElements('title').firstOrNull?.innerText ?? '未知节目';
        final desc = prog.findElements('desc').firstOrNull?.innerText ?? '';

        final epgProgram = EpgProgram(
          id: '${channelId}_${startTime.millisecondsSinceEpoch}',
          channelId: channelId,
          title: title,
          description: desc,
          startTime: startTime,
          endTime: endTime,
        );

        result.putIfAbsent(channelId, () => []).add(epgProgram);
      }

      // 对每个频道的节目按开始时间排序
      for (final list in result.values) {
        list.sort((a, b) => a.startTime.compareTo(b.startTime));
      }
    } catch (e) {
      debugPrintEpg('解析 XMLTV 失败: $e');
    }
    return (programs: result, channelNames: channelNames);
  }

  /// 根据频道信息查找匹配的 EPG 节目列表
  /// 优先按 tvgId 匹配，其次按频道名称匹配 EPG 的 display-name
  static List<EpgProgram> findProgramsForChannel(
    Channel channel,
    Map<String, List<EpgProgram>> epgData,
    Map<String, String> channelNames,
  ) {
    // 1. 按 tvg-id 精确匹配
    if (channel.tvgId.isNotEmpty && epgData.containsKey(channel.tvgId)) {
      return epgData[channel.tvgId]!;
    }

    // 归一化：忽略大小写、空格、横线、括号差异
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[\s\-_（）()\[\].]'), '');

    // 候选名称：tvg-name + 频道显示名
    final candidates = <String>[
      if (channel.tvgName.isNotEmpty) norm(channel.tvgName),
      norm(channel.name),
    ]..removeWhere((e) => e.isEmpty);

    // 2. 按名称精确匹配（EPG display-name 或 channel id）
    for (final entry in epgData.entries) {
      final dn = norm(channelNames[entry.key] ?? '');
      final id = norm(entry.key);
      for (final c in candidates) {
        if (dn == c || id == c) return entry.value;
      }
    }

    // 3. 名称包含模糊匹配（只对 display-name，且双方长度 ≥3，
    //    避免 "cctv1" 错误命中 "cctv13"）
    for (final entry in epgData.entries) {
      final dn = norm(channelNames[entry.key] ?? '');
      if (dn.length < 3) continue;
      for (final c in candidates) {
        if (c.length < 3) continue;
        if (dn.contains(c) || c.contains(dn)) return entry.value;
      }
    }

    return [];
  }

  /// 解析 XMLTV 日期格式 "20240101190000 +0800"
  static DateTime? _parseXmltvDate(String str) {
    if (str.isEmpty) return null;
    try {
      // 格式: YYYYMMDDHHMMSS +ZZZZ
      final parts = str.trim().split(' ');
      final datePart = parts[0].padRight(14, '0');
      if (datePart.length < 14) return null;

      final year = int.parse(datePart.substring(0, 4));
      final month = int.parse(datePart.substring(4, 6));
      final day = int.parse(datePart.substring(6, 8));
      final hour = int.parse(datePart.substring(8, 10));
      final minute = int.parse(datePart.substring(10, 12));
      final second = int.parse(datePart.substring(12, 14));

      DateTime dt = DateTime(year, month, day, hour, minute, second);

      // 处理时区偏移
      if (parts.length > 1) {
        final tz = parts[1];
        final sign = tz.startsWith('-') ? -1 : 1;
        final tzHours = int.tryParse(tz.substring(1, 3)) ?? 0;
        final tzMinutes = int.tryParse(tz.substring(3, 5)) ?? 0;
        final offset = Duration(hours: sign * tzHours, minutes: sign * tzMinutes);
        // 转为本地时间
        dt = dt.subtract(offset).add(dt.timeZoneOffset);
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
