import 'dart:io';

/// 关闭系统：
/// - Windows：shutdown /s /t 0 /f，立即关机，不弹系统的「几分钟后关闭」
///   提示框（倒计时由应用自己的关机卡片负责）
/// - Linux：poweroff 立即关机
/// 其它平台为空操作（退出框不显示关机按钮）
Future<void> shutdownSystem() async {
  if (Platform.isWindows) {
    await Process.run('shutdown', const ['/s', '/t', '0', '/f']);
  } else if (Platform.isLinux) {
    await Process.run('poweroff', const []);
  }
}
