import 'dart:convert' show utf8;

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:xml/xml.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';

/// XMLTV 解析结果
typedef XmltvResult = ({
  Map<String, List<EpgProgram>> programs,
  Map<String, List<String>> channelNames,
  Map<String, String> channelIcons,
});

/// 后台 isolate 入口：解压（按 gzip 魔数判断）+ UTF-8 解码 + 原始解析。
/// 只做纯数据运算，入参/返回值都是可跨 isolate 传递的基本类型。
Map<String, Object?> _decodeEpgBytes(List<int> bytes) {
  final String body;
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    body = utf8.decode(GZipDecoder().decodeBytes(bytes));
  } else {
    body = utf8.decode(bytes);
  }
  return XmltvEpgParser.parseRaw(body);
}

/// XMLTV 格式 EPG 解析器
class XmltvEpgParser {
  /// 解析 XMLTV 内容（同步版，供已解码成字符串的场景）
  static XmltvResult parse(String xmlContent) =>
      _buildResult(parseRaw(xmlContent));

  /// 解析压缩（.gz）或明文 EPG 字节。
  ///
  /// gunzip、UTF-8 解码、XML DOM 解析全部丢到后台 isolate：常见 XMLTV
  /// 解压后 7 MB、3.7 万条节目，在 UI isolate 上做这些会冻住启动画面
  /// 数秒（状态文案会停在「正在读取节目列表…」不动，观感就是卡死）。
  static Future<XmltvResult> parseBytesAsync(List<int> bytes) async {
    final raw = await compute(_decodeEpgBytes, bytes);
    return _buildResult(raw);
  }

  /// 原始解析：只产出可跨 isolate 传递的纯数据
  /// programs 每行 = [channelId, title, desc, startMs, endMs]
  static Map<String, Object?> parseRaw(String xmlContent) {
    final rows = <List<Object?>>[];
    final channelNames = <String, List<String>>{};
    final channelIcons = <String, String>{};
    try {
      final document = XmlDocument.parse(xmlContent);
      final tvElement = document.findElements('tv').firstOrNull;
      if (tvElement == null) {
        return {
          'programs': rows,
          'names': channelNames,
          'icons': channelIcons,
        };
      }

      // 频道 id -> 所有显示名 + 台标
      for (final ch in tvElement.findElements('channel')) {
        final id = ch.getAttribute('id') ?? '';
        final names = ch
            .findElements('display-name')
            .map((e) => decodeEntities(e.innerText.trim()))
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

        final title = decodeEntities(
            prog.findElements('title').firstOrNull?.innerText ?? '未知节目');
        final desc = decodeEntities(
            prog.findElements('desc').firstOrNull?.innerText ?? '');
        rows.add([
          channelId,
          title,
          desc,
          startTime.millisecondsSinceEpoch,
          endTime.millisecondsSinceEpoch,
        ]);
      }
    } catch (e) {
      debugPrintEpg('解析 XMLTV 失败: $e');
    }
    return {
      'programs': rows,
      'names': channelNames,
      'icons': channelIcons,
    };
  }

  /// 纯数据还原成 EpgProgram 模型（在主 isolate 上，代价很小）
  static XmltvResult _buildResult(Map<String, Object?> raw) {
    final programs = <String, List<EpgProgram>>{};
    final rows = raw['programs'] as List? ?? const [];
    for (final row in rows) {
      final r = row as List;
      final channelId = r[0] as String;
      final startMs = r[3] as int;
      final endMs = r[4] as int;
      programs.putIfAbsent(channelId, () => []).add(EpgProgram(
            id: '${channelId}_$startMs',
            channelId: channelId,
            title: r[1] as String,
            description: r[2] as String,
            startTime: DateTime.fromMillisecondsSinceEpoch(startMs),
            endTime: DateTime.fromMillisecondsSinceEpoch(endMs),
          ));
    }
    for (final list in programs.values) {
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
    }
    return (
      programs: programs,
      channelNames: (raw['names'] as Map?)?.cast<String, List<String>>() ??
          <String, List<String>>{},
      channelIcons:
          (raw['icons'] as Map?)?.cast<String, String>() ?? <String, String>{},
    );
  }

  /// HTML/XML 实体：部分 XMLTV 源把实体的字面串写进了文本
  /// （如 `&amp;apos;` 只解码一层后剩 `&apos;`，界面上就显示成乱码）
  static final _entityRe = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

  /// 再解一层实体（两次足够处理双重转义）
  static String decodeEntities(String s) {
    if (!s.contains('&')) return s;
    var out = s;
    for (var pass = 0; pass < 2; pass++) {
      final next = out.replaceAllMapped(_entityRe, (m) {
        final body = m.group(1)!;
        final lower = body.toLowerCase();
        if (lower.startsWith('#x')) {
          final v = int.tryParse(body.substring(2), radix: 16);
          return v == null ? m.group(0)! : String.fromCharCode(v);
        }
        if (lower.startsWith('#')) {
          final v = int.tryParse(body.substring(1));
          return v == null ? m.group(0)! : String.fromCharCode(v);
        }
        switch (lower) {
          case 'amp':
            return '&';
          case 'apos':
            return "'";
          case 'quot':
            return '"';
          case 'lt':
            return '<';
          case 'gt':
            return '>';
          case 'nbsp':
            return ' ';
        }
        return m.group(0)!;
      });
      if (next == out) break;
      out = next;
    }
    return out;
  }

  /// 归一化名称：忽略大小写、空格、标点、括号差异
  static final _normRe = RegExp(r'[\s\-_（）()\[\].·、,，+]');
  static String norm(String s) => s.toLowerCase().replaceAll(_normRe, '');

  static final _cctvRe = RegExp(r'cctv[-\s]*(\d+)\s*(\+?)');

  /// 仅当名称里包含 "CCTV+数字"（如 CCTV4中文国际、CCTV-1综合、CCTV5+体育赛事）
  /// 时，提取英文核心 "cctv4"/"cctv1"/"cctv5+"；其他频道一律返回 null，
  /// 仍按完整原名匹配（湖南卫视、北京卫视等不去汉字）
  static String? cctvCore(String s) {
    final m = _cctvRe.firstMatch(s.toLowerCase());
    if (m == null) return null;
    return 'cctv${m.group(1)}${m.group(2) ?? ''}';
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
  static final _tzSplitRe = RegExp(r'\s+');

  static DateTime? _parseXmltvDate(String str) {
    if (str.isEmpty) return null;
    try {
      final parts = str.trim().split(_tzSplitRe);
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
