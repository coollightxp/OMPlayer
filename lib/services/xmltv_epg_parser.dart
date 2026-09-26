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

        result.putIfAbsent(channelId, () => []).add(EpgProgram(
              id: '${channelId}_${startTime.millisecondsSinceEpoch}',
              channelId: channelId,
              title: title,
              description: desc,
              startTime: startTime,
              endTime: endTime,
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

  /// 归一化名称：忽略大小写、空格、标点、括号差异
  static String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s\-_（）()\[\].·、,，]'), '');

  /// 只保留 ASCII 字母数字（去掉汉字等），用于 "CCTV4中文国际"→"cctv4"
  static String asciiCore(String s) {
    final core = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return core;
  }

  /// 找到频道对应的 EPG 频道 id
  /// 顺序：tvgId 精确 → 全名归一化相等 → 英文核心相等 → 包含匹配
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
    final wantCore = <String>{
      asciiCore(channel.name),
      if (channel.tvgName.isNotEmpty) asciiCore(channel.tvgName),
    }..removeWhere((e) => e.length < 3);

    String? fallback;
    for (final entry in epgData.entries) {
      final id = entry.key;
      final names = channelNames[id] ?? [id];
      final fulls = names.map(norm).toList();
      final cores = names.map(asciiCore).where((e) => e.length >= 3).toList();

      // 2. 全名精确
      if (fulls.any(wantFull.contains)) return id;

      // 3. 去掉汉字后的英文核心精确（CCTV4中文国际 == CCTV4）
      if (cores.any(wantCore.contains)) return id;

      // 4. 包含模糊匹配（长度 ≥5，避免 CCTV1 撞上 CCTV13）
      if (fallback == null) {
        for (final c in wantCore) {
          if (c.length < 5) continue;
          if (cores.any((cn) => cn.contains(c) || c.contains(cn))) {
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
