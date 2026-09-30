import 'package:flutter/services.dart';

/// Windows 原生全局热键桥。
///
/// 网页频道的 WebView2 是独立 HWND，键盘焦点进入后 WM_KEYDOWN 不再
/// 经过 Flutter，HardwareKeyboard 收不到任何键，数字选台全部失效。
/// runner 侧安装 WH_KEYBOARD_LL 低级钩子，本进程在前台时把数字键
/// （主键盘 0-9、小键盘 0-9）通过此通道转发给 Dart，并直接吞掉按键。
/// 通道为裸 UTF-8 字符串（C 侧 messenger API，无 StandardMethodCodec）。
/// 非 Windows 平台调用全部静默无效。
class WinHotkeys {
  static const BasicMessageChannel<String> _channel =
      BasicMessageChannel<String>('omplayer/win_hotkeys', StringCodec());

  bool _handlerSet = false;

  /// 注册数字键回调（参数 0-9）。传 null 注销。
  void setDigitHandler(void Function(int digit)? onDigit) {
    if (onDigit == null) {
      _channel.setMessageHandler(null);
      _handlerSet = false;
      return;
    }
    if (_handlerSet) return;
    _handlerSet = true;
    // setMessageHandler 要求 Future<String>（非空），回复空串即可
    Future<String> onMessage(String? msg) async {
      final n = int.tryParse(msg ?? '');
      if (n != null && n >= 0 && n <= 9) onDigit(n);
      return '';
    }

    _channel.setMessageHandler(onMessage);
  }

  /// true=数字键拦截用于选台；false=放行（设置面板输入框需要输入数字）
  Future<void> setCapture(bool capture) async {
    try {
      await _channel.send(capture ? '1' : '0');
    } catch (_) {
      // 非 Windows 或旧 runner 无实现：忽略
    }
  }
}
