import 'dart:async';
import 'dart:io';

import 'cast_log.dart';

/// 投屏流本地中转代理。
///
/// 动机：mdk 内核对视频号 CDN（finder.video.qq.com）的 Range 断点请求
/// 会挂死——服务器接受请求但永不回数据（同 URL 在 mpv 上随便拖秒开）。
/// 经本地代理后 HTTP 层完全由我们控制：
/// - 每个请求使用全新连接（不复用可能被 CDN 挂起的连接）；
/// - 首字节停滞 8 秒：未向内核输出过字节，换全新连接整请求重试（≤3 次）；
/// - body 中途停滞 8 秒：直接断开，内核侧已开启的 avio.reconnect
///   会携当前位置重新经代理发请求（同样拿到全新连接），等价于
///   mpv 的断点续传行为。
///   （v1.1.005：实测腾讯 CDN 单连接传 1~11MB 后常见断流，15 秒阈值
///   意味着每次断流用户干等 15 秒才恢复；降到 8 秒恢复显著更快。
///   8 秒内完全无字节不可能是慢速限速——TCP 只要活着就有字节。）
class CastStreamProxy {
  CastStreamProxy._();
  static final CastStreamProxy instance = CastStreamProxy._();

  HttpServer? _server;

  /// 把 [rawUrl] 包装为本地代理地址；代理启动失败时返回 null（回退直连）。
  Future<String?> wrapUrl(String rawUrl) async {
    try {
      if (_server == null) {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        s.listen(_handle, onError: (_) {});
        _server = s;
        CastLog.write('cast proxy listen 127.0.0.1:${s.port}');
      }
      return 'http://127.0.0.1:${_server!.port}/cast?url='
          '${Uri.encodeComponent(rawUrl)}';
    } catch (e) {
      CastLog.write('cast proxy start FAILED: $e');
      return null;
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  static const _hopByHop = {
    'connection',
    'keep-alive',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
  };

  Future<void> _handle(HttpRequest req) async {
    final target = req.uri.queryParameters['url'];
    if (target == null || !target.startsWith('http')) {
      req.response.statusCode = 400;
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    final range = req.headers.value(HttpHeaders.rangeHeader);
    var sent = 0;
    try {
      for (var attempt = 1;; attempt++) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8);
        try {
          final outReq = await client.getUrl(Uri.parse(target));
          // 裸请求转发（只带 Range）：实测给视频号 CDN 补 UA/Referer
          // 反而会被挂死（v1.0.131 实验），保持与可用直连一致
          if (range != null) {
            outReq.headers.set(HttpHeaders.rangeHeader, range);
          }
          final outResp =
              await outReq.close().timeout(const Duration(seconds: 8));
          if (sent == 0) {
            req.response.statusCode = outResp.statusCode;
            outResp.headers.forEach((name, values) {
              if (_hopByHop.contains(name.toLowerCase())) return;
              for (final v in values) {
                req.response.headers.set(name, v);
              }
            });
            // 明确声明支持断点续传（内核判定可 seek 的依据）
            req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          }
          await for (final chunk
              in outResp.timeout(const Duration(seconds: 8))) {
            sent += chunk.length;
            req.response.add(chunk);
            await req.response.flush();
          }
          if (range != null || attempt > 1) {
            CastLog.write(
                'cast proxy ok range=${range ?? "-"} bytes=$sent attempt=$attempt');
          }
          break;
        } catch (e) {
          if (sent == 0 && attempt < 3) {
            // 还没向内核输出任何字节：安全地换全新连接整请求重试
            CastLog.write(
                'cast proxy retry#$attempt range=${range ?? "-"}: $e');
            continue;
          }
          // 已输出过字节的 body 中途停滞：断开，内核 avio.reconnect
          // 会携当前位置重新经代理请求（全新连接）
          CastLog.write(
              'cast proxy abort range=${range ?? "-"} sent=$sent: $e');
          break;
        } finally {
          client.close(force: true);
        }
      }
    } finally {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }
}
