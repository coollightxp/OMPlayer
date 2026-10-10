import 'dart:io';

/// 关闭系统：
/// - Windows：shutdown /s /t 5，5 秒后关机，用户可运行 `shutdown /a` 取消
/// - Linux：poweroff 立即关机
/// 其它平台为空操作（退出框不显示关机按钮）
Future<void> shutdownSystem() async {
  if (Platform.isWindows) {
    await Process.run('shutdown', const ['/s', '/t', '5']);
  } else if (Platform.isLinux) {
    await Process.run('poweroff', const []);
  }
}
