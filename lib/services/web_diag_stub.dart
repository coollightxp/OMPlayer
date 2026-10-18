/// 网页频道诊断埋点（Web 平台占位）：无文件系统，全部空操作
class WebDiag {
  WebDiag._();

  static String appVersion = '';

  static void begin(String url, String title) {}

  static void end() {}

  static void log(String event, [String detail = '']) {}

  static Future<String> flush() async => '';
}
