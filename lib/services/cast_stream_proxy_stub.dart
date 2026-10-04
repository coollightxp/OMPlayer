/// Web 端空实现：浏览器无法起本地 HTTP 服务
class CastStreamProxy {
  CastStreamProxy._();
  static final CastStreamProxy instance = CastStreamProxy._();

  Future<String?> wrapUrl(String rawUrl) async => null;
  Future<void> stop() async {}
}
