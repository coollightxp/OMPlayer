import 'dart:io';

/// 无媒体后缀/脚本入口型播放地址的格式预检结果缓存，
/// 避免每次切台都多发一次 HTTP 请求
final Map<String, String> _probeCache = {};

/// 发起轻量 GET 预检（自动跟随重定向），依据最终响应的 Content-Type
/// 判断真实封装格式。
///
/// 返回 'hls' / 'dash'；无法判断时返回 null。
///
/// 背景：ExoPlayer（video_player_android）只按 URL 后缀或显式 MIME 选择
/// MediaSource，不会像 MDK 那样嗅探内容。形如 live.php?id=CCTV1 的入口
/// 实际 302 跳到 m3u8，若不告知格式会按 progressive 解析而播放失败。
Future<String?> inferStreamFormat({
  required String url,
  required Map<String, String> headers,
}) async {
  final cached = _probeCache[url];
  if (cached != null) return cached;

  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 8);
    final req = await client.openUrl('GET', Uri.parse(url));
    headers.forEach(req.headers.set);
    final resp = await req.close().timeout(const Duration(seconds: 8));

    // 只需要响应头：直接中止，不下载 body（直播流会持续推数据）
    final mime = resp.headers.contentType?.mimeType ??
        resp.headers.value('content-type') ??
        '';
    final probe = mime.toLowerCase();

    String? result;
    if (probe.contains('mpegurl') || probe.contains('m3u8')) {
      result = 'hls';
    } else if (probe.contains('dash+xml') || probe.contains('mpd')) {
      result = 'dash';
    }
    if (result != null) _probeCache[url] = result;
    return result;
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}
