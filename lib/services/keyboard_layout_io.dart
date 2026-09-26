import 'dart:ffi';
import 'dart:io';

/// Windows 10/11：启动后把窗口键盘布局切到美式英文（00000409），
/// 避免中文输入法拦截字母快捷键（按 C/E/F/M/R 会弹出候选框）。
/// 通过 user32 的 WM_INPUTLANGCHANGEREQUEST 消息实现，无需额外依赖。
void forceEnglishKeyboard() {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getForegroundWindow = user32
        .lookupFunction<IntPtr Function(), int Function()>(
            'GetForegroundWindow');
    final sendMessage = user32.lookupFunction<
        IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('SendMessageW');
    final hwnd = getForegroundWindow();
    if (hwnd == 0) return;
    // WM_INPUTLANGCHANGEREQUEST = 0x0050，lParam = en-US 的 HKL
    const wmInputLangChangeRequest = 0x0050;
    const hklEnUs = 0x04090409;
    sendMessage(
        hwnd, wmInputLangChangeRequest, 0, hklEnUs);
  } catch (_) {
    // 切换失败不影响使用
  }
}
