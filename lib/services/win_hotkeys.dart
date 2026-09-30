import 'package:flutter/services.dart';

/// Windows 原生全局热键桥。
///
/// 网页频道的 WebView2 是独立 HWND，键盘焦点进入后 WM_KEYDOWN 不再
/// 经过 Flutter，HardwareKeyboard 收不到任何键。runner 侧安装
/// WH_KEYBOARD_LL 低级钩子，本进程在前台时把数字键（0-9/小键盘）与
/// 控制键（空格/方向键/M/F/R/C/E/S/Esc）通过此通道转发给 Dart 并吞掉。
/// 通道为裸 UTF-8 字符串（C 侧 messenger API，无 StandardMethodCodec）：
///   - "0".."9"    数字选台
///   - "k:xxx"     动作键（space/left/right/up/down/esc/m/f/r/c/e/s）
/// 反向消息："1"/"0" 开关热键捕获，"C1"/"C0" 开关空闲光标隐藏。
/// 非 Windows 平台调用全部静默无效。
class WinHotkeys {
  static const BasicMessageChannel<String> _channel =
      BasicMessageChannel<String>('omplayer/win_hotkeys', StringCodec());

  void Function(int digit)? _onDigit;
  void Function(String action)? _onAction;
  bool _handlerInstalled = false;

  /// 注册数字键回调（参数 0-9）。传 null 注销。
  void setDigitHandler(void Function(int digit)? onDigit) {
    _onDigit = onDigit;
    _syncHandler();
  }

  /// 注册动作键回调（space/left/right/up/down/esc/m/f/r/c/e/s）
  void setActionHandler(void Function(String action)? onAction) {
    _onAction = onAction;
    _syncHandler();
  }

  void _syncHandler() {
    if (_onDigit == null && _onAction == null) {
      if (_handlerInstalled) {
        _channel.setMessageHandler(null);
        _handlerInstalled = false;
      }
      return;
    }
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    // setMessageHandler 要求 Future<String>（非空），回复空串即可
    _channel.setMessageHandler((String? msg) async {
      final m = msg ?? '';
      if (m.startsWith('k:')) {
        _onAction?.call(m.substring(2));
      } else {
        final n = int.tryParse(m);
        if (n != null && n >= 0 && n <= 9) _onDigit?.call(n);
      }
      return '';
    });
  }

  /// true=拦截热键用于播放控制；false=放行（设置面板输入框需要输入）
  Future<void> setCapture(bool capture) async {
    try {
      await _channel.send(capture ? '1' : '0');
    } catch (_) {
      // 非 Windows 或旧 runner 无实现：忽略
    }
  }

  /// true=网页前台播放时鼠标静止 3 秒隐藏光标（原生实现，
  /// 网页 CSS 无法覆盖跨域 iframe 内的光标）
  Future<void> setCursorHide(bool enable) async {
    try {
      await _channel.send(enable ? 'C1' : 'C0');
    } catch (_) {}
  }
}
