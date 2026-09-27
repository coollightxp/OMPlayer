import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 10/11：把英文(美式)键盘布局激活为当前输入法，
/// 避免中文输入法拦截字母快捷键（按 C/E/F/M/R 会弹出候选框）。
/// 通过 user32 的 LoadKeyboardLayoutW + KLF_ACTIVATE 实现：
/// 直接给当前线程换上 en-US 布局，比 WM_INPUTLANGCHANGEREQUEST
/// 消息更可靠（后者依赖窗口处理消息，焦点不在本窗口时无效）。
void forceEnglishKeyboard() {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final loadKeyboardLayout = user32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, int)>('LoadKeyboardLayoutW');
    // "00000409" = 英文(美国)，KLF_ACTIVATE = 0x00000001
    const klfActivate = 0x00000001;
    final name = '00000409'.toNativeUtf16();
    try {
      loadKeyboardLayout(name, klfActivate);
    } finally {
      calloc.free(name);
    }
  } catch (_) {
    // 切换失败不影响使用
  }
}
