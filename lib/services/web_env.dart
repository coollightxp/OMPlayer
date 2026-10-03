import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 全局 WebView2 环境（仅 Windows 使用）。
WebViewEnvironment? webViewEnvironment;

/// 环境创建全部失败时的错误详情（仅用于错误界面展示，不写日志文件）。
String webEnvLastError = '';

/// 本次运行实际使用的用户数据目录。
String? _resolvedUserDataFolder;

const _browserArgs =
    '--disk-cache-size=268435456 --autoplay-policy=no-user-gesture-required';

// ==================== 用户数据目录 ====================

/// 解析 WebView2 用户数据目录：
/// - exe 所在目录可写：沿用绿色版习惯的同级目录
/// - Program Files 等受保护目录：改放当前用户 LocalAppData
///   （这是"已装运行时却起不来"的常见根因：UDF 落在无写权限的位置）
String _resolveUserDataFolder() {
  final exeFile = File(Platform.resolvedExecutable);
  final exeDir = exeFile.parent;
  final exeName = exeFile.path
      .split(Platform.pathSeparator)
      .last
      .replaceAll('.exe', '');
  if (_dirWritable(exeDir)) {
    return '${exeDir.path}${Platform.pathSeparator}$exeName.WebView2';
  }
  final local = Platform.environment['LOCALAPPDATA'] ?? '';
  if (local.isNotEmpty) {
    return '$local${Platform.pathSeparator}OMPlayer'
        '${Platform.pathSeparator}WebView2';
  }
  return '${exeDir.path}${Platform.pathSeparator}$exeName.WebView2';
}

bool _dirWritable(Directory d) {
  try {
    final t = File('${d.path}${Platform.pathSeparator}.om_w_$pid');
    t.writeAsStringSync('1', flush: true);
    t.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

// ==================== 运行时目录探测 ====================

class _Candidate {
  final String folder;
  final List<int> version;
  /// true = Edge 浏览器内置的 EBWebView（仅作兜底）
  final bool edgeFallback;
  _Candidate(this.folder, this.version, this.edgeFallback);
}

List<int> _parseVersion(String name) {
  final parts = name.split('.');
  if (parts.length != 4) return const [];
  final v = parts.map(int.tryParse).toList();
  return v.contains(null) ? const [] : v.cast<int>();
}

int _cmpVersion(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return 0;
}

bool _hasRuntimeBin(String folder) =>
    File('$folder${Platform.pathSeparator}msedgewebview2.exe').existsSync();

/// 在文件系统中探测所有可用的 WebView2 运行时：
/// - 独立 Evergreen Runtime（per-machine x86/x64 + per-user）
/// - Edge 浏览器内置的 EBWebView（最后兜底）
///
/// 不依赖注册表：覆盖"运行时装成了 per-user 但应用被管理员身份启动"
/// 等加载器自动探测失效的场景。
List<_Candidate> _findCandidates() {
  final pf86 = Platform.environment['ProgramFiles(x86)'] ?? '';
  final pf64 = Platform.environment['ProgramW6432'] ??
      Platform.environment['ProgramFiles'] ??
      '';
  final lda = Platform.environment['LOCALAPPDATA'] ?? '';
  final roots = <String>{pf86, pf64, lda}
      .where((s) => s.isNotEmpty)
      .toList();
  final sep = Platform.pathSeparator;

  final result = <_Candidate>[];
  for (final root in roots) {
    // 独立 Evergreen Runtime：...\Microsoft\EdgeWebView\Application\<版本>
    final runtimeRoot = Directory(
        '$root${sep}Microsoft${sep}EdgeWebView${sep}Application');
    if (runtimeRoot.existsSync()) {
      for (final e
          in runtimeRoot.listSync(followLinks: false).whereType<Directory>()) {
        final name = e.path.split(sep).last;
        final v = _parseVersion(name);
        if (v.isNotEmpty && _hasRuntimeBin(e.path)) {
          result.add(_Candidate(e.path, v, false));
        }
      }
    }
    // Edge 浏览器内置：...\Microsoft\Edge\Application\<版本>\EBWebView
    final edgeRoot =
        Directory('$root${sep}Microsoft${sep}Edge${sep}Application');
    if (edgeRoot.existsSync()) {
      for (final e
          in edgeRoot.listSync(followLinks: false).whereType<Directory>()) {
        final v = _parseVersion(e.path.split(sep).last);
        if (v.isEmpty) continue;
        final eb = Directory('${e.path}${sep}EBWebView');
        if (eb.existsSync() && _hasRuntimeBin(eb.path)) {
          result.add(_Candidate(eb.path, v, true));
        }
      }
    }
  }
  result.sort((a, b) {
    if (a.edgeFallback != b.edgeFallback) {
      return a.edgeFallback ? 1 : -1; // 独立运行时优先
    }
    return _cmpVersion(b.version, a.version); // 版本高者优先
  });
  return result;
}

// ==================== 环境创建（多级兜底） ====================

/// 初始化 WebView2 环境。
/// 尝试顺序：① 加载器自动探测 ② 独立运行时目录（高版本优先）
/// ③ Edge 浏览器内置 EBWebView。
Future<void> initWebViewEnvironment() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  if (webViewEnvironment != null) return;

  _resolvedUserDataFolder = _resolveUserDataFolder();
  final candidates = _findCandidates();

  // null = 让 WebView2 加载器按注册表自动探测
  final seen = <String>{};
  final attempts = <String?>[null];
  for (final c in candidates) {
    if (seen.add(c.folder)) attempts.add(c.folder);
  }

  final errors = <String>[];
  for (final folder in attempts) {
    try {
      webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _resolvedUserDataFolder,
          browserExecutableFolder: folder,
          additionalBrowserArguments: _browserArgs,
        ),
      );
      webEnvLastError = '';
      return;
    } catch (e) {
      errors.add('${folder ?? '<自动探测>'} -> $e');
    }
  }
  webEnvLastError = errors.take(4).join('\n');
}

// ==================== 缓存清理 ====================

/// 清理 WebView2 纯缓存目录（Cache / Code Cache / GPUCache / Service Worker）。
/// 保留 Cookies / Local Storage 等登录态。
void cleanWebView2Cache() {
  if (!Platform.isWindows) return;
  final sep = Platform.pathSeparator;
  final exeFile = File(Platform.resolvedExecutable);
  final exeName = exeFile.path.split(sep).last.replaceAll('.exe', '');
  final legacy = '${exeFile.parent.path}$sep$exeName.WebView2';
  final folders = <String>{
    _resolvedUserDataFolder ?? _resolveUserDataFolder(),
    legacy, // 旧版本遗留目录
  };
  const cacheDirs = ['Cache', 'Code Cache', 'GPUCache', 'Service Worker'];
  for (final path in folders) {
    final wvDir = Directory(path);
    if (!wvDir.existsSync()) continue;
    for (final name in cacheDirs) {
      final d = Directory('$path$sep$name');
      if (d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }
}
