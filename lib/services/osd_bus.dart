import 'package:flutter/material.dart';

/// 全局中央 OSD 消息总线：深层 widget（设置面板/EPG 面板等）无法直接
/// 调用 player_screen 的 _showOsd，通过此总线转发，
/// 由 player_screen 监听后在屏幕中央渲染（替代底部 SnackBar）
class OsdBus {
  OsdBus._();

  static final ValueNotifier<OsdMessage?> message = ValueNotifier(null);
  static int _seq = 0;

  static void show(String text, {IconData icon = Icons.info_outline}) {
    message.value = OsdMessage(++_seq, text, icon);
  }
}

class OsdMessage {
  final int seq;
  final String text;
  final IconData icon;
  const OsdMessage(this.seq, this.text, this.icon);
}
