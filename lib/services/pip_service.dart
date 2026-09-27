import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart' show Rect, Size;
import 'package:window_manager/window_manager.dart';

/// 画中画服务
///
/// - Android 8+：系统级画中画（按 Home 自动小窗 / 手动进入），
///   视频由原生 Surface 继续渲染，切出应用后仍可观看
/// - Windows/macOS/Linux：迷你窗口近似（缩小窗口并置顶，点击画面恢复）
/// - 其它平台（iOS/Web）：不支持
class PipService {
  static const MethodChannel _channel = MethodChannel('omplayer/pip');

  bool _android = false;
  bool _pipMode = false;
  bool _miniWindow = false;
  bool _savedFullscreen = false;
  bool _savedMaximized = false;
  bool _savedAlwaysOnTop = false;
  Rect? _savedBounds;

  /// 当前是否处于画中画/迷你窗状态
  bool get pipMode => _pipMode;

  /// 是否 Android 平台（用于自动画中画同步）
  bool get isAndroid => _android;

  final StreamController<bool> _pipModeCtrl =
      StreamController<bool>.broadcast();

  /// 画中画状态变化（进入/退出）通知
  Stream<bool> get onPipModeChanged => _pipModeCtrl.stream;

  PipService() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (call.method == 'pipChanged') {
      _pipMode = call.arguments == true;
      _pipModeCtrl.add(_pipMode);
    }
  }

  /// 当前平台是否支持画中画
  Future<bool> isSupported() async {
    try {
      if (kIsWeb) return false;
      if (Platform.isAndroid) {
        _android = true;
        return await _channel.invokeMethod<bool>('isPipSupported') ?? false;
      }
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 进入画中画（Android 系统小窗 / 桌面迷你窗）
  Future<bool> enter() async {
    try {
      if (kIsWeb) return false;
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<bool>('enterPip') ?? false;
      }
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        await _enterMiniWindow();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Android：离开应用（按 Home/任务键）时是否自动进入画中画
  Future<void> setAutoPip(bool enabled) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('setAutoPip', {'enabled': enabled});
    } catch (_) {}
  }

  /// 桌面端：退出迷你窗口，恢复原窗口尺寸/位置/置顶/全屏状态。
  /// 返回 true 表示此前处于迷你窗并已完成恢复。
  Future<bool> exitMiniWindow() async {
    if (!_miniWindow) return false;
    _miniWindow = false;
    _pipMode = false;
    _pipModeCtrl.add(false);
    try {
      final b = _savedBounds;
      if (b != null && b.width > 0 && b.height > 0) {
        await windowManager.setBounds(b);
      }
      await windowManager.setAlwaysOnTop(_savedAlwaysOnTop);
      if (_savedFullscreen) {
        await windowManager.setFullScreen(true);
      } else if (_savedMaximized) {
        await windowManager.maximize();
      } else {
        // 普通窗口：恢复尺寸后强制重建一次视频输出表面，
        // 降低 Windows 下快速缩放残留灰白伪影的概率
        await _refreshSurface();
      }
    } catch (_) {}
    return true;
  }

  /// Windows 下程序化快速缩放窗口（进出迷你窗）后，fvp/MDK 的视频输出
  /// 表面可能与合成器短暂失配，画面上残留一层灰白半透明伪影且不消失。
  /// 模拟一次用户式微调（+1px 再还原）强制 Flutter/视频输出按最终尺寸
  /// 完整重建；150ms 后再刷一次，覆盖表面重建竞态。
  Future<void> _refreshSurface() async {
    try {
      final size = await windowManager.getSize();
      await windowManager.setSize(Size(size.width + 1, size.height + 1));
      await windowManager.setSize(size);
      Future.delayed(const Duration(milliseconds: 150), () async {
        try {
          final s = await windowManager.getSize();
          if (s.width == size.width && s.height == size.height) {
            await windowManager.setSize(Size(size.width + 1, size.height + 1));
            await windowManager.setSize(size);
          }
        } catch (_) {}
      });
    } catch (_) {}
  }

  /// 桌面端：把窗口缩小为置顶迷你窗（保存原状态以便恢复）
  Future<void> _enterMiniWindow() async {
    if (_miniWindow) return;
    try {
      _savedFullscreen = await windowManager.isFullScreen();
      if (_savedFullscreen) {
        await windowManager.setFullScreen(false);
      }
      // 最大化窗口上 setSize 行为异常：先还原，记下标记恢复时再用
      _savedMaximized = await windowManager.isMaximized();
      if (_savedMaximized) {
        await windowManager.restore();
      }
      _savedBounds = await windowManager.getBounds();
      _savedAlwaysOnTop = await windowManager.isAlwaysOnTop();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(const Size(480, 270));
      _miniWindow = true;
      _pipMode = true;
      _pipModeCtrl.add(true);
    } catch (_) {}
  }
}
