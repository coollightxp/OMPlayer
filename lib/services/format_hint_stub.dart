/// Web 端无法使用 dart:io，预检为空操作（video_player_web 自行处理格式）
Future<String?> inferStreamFormat({
  required String url,
  required Map<String, String> headers,
}) async =>
    null;
