import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// 选择本地直播源文件（任意格式：.m3u/.m3u8/.txt/TVBox/.nzk/.conf/无后缀…），
/// 加载时按内容自动识别格式。
///
/// - Android：走自研 MethodChannel（ACTION_GET_CONTENT + */*）。
///   file_picker 13 安卓端对 any/custom 都固定发 ACTION_OPEN_DOCUMENT
///   （SAF），而电视盒子上常见的文件管理器多数只响应 ACTION_GET_CONTENT、
///   不提供 DocumentsProvider；SAF 还会按 MIME 把冷门/无后缀文件置灰，
///   表现为「很多格式选不到」。GET_CONTENT + */* 不按格式过滤，
///   与 Windows 原生对话框「所有文件」的体验一致。
///   content:// 选中后由原生侧复制到应用缓存并回传绝对路径。
/// - Windows/Linux：file_picker 原生对话框，FileType.any 即所有文件；
///   Windows 全屏置顶窗口会盖住模态对话框，选择期间临时取消置顶。
///
/// 返回文件绝对路径；用户取消返回 null。
Future<String?> pickLocalPlaylistFile() async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('omplayer/local_file_picker');
    return channel.invokeMethod<String>('pick');
  }

  var restoreTopmost = false;
  try {
    restoreTopmost = await windowManager.isAlwaysOnTop();
    if (restoreTopmost) {
      await windowManager.setAlwaysOnTop(false);
      // 等窗口管理器应用完层级变更，避免对话框仍被盖住
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  } catch (_) {
    restoreTopmost = false;
  }
  try {
    // file_picker 12+ 新 API：FilePicker.pickFile 直接返回 PlatformFile?
    // 放开所有文件类型：直播源后缀五花八门，加载时按内容自动识别格式
    final file = await FilePicker.pickFile(type: FileType.any);
    return file?.path;
  } finally {
    if (restoreTopmost) {
      try {
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {}
    }
  }
}
