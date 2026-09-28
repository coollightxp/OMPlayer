import 'dart:ffi';
import 'dart:io';

/// Windows NumLock 状态读取/切换（通过 user32 FFI）。
///
/// 背景：Flutter Windows 引擎在窗口初始化同步键盘状态时，会把
/// NumLock 意外关闭，表现为启动本程序后小键盘失效，需手动按一次。
/// 启动时根据上次退出时记录的状态把它恢复回来。
class NumlockService {
  static const int _vkNumLock = 0x90;
  static const int _keyeventfKeyUp = 0x0002;

  DynamicLibrary? _user32;

  DynamicLibrary get _lib =>
      _user32 ??= DynamicLibrary.open('user32.dll');

  late final _getKeyState = _lib.lookupFunction<
      Int16 Function(Int32), int Function(int)>('GetKeyState');
  late final _keybdEvent = _lib.lookupFunction<
      Void Function(Uint8, Uint8, Uint32, IntPtr),
      void Function(int, int, int, int)>('keybd_event');

  /// 当前 NumLock 是否开启（非 Windows 返回 null）
  bool? get isOn {
    if (!Platform.isWindows) return null;
    try {
      // VK_NUMLOCK 的切换位是最低位（& 1）
      return (_getKeyState(_vkNumLock) & 1) != 0;
    } catch (_) {
      return null;
    }
  }

  /// 模拟一次 NumLock 按键（按下+抬起），翻转当前状态
  void toggle() {
    if (!Platform.isWindows) return;
    try {
      _keybdEvent(_vkNumLock, 0x45, 0, 0);
      _keybdEvent(_vkNumLock, 0x45, _keyeventfKeyUp, 0);
    } catch (_) {}
  }
}
