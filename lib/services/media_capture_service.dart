import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';

/// 媒体捕获服务 - 桌面端录制与截图
/// 录制使用 ffmpeg 命令行工具（需系统已安装）
/// 截图使用 screenshot 包
class MediaCaptureService {
  final ScreenshotController screenshotController = ScreenshotController();
  Process? _recordProcess;
  bool _isRecording = false;
  String? _currentRecordPath;

  bool get isRecording => _isRecording;

  /// 检查是否为桌面平台（Web 上 Platform 不可调用，先用 kIsWeb 短路）
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 检查 ffmpeg 是否可用
  Future<bool> hasFfmpeg() async {
    try {
      final result = await Process.run('ffmpeg', ['-version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 获取保存目录
  Future<String> _getSaveDir(String subDir) async {
    Directory dir;
    if (Platform.isWindows) {
      dir = Directory('${Platform.environment['USERPROFILE']}\\Videos\\OMPlayer');
    } else if (Platform.isMacOS) {
      dir = Directory('${Platform.environment['HOME']}/Movies/OMPlayer');
    } else {
      dir = Directory('${Platform.environment['HOME']}/Videos/OMPlayer');
    }
    final target = Directory('${dir.path}/$subDir');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target.path;
  }

  /// 开始录制直播流
  /// [streamUrl] 直播流地址
  /// [channelName] 频道名称（用于文件名）
  Future<bool> startRecording(String streamUrl, String channelName) async {
    if (_isRecording) return false;
    if (!await hasFfmpeg()) {
      throw Exception('未检测到 ffmpeg，请先安装 ffmpeg 以使用录制功能');
    }

    final timestamp = DateTime.now().toString().replaceAll(':', '-').replaceAll(' ', '_');
    final dir = await _getSaveDir('recordings');
    final safeName = channelName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    _currentRecordPath = '$dir/${safeName}_$timestamp.mp4';

    try {
      _recordProcess = await Process.start(
        'ffmpeg',
        [
          '-i', streamUrl,
          '-c', 'copy',
          '-bsf:a', 'aac_adtstoasc',
          '-y',
          _currentRecordPath!,
        ],
        mode: ProcessStartMode.detachedWithStdio,
      );
      _isRecording = true;
      return true;
    } catch (e) {
      _isRecording = false;
      _currentRecordPath = null;
      rethrow;
    }
  }

  /// 停止录制
  Future<String?> stopRecording() async {
    if (!_isRecording || _recordProcess == null) return null;
    try {
      // 发送 q 命令优雅退出
      _recordProcess!.stdin.write('q');
      await _recordProcess!.stdin.flush();
      await Future.delayed(const Duration(seconds: 2));
      _recordProcess?.kill();
    } catch (_) {
      _recordProcess?.kill();
    }
    final path = _currentRecordPath;
    _isRecording = false;
    _recordProcess = null;
    _currentRecordPath = null;
    return path;
  }

  /// 截取当前画面
  /// [channelName] 频道名称（用于文件名）
  Future<String?> takeScreenshot(String channelName) async {
    try {
      final Uint8List? image = await screenshotController.capture();
      if (image == null) return null;

      final timestamp = DateTime.now().toString().replaceAll(':', '-').replaceAll(' ', '_');
      final dir = await _getSaveDir('screenshots');
      final safeName = channelName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final path = '$dir/${safeName}_$timestamp.png';

      final file = File(path);
      await file.writeAsBytes(image);
      return path;
    } catch (e) {
      return null;
    }
  }
}
