import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 网页频道诊断埋点（原生平台实现）：定位「拉起慢 / 黑屏有声 / 串台 /
/// 卡顿」类故障。网页频道激活期间全链路打点（相对开台 t0 的毫秒
/// 时间戳），环形内存缓冲（600 条）平时不落盘；用户在设置里点
/// 「导出网页诊断日志」时才一次性写文件。所有方法失败静默，
/// 绝不影响播放。
class WebDiag {
  WebDiag._();

  static const int _maxEntries = 600;
  static final List<String> _entries = [];
  static int _t0 = 0;
  static bool _active = false;

  /// 应用版本（PlayerScreen 启动时写入，随日志导出便于定位版本）
  static String appVersion = '';

  /// 网页频道开台：同一次运行内连续网页频道共用一条时间线
  /// （跨频道串台分析依赖它），并记开台事件
  static void begin(String url, String title) {
    if (_t0 == 0) _t0 = DateTime.now().millisecondsSinceEpoch;
    _active = true;
    log('open', 'v=$appVersion|title=$title|url=$url');
  }

  /// 网页频道关台：记关台事件后停止记录（缓冲保留待导出）
  static void end() {
    log('close');
    _active = false;
  }

  /// 追加一条事件（仅网页频道激活期间；自动加相对毫秒时间戳）
  static void log(String event, [String detail = '']) {
    if (!_active || _t0 == 0) return;
    try {
      final rel = DateTime.now().millisecondsSinceEpoch - _t0;
      var d = detail.replaceAll('\n', ' ').replaceAll('\r', ' ');
      if (d.length > 400) d = d.substring(0, 400);
      _entries.add('+$rel $event${d.isEmpty ? '' : ' $d'}');
      if (_entries.length > _maxEntries) {
        _entries.removeRange(0, _entries.length - _maxEntries);
      }
    } catch (_) {}
  }

  /// 把当前缓冲写入应用支持目录 omplayer_web_diag.log（覆盖写），
  /// 返回文件完整路径；无内容或不可写时返回空串
  static Future<String> flush() async {
    if (_entries.isEmpty) return '';
    try {
      final dir = await getApplicationSupportDirectory();
      final p = '${dir.path}${Platform.pathSeparator}omplayer_web_diag.log';
      final sink = File(p).openWrite(mode: FileMode.write);
      sink.writeln('# OMPlayer 网页诊断日志  ${DateTime.now().toIso8601String()}');
      sink.writeln('# app=$appVersion entries=${_entries.length}');
      for (final e in _entries) {
        sink.writeln(e);
      }
      await sink.flush();
      await sink.close();
      return p;
    } catch (_) {
      return '';
    }
  }
}
