import 'dart:typed_data';

import 'package:fvp/fvp.dart' show FVPControllerExtensions;
import 'package:video_player/video_player.dart';

/// fvp(MDK) 原生截帧，返回 RGBA 数据
Future<Uint8List?> fvpSnapshot(VideoPlayerController controller,
        {int? width, int? height}) =>
    controller.snapshot(width: width, height: height);

/// fvp(MDK) 原生录制：to 非空开始录制，to 为 null 停止
void fvpRecord(VideoPlayerController controller,
        {String? to, String? format}) =>
    controller.record(to: to, format: format);
