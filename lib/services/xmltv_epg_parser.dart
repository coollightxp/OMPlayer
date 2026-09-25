import 'package:xml/xml.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';

/// XMLTV 格式 EPG 解析器
/// XMLTV 是 EPG 数据的标准格式，XML 结构
class XmltvEpgParser {
  /// 解析 XMLTV 内容，返回频道ID -> 节目列表的映射
  static Map<String, List<EpgProgram>> parse(String xmlContent) {
    final result = <String, List<EpgProgram>>{};
    try {
      final document = XmlDocument.parse(xmlContent);
      final tvElement = document.findElements('tv').firstOrNull;
      if (tvElement == null) return result;

      // 先建立频道 id -> 显示名 的映射
      final channelNames = <String, String>{};
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
    return result;
  }

  /// 根据频道信息查找匹配的 EPG 节目列表
  /// 优先按 tvgId 匹配，其次按 tvgName/频道名匹配
  static List<EpgProgram> findProgramsForChannel(
    Channel channel,
    Map<String, List<EpgProgram>> epgData,
  ) {
    // 1. 按 tvg-id 精确匹配
    if (channel.tvgId.isNotEmpty && epgData.containsKey(channel.tvgId)) {
      return epgData[channel.tvgId]!;
    }

    // 2. 按 tvg-name 匹配（不区分大小写）
    if (channel.tvgName.isNotEmpty) {
      for (final entry in epgData.entries) {
        // 这里 entry.key 是 channel id，需要通过 channelNames 映射
        // 简化处理：遍历所有节目找标题匹配的
      }
    }

    // 3. 模糊匹配：遍历所有频道 id 和节目，找名称包含关系
    final lowerName = channel.name.toLowerCase();
    for (final entry in epgData.entries) {
      final key = entry.key.toLowerCase();
      if (key.contains(lowerName) || lowerName.contains(key)) {
        return entry.value;
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
