import 'package:flutter/services.dart';

/// 安卓原生桥：系统画中画（小窗）、退到后台听电视、
/// 通知栏音频卡片（含上一台/暂停/下一台/关闭）。
///
/// 原生实现由 CI 在 flutter create 生成 android/ 工程时注入
/// （MainActivity + AudioPlaybackService，AndroidManifest 开启
/// supportsPictureInPicture / 前台服务权限）。其他平台没有该通道，
/// 调用会抛 MissingPluginException，这里统一吞掉并返回 false。
const MethodChannel _channel = MethodChannel('omplayer/pip');

void Function(bool active)? _pipCb;
void Function(String cmd)? _audioCb;
bool _handlerInstalled = false;

void _ensureHandler() {
  if (_handlerInstalled) return;
  _handlerInstalled = true;
  _channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'pip':
        _pipCb?.call(call.arguments == true);
        break;
      case 'audio':
        // 通知栏按钮：playpause / prev / next / stop / restore
        _audioCb?.call(call.arguments?.toString() ?? '');
        break;
    }
  });
}

/// 进入系统画中画；成功返回 true（Android 8.0+ 且 activity 在前台）
Future<bool> enterPip() async {
  try {
    return await _channel.invokeMethod<bool>('enter') ?? false;
  } catch (_) {
    return false;
  }
}

/// 退出画中画（恢复到全屏窗口）
Future<void> exitPip() async {
  try {
    await _channel.invokeMethod('exit');
  } catch (_) {}
}

/// 把应用退到后台但保持播放（听电视隐藏窗口）；成功返回 true
Future<bool> moveToBackground() async {
  try {
    return await _channel.invokeMethod<bool>('background') ?? false;
  } catch (_) {
    return false;
  }
}

/// 是否 Android TV / 电视盒子（Leanback 或电视系统特性）。
/// 电视端没有通知栏可操作，「听电视」必须始终留在信息卡片上。
Future<bool> isTvDevice() async {
  try {
    return await _channel.invokeMethod<bool>('isTv') ?? false;
  } catch (_) {
    return false;
  }
}

/// 通知权限是否已授予（Android 13+）。没权限时通知卡片不会显示，
/// 隐藏窗口后将没有任何可操作入口，调用方应据此不隐藏。
/// 其它平台没有该通道，一律视为可用（true）。
Future<bool> notifGranted() async {
  try {
    return await _channel.invokeMethod<bool>('notifGranted') ?? true;
  } catch (_) {
    return true;
  }
}

/// 打开系统里本应用的通知设置页（引导手动开启权限）。
/// 成功打开返回 true；非安卓/无实现返回 false。
Future<bool> openNotifSettings() async {
  try {
    return await _channel.invokeMethod<bool>('openNotifSettings') ?? false;
  } catch (_) {
    return false;
  }
}

/// 更新通知栏「音频播放」卡片（前台服务，含上一台/暂停/下一台/关闭）
/// [logo]/[logoKey] 为当前频道台标 PNG 的 base64 与标识：
/// 原生把它作为卡片右侧大图与锁屏封面（变化时才重新解码）
Future<void> audioNotify(
    {required String name,
    required String program,
    required bool playing,
    String logo = '',
    String logoKey = ''}) async {
  try {
    await _channel.invokeMethod('audioUpdate', {
      'name': name,
      'program': program,
      'playing': playing,
      'logo': logo,
      'logoKey': logoKey,
    });
  } catch (_) {}
}

/// 关闭通知栏卡片（退出听电视时）
Future<void> audioStop() async {
  try {
    await _channel.invokeMethod('audioStop');
  } catch (_) {}
}

/// 注册画中画状态回调：用户点画中画窗口的全屏/关闭时由原生通知
void listenPipState(void Function(bool active)? cb) {
  _pipCb = cb;
  _ensureHandler();
}

/// 注册通知栏卡片命令回调（playpause / prev / next / stop / restore）
void listenAudioCommands(void Function(String cmd)? cb) {
  _audioCb = cb;
  _ensureHandler();
}
