import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/epg_program.dart';

/// 央视频 EPG 模块（独立、可随时替换）。
///
/// 接口：GET https://capi.yangshipin.cn/api/yspepg/program/<pid>
/// 返回 protobuf（application/octet-stream），需要带 Referer。
/// 结构（手工解析确认）：
///   顶层 f1 = 节目总数，f2 = repeated Program，f3 = '成功'，f4 = 服务器时间
///   Program: f1 = 节目 id(string)、f2 = 标题(string)、
///            f3 = 开始时间(unix 秒, varint)、f4 = 结束时间(unix 秒, varint)
/// 频道 pid 与 [YangshipinChannels] 一致。
class YangshipinEpg {
  static const String _base =
      'https://capi.yangshipin.cn/api/yspepg/program/';
  static const Duration refreshInterval = Duration(minutes: 15);

  final http.Client _client;

  /// pid -> 当天的节目单（已按开始时间排序）
  final Map<String, List<EpgProgram>> _byPid = {};
  final Map<String, DateTime> _fetchedAt = {};

  YangshipinEpg({http.Client? client}) : _client = client ?? http.Client();

  List<EpgProgram> programsFor(String pid) => _byPid[pid] ?? const [];

  bool get isEmpty => _byPid.isEmpty;

  /// 是否已过刷新间隔
  bool _stale(String pid) {
    final at = _fetchedAt[pid];
    return at == null ||
        DateTime.now().difference(at) > refreshInterval;
  }

  /// 批量拉取（限制并发，避免一次性打满连接）。
  /// [onProgress] 每完成一个 pid 回调一次（已完成数, 总数），用于更新 UI。
  Future<void> refresh(
    List<String> pids, {
    int concurrency = 6,
    bool force = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = force ? List<String>.from(pids) : pids.where(_stale).toList();
    if (targets.isEmpty) return;
    var next = 0;
    var done = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= targets.length) return;
        try {
          await _fetchOne(targets[i]);
        } catch (_) {
          // 单个频道失败不影响其它频道
        }
        done++;
        onProgress?.call(done, targets.length);
      }
    }

    final workers =
        targets.length < concurrency ? targets.length : concurrency;
    await Future.wait(
      List.generate(workers, (_) => worker()),
    );
  }

  Future<void> _fetchOne(String pid) async {
    // 单个频道超时：弱网/接口无响应时不能让启动流程无限等待
    final resp = await _client
        .get(
          Uri.parse('$_base$pid'),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
            'Referer': 'https://yangshipin.cn/tv/home',
            'Accept': 'application/octet-stream',
          },
        )
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return;
    final programs = parsePrograms(pid, resp.bodyBytes);
    _byPid[pid] = programs;
    _fetchedAt[pid] = DateTime.now();
  }

  /// 解析 EPG protobuf。字段缺失时跳过该条，保证不因单条异常丢整份节目单。
  static List<EpgProgram> parsePrograms(String pid, Uint8List data) {
    final result = <EpgProgram>[];
    var i = 0;
    while (i < data.length) {
      final key = _varint(data, i);
      if (key == null) break;
      i = key.next;
      final field = key.value >> 3;
      final wire = key.value & 7;
      if (wire == 0) {
        final v = _varint(data, i);
        if (v == null) break;
        i = v.next;
      } else if (wire == 1) {
        i += 8;
      } else if (wire == 2) {
        final len = _varint(data, i);
        if (len == null) break;
        i = len.next;
        final end = i + len.value;
        if (end > data.length) break;
        if (field == 2) {
          final p = _parseProgram(pid, data.sublist(i, end));
          if (p != null) result.add(p);
        }
        i = end;
      } else if (wire == 5) {
        i += 4;
      } else {
        break;
      }
    }
    result.sort((a, b) => a.startTime.compareTo(b.startTime));
    return result;
  }

  static EpgProgram? _parseProgram(String pid, Uint8List data) {
    String? id;
    String? title;
    int? start;
    int? end;
    var i = 0;
    while (i < data.length) {
      final key = _varint(data, i);
      if (key == null) break;
      i = key.next;
      final field = key.value >> 3;
      final wire = key.value & 7;
      if (wire == 0) {
        final v = _varint(data, i);
        if (v == null) break;
        i = v.next;
        if (field == 3) start = v.value;
        if (field == 4) end = v.value;
      } else if (wire == 2) {
        final len = _varint(data, i);
        if (len == null) break;
        i = len.next;
        final stop = i + len.value;
        if (stop > data.length) break;
        if (field == 1) id = utf8.decode(data.sublist(i, stop), allowMalformed: true);
        if (field == 2) title = utf8.decode(data.sublist(i, stop), allowMalformed: true);
        i = stop;
      } else if (wire == 1) {
        i += 8;
      } else if (wire == 5) {
        i += 4;
      } else {
        break;
      }
    }
    if (title == null || title.trim().isEmpty || start == null) return null;
    final startTime = DateTime.fromMillisecondsSinceEpoch(start * 1000);
    final endTime = end != null
        ? DateTime.fromMillisecondsSinceEpoch(end * 1000)
        : startTime.add(const Duration(minutes: 30));
    return EpgProgram(
      id: id ?? '$pid-$start',
      channelId: pid,
      title: title.trim(),
      startTime: startTime,
      endTime: endTime,
    );
  }

  static ({int value, int next})? _varint(Uint8List b, int i) {
    var value = 0;
    var shift = 0;
    while (true) {
      if (i >= b.length) return null;
      final c = b[i++];
      value |= (c & 0x7f) << shift;
      if ((c & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) return null;
    }
    return (value: value, next: i);
  }

  void dispose() {
    _client.close();
  }
}
