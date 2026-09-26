import 'dart:typed_data';

/// Web/无文件系统平台的空实现（截图/录制入口仅桌面端开放）
class MediaCaptureService {
  static bool get isDesktop => false;

  Future<String> getSaveDir(String subDir) async => '';

  Future<String> buildFilePath(String subDir, String name, String ext) async =>
      '';

  Future<String> saveBytes(String path, Uint8List bytes) async => path;

  Future<Uint8List> rgbaToPng(
      Uint8List rgba, int width, int height) async {
    throw UnsupportedError('截图仅支持桌面端');
  }
}
