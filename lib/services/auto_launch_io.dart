import 'dart:io';

/// 开机启动（纯 dart:io 实现，避免 launch_at_startup 的 win32 版本
/// 与 file_picker 13 冲突）：
/// - Windows: 写 HKCU\...\Run 注册表项（无需管理员权限）
/// - macOS:   ~/Library/LaunchAgents 下的 LaunchAgent plist
/// - Linux:   ~/.config/autostart 下的 .desktop 文件

const _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
const _valueName = 'OMPlayer';
const _label = 'com.omplayer.app';

/// 兼容旧调用，自实现无需初始化
void setupAutoLaunch() {}

Future<void> setAutoLaunchEnabled(bool enabled) async {
  try {
    if (Platform.isWindows) {
      await _setWindows(enabled);
    } else if (Platform.isMacOS) {
      await _setMacOS(enabled);
    } else if (Platform.isLinux) {
      await _setLinux(enabled);
    }
  } catch (_) {
    // 静默失败，不影响应用启动
  }
}

Future<bool> isAutoLaunchEnabled() async {
  try {
    if (Platform.isWindows) {
      final r = await Process.run(
          'reg', ['query', 'HKCU\\$_runKey', '/v', _valueName]);
      return r.exitCode == 0;
    } else if (Platform.isMacOS) {
      return File(await _macPlistPath()).exists();
    } else if (Platform.isLinux) {
      return File(await _linuxDesktopPath()).exists();
    }
  } catch (_) {}
  return false;
}

// ==================== Windows ====================

Future<void> _setWindows(bool enabled) async {
  if (enabled) {
    await Process.run('reg', [
      'add',
      'HKCU\\$_runKey',
      '/v',
      _valueName,
      '/t',
      'REG_SZ',
      '/d',
      '"${Platform.resolvedExecutable}"',
      '/f',
    ]);
  } else {
    // 项不存在时 reg delete 会返回非零，忽略即可
    await Process.run('reg',
        ['delete', 'HKCU\\$_runKey', '/v', _valueName, '/f']);
  }
}

// ==================== macOS ====================

Future<String> _macPlistPath() async {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/Library/LaunchAgents/$_label.plist';
}

Future<void> _setMacOS(bool enabled) async {
  final path = await _macPlistPath();
  final file = File(path);
  if (enabled) {
    await file.parent.create(recursive: true);
    await file.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>${Platform.resolvedExecutable}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''');
  } else if (await file.exists()) {
    await file.delete();
  }
}

// ==================== Linux ====================

Future<String> _linuxDesktopPath() async {
  final home = Platform.environment['HOME'] ?? '';
  final config = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  return '$config/autostart/omplayer.desktop';
}

Future<void> _setLinux(bool enabled) async {
  final path = await _linuxDesktopPath();
  final file = File(path);
  if (enabled) {
    await file.parent.create(recursive: true);
    await file.writeAsString('''[Desktop Entry]
Type=Application
Name=OMPlayer
Exec=${Platform.resolvedExecutable}
Terminal=false
X-GNOME-Autostart-enabled=true
''');
  } else if (await file.exists()) {
    await file.delete();
  }
}
