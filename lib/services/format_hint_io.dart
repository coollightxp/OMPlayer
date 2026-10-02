import 'dart:io';

/// 无媒体后缀/脚本入口型播放地址的格式预检结果缓存，
/// 避免每次切台都多发一次 HTTP 请求
final Map<String, String> _probeCache = {};

/// IPTV 常见脚本入口：绝大多数实际 302 到 HLS，直接判定减少预检依赖
bool _isKnownHlsEntry(String url) {
  final lower = url.toLowerCase();
  const patterns = [
    '/live.php',
    '/play.php',
    '/stream.php',
    '/hls.php',
    '/tv.php',
    '/m3u8.php',
    '/api/live',
    '/api/stream',
  ];
  for (final p in patterns) {
    if (lower.contains(p)) return true;
  }
  return false;
}

/// 发起轻量预检（HEAD 优先，GET fallback），依据最终响应的 Content-Type
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

  // 常见脚本入口直接判定为 HLS，避免网络预检失败导致播放不了
  if (_isKnownHlsEntry(url)) {
    _probeCache[url] = 'hls';
    return 'hls';
  }

  // 先尝试 HEAD（只读头、不下载 body），失败再 fallback GET
  String? result;
  try {
    result = await _probe(url, headers, 'HEAD');
  } catch (_) {}
  if (result == null) {
    try {
      result = await _probe(url, headers, 'GET');
    } catch (_) {}
  }
  if (result != null) _probeCache[url] = result;
  return result;
}

Future<String?> _probe(
  String url,
  Map<String, String> headers,
  String method,
) async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 6);
    final req = await client.openUrl(method, Uri.parse(url));
    headers.forEach(req.headers.set);
    final resp = await req.close().timeout(const Duration(seconds: 6));

    final mime = resp.headers.contentType?.mimeType ??
        resp.headers.value('content-type') ??
        '';
    final probe = mime.toLowerCase();
    if (probe.contains('mpegurl') || probe.contains('m3u8')) {
      return 'hls';
    } else if (probe.contains('dash+xml') || probe.contains('mpd')) {
      return 'dash';
    }
    return null;
  } finally {
    client?.close(force: true);
  }
}
