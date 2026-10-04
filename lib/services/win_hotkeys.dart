import 'package:flutter/services.dart';

/// Windows 原生全局热键桥。
///
/// 网页频道的 WebView2 是独立 HWND，键盘焦点进入后 WM_KEYDOWN 不再
/// 经过 Flutter，HardwareKeyboard 收不到任何键。runner 侧安装
/// WH_KEYBOARD_LL 低级钩子。
///
/// 为了让普通播放界面保留 Flutter 完整的按下/抬起/长按事件序列
/// （左右键长按拖进度、OK 短按/长按都依赖 KeyUp），钩子只在网页频道
/// 处于【前台】时才拦截并转发（[setWebForward]）；普通视频/直播时一律
/// 放行，由 HardwareKeyboard 处理。浏览器返回键（VK_BROWSER_BACK）
/// 例外：始终拦截，防止 WebView 历史导航并统一走层级返回。
///
/// 通道为裸 UTF-8 字符串（C 侧 messenger API，无 StandardMethodCodec）：
///   - "0".."9"    数字选台（仅按下）
///   - "k:xxx"     动作键按下（space/left/right/up/down/esc/ok/menu/back/...）
///   - "u:xxx"     动作键抬起
/// 反向消息：
///   - "1"/"0"    开关热键捕获（设置面板输入框打开时关闭）
///   - "C1"/"C0"  开关空闲光标隐藏
///   - "W1"/"W0"  开关网页前台转发模式
/// 非 Windows 平台调用全部静默无效。
class WinHotkeys {
  static const BasicMessageChannel<String> _channel =
      BasicMessageChannel<String>('omplayer/win_hotkeys', StringCodec());

  void Function(int digit)? _onDigit;

  /// 动作键回调；isDown=true 为按下、false 为抬起
  void Function(String action, bool isDown)? _onAction;
  bool _handlerInstalled = false;

  /// 注册数字键回调（参数 0-9）。传 null 注销。
  void setDigitHandler(void Function(int digit)? onDigit) {
    _onDigit = onDigit;
    _syncHandler();
  }

  /// 注册动作键回调（space/left/right/up/down/esc/ok/menu/back/m/f/r/c/e/s）
  void setActionHandler(void Function(String action, bool isDown)? onAction) {
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
        _onAction?.call(m.substring(2), true);
      } else if (m.startsWith('u:')) {
        _onAction?.call(m.substring(2), false);
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

  /// true=网页频道在前台：钩子拦截按键并转发（WebView 吞键）；
  /// false=普通视频界面：钩子放行，保留 Flutter 完整按键事件
  Future<void> setWebForward(bool enable) async {
    try {
      await _channel.send(enable ? 'W1' : 'W0');
    } catch (_) {}
  }
}
