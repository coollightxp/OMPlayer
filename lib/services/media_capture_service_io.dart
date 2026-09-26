import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 媒体捕获服务 - 桌面端录制与截图的文件存储
/// 录制/截帧由 fvp(MDK) 原生完成，这里只负责固定目录与 PNG 编码
class MediaCaptureService {
  /// 检查是否为桌面平台（Web 上 Platform 不可调用，先用 kIsWeb 短路）
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 获取保存目录（截图/录制固定保存到 用户视频目录/OMPlayer/）
  Future<String> getSaveDir(String subDir) async {
    late String base;
    if (Platform.isWindows) {
      base = '${Platform.environment['USERPROFILE']}\\Videos\\OMPlayer';
    } else if (Platform.isMacOS) {
      base = '${Platform.environment['HOME']}/Movies/OMPlayer';
    } else {
      base = '${Platform.environment['HOME']}/Videos/OMPlayer';
    }
    final target = Directory('$base/$subDir');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target.path;
  }

  /// 生成保存文件完整路径
  Future<String> buildFilePath(String subDir, String name, String ext) async {
    final dir = await getSaveDir(subDir);
    final ts = DateTime.now()
        .toString()
        .replaceAll(':', '-')
        .replaceAll(' ', '_')
        .split('.')
        .first;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '$dir/${safe}_$ts.$ext';
  }

  /// 保存字节到文件
  Future<String> saveBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// 将 fvp snapshot 返回的 RGBA 数据编码为 PNG
  Future<Uint8List> rgbaToPng(
      Uint8List rgba, int width, int height) async {
    final buf = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buf,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final png =
        await frame.image.toByteData(format: ui.ImageByteFormat.png);
    descriptor.dispose();
    buf.dispose();
    return png!.buffer.asUint8List();
  }
}
