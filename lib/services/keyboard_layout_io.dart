import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows：仅把【本程序窗口】的输入法切到英文(美式)，
/// 避免中文输入法拦截字母快捷键（按 C/E/F/M/R 弹候选框），
/// 且绝不影响系统其它程序的输入法状态。
///
/// 实现分三步（全部只作用于本进程/本线程）：
/// 1. LoadKeyboardLayoutW("00000409", 不带 KLF_ACTIVATE)：
///    确保 en-US 布局已加载。不带激活标志，不会切换当前任何窗口的输入法；
/// 2. ActivateKeyboardLayout(hkl, 0)：只为【调用线程】（即本程序窗口
///    所在线程）激活英文布局 —— 这正是系统"每个应用可单独切换输入法"
///    所用的机制，其它程序保持自己的输入法；
/// 3. 向本程序窗口 PostMessage(WM_INPUTLANGCHANGEREQUEST)：
///    等价于用户在本窗口按 Win+空格，仅对本窗口生效。
///
/// 注意：绝不能使用 LoadKeyboardLayoutW 的 KLF_ACTIVATE 标志，
/// 它在窗口创建早期调用时会把英文布局提升为系统会话默认输入法，
/// 导致其它程序（如编辑器）也被切到英文。
void forceEnglishKeyboard() {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final loadKeyboardLayout = user32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, int)>('LoadKeyboardLayoutW');
    final activateKeyboardLayout = user32.lookupFunction<
        IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
        'ActivateKeyboardLayout');
    final getForegroundWindow = user32
        .lookupFunction<IntPtr Function(), int Function()>(
            'GetForegroundWindow');
    final postMessage = user32.lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('PostMessageW');

    // 1) 仅加载 en-US 布局（不激活，不影响其它程序）
    final name = '00000409'.toNativeUtf16();
    int hkl = 0;
    try {
      hkl = loadKeyboardLayout(name, 0);
    } finally {
      calloc.free(name);
    }
    if (hkl == 0) return;

    // 2) 只为本程序窗口线程激活英文布局
    activateKeyboardLayout(hkl, 0);

    // 3) 通知本程序窗口输入法已切换（此时本窗口刚被 focus，是前台窗口）
    final hwnd = getForegroundWindow();
    if (hwnd != 0) {
      const wmInputLangChangeRequest = 0x0050;
      postMessage(hwnd, wmInputLangChangeRequest, 0, hkl);
    }
  } catch (_) {
    // 切换失败不影响使用
  }
}
