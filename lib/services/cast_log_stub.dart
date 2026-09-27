/// 投屏诊断日志（Web 占位）：不记录任何内容
class CastLog {
  CastLog._();

  static Future<String> path() async => '';

  static void write(String msg) {}
}
