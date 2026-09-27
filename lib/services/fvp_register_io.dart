import 'dart:io' show Platform;

import 'package:fvp/fvp.dart' as fvp;

/// Windows/Linux 注册 MDK 视频播放后端（video_player 官方不支持桌面端）
void registerFvp() {
  if (Platform.isWindows || Platform.isLinux) {
    // 网络直播（微信视频号/抖音等多为 HTTP-FLV/HLS）：
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
        // 起播最小缓冲 3 秒 + 读包缓冲上限 15 秒（默认仅 4 秒）：
        // minMs=1s 时起播太急、网络轻微抖动立刻卡顿（开局卡顿明显），
        // 3s 预读在良好网络下几乎不增加等待，却能显著减少开局/中途缓冲；
        // 上限 15s 让 CDN 限速/网关掐流时有缓冲窗口，并减少慢速消费被断连
        'buffer.range': '3000+15000',
      },
    });
  }
}
