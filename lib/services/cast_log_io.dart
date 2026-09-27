import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 投屏诊断日志（原生平台实现）：记录 DLNA 信令与播放状态，
/// 定位「投到一半卡住」等兼容问题。
///
/// 写入应用支持目录下的 dlna_cast.log（与 shared_preferences.json 同目录），
/// 超过 256KB 轮转为 .old。所有方法同步排队、失败静默，绝不影响播放。
class CastLog {
  CastLog._();

  static const _maxBytes = 256 * 1024;
  static String? _path;
  static bool _flushing = false;
  static final List<String> _pending = [];

  /// 日志文件完整路径（空串表示不可用）
  static Future<String> path() async {
    if (_path != null) return _path!;
    try {
      final dir = await getApplicationSupportDirectory();
      _path = '${dir.path}${Platform.pathSeparator}dlna_cast.log';
    } catch (_) {
      _path = '';
    }
    return _path!;
  }

  /// 追加一行（自动加时间戳）
  static void write(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _pending.add('$ts $msg');
    _flush();
  }

  static Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final p = await path();
        if (p.isEmpty) {
          _pending.clear();
          break;
        }
        try {
          final f = File(p);
          if (await f.exists() && await f.length() > _maxBytes) {
            final old = File('$p.old');
            if (await old.exists()) {
              try {
                await old.delete();
              } catch (_) {}
            }
            try {
              await f.rename('$p.old');
            } catch (_) {}
          }
          final sink = File(p).openWrite(mode: FileMode.append);
          while (_pending.isNotEmpty) {
            sink.writeln(_pending.removeAt(0));
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          // 单批写入失败直接丢弃，避免异常时队列死循环
          _pending.clear();
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
