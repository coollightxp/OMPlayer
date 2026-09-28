/// Web 管理服务回调（只使用基础类型，保证 Web 占位实现也能引用）
class RemoteAdminHooks {
  /// 返回当前全部配置快照：
  /// {playLists:[...], currentPlaylistId, epgs:[...], currentEpgId}
  final Future<Map<String, dynamic>> Function() getSnapshot;

  /// 手机端保存全量配置（增删改后的列表 + 当前选中项）
  final Future<void> Function(Map<String, dynamic> data) applySnapshot;

  /// 请求重新拉取：kind = playlists / epgs
  final Future<void> Function(String kind) refresh;

  const RemoteAdminHooks({
    required this.getSnapshot,
    required this.applySnapshot,
    required this.refresh,
  });
}

/// Web 端占位实现（局域网管理服务仅原生平台可用）
class RemoteAdminService {
  bool get isRunning => false;
  String get endpoint => '';

  Future<void> start({required RemoteAdminHooks hooks}) async {}

  void stop() {}
}
