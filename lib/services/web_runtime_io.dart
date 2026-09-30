import 'dart:io';

/// WebView2 Evergreen Runtime 客户端 GUID
const _webView2ClientGuid =
    r'{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

/// 检测内嵌网页运行环境是否就绪。
///
/// Windows 上 flutter_inappwebview 依赖 Microsoft Edge WebView2
/// Runtime，部分 Win10 家庭版/LTSC/精简系统未预装，表现为网页频道
/// 永远卡在「正在打开网页频道」。通过 reg query 查注册表中的
/// Evergreen Runtime 版本号（pv）判断。
/// 其余平台（macOS/Linux/移动端）内核随系统提供，恒为可用。
Future<bool> detectEmbeddedWebRuntime() async {
  if (!Platform.isWindows) return true;
  // 依次查：机器级 32 位（最常见）、机器级 64 位、用户级安装
  final keys = <String>[
    r'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$_webView2ClientGuid',
    r'HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\$_webView2ClientGuid',
    r'HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\$_webView2ClientGuid',
  ];
  for (final key in keys) {
    try {
      final r = await Process.run('reg', ['query', key, '/v', 'pv']);
      if (r.exitCode == 0 && r.stdout.toString().contains('pv')) {
        return true;
      }
    } catch (_) {
      // reg 命令不可用/键不存在，继续尝试下一个位置
    }
  }
  return false;
}
