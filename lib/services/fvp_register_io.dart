import 'dart:io' show Platform;

import 'package:fvp/fvp.dart' as fvp;

/// Windows/Linux 注册 MDK 视频播放后端（video_player 官方不支持桌面端）
///
/// [bufferSeconds] 播放缓冲上限（秒）：弱网/直播抖动时预读更多数据抗卡顿，
/// 起播缓冲固定取 min(3 秒, 上限)，避免为大缓冲等太久。
/// 上限 120 秒：投屏点播（腾讯视频等）单连接下载波动大，需要远大于
/// 直播场景的缓冲（投屏由 PlayerController 传入 90 秒）
void registerFvp({int bufferSeconds = 5}) {
  if (Platform.isWindows || Platform.isLinux) {
    final maxMs = bufferSeconds.clamp(5, 120) * 1000;
    final startMs = maxMs < 3000 ? maxMs : 3000;
    // TCP 连接被运营商/路由器/NAT 中间设备静默掐断时，ffmpeg 默认会无限等待，
    // 表现为画面永久卡住、无错误回调。通过 avio.* 透传 ffmpeg http 协议选项，
    // 让协议层自动重连；rw_timeout 让僵死读在 15 秒后超时并触发重连。
    // 注意：不使用 reconnect_at_eof，避免点播短视频正常播完后被无限重开。
    fvp.registerWith(options: {
      'player': {
        // ffmpeg http/https 协议层：断连自动重连（含点播 MP4 的传输中途网络错误）
        'avio.reconnect': '1',
        'avio.reconnect_streamed': '1',
        'avio.reconnect_on_network_error': '1',
        'avio.reconnect_delay_max': '5',
        'avio.rw_timeout': '15000000', // 微秒，15 秒
        // 缓冲区间「起播预读 + 上限」（毫秒）：
        // 上限越大越能吸收网络抖动（可在设置里调 5/10/20/30 秒）
        'buffer.range': '$startMs+$maxMs',
      },
    });
  }
}
