import 'dart:typed_data';

import 'package:video_player/video_player.dart';

/// Web 空实现
Future<Uint8List?> fvpSnapshot(VideoPlayerController controller,
        {int? width, int? height}) async =>
    null;

void fvpRecord(VideoPlayerController controller, {String? to, String? format}) {}
