import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/player_controller.dart';

/// 视频播放器显示组件
class VideoPlayerWidget extends StatelessWidget {
  const VideoPlayerWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final vc = controller.videoController;

        // 加载状态
        if (controller.state == PlayerState.loading) {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.blueAccent),
                  SizedBox(height: 16),
                  Text(
                    '正在加载直播...',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
          );
        }

        // 错误状态
        if (controller.state == PlayerState.error) {
          return Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.redAccent, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    '播放失败',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      final ch = controller.currentChannel;
                      if (ch != null) {
                        controller.playChannel(ch);
                      } else if (controller.flatChannels.isNotEmpty) {
                        // 启动恢复失败等场景下 currentChannel 可能为空：
                        // 兜底播放列表第一个频道，避免按钮完全无反应
                        controller
                            .playChannel(controller.flatChannels.first);
                      }
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }

        // 空闲状态
        if (vc == null || !vc.value.isInitialized) {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.live_tv, color: Colors.white30, size: 64),
                  SizedBox(height: 16),
                  Text(
                    '请选择频道开始观看',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
            ),
          );
        }

        // 视频播放
        // 部分投屏流（抖音等 MP4/FLV）音频先就绪、视频尺寸上报为 0，
        // 直接用 size 会把纹理缩成 0×0 → 有声无画面；
        // 此时用 16:9 兜底，等视频帧到达、size 更新后自动恢复真实比例
        final w = vc.value.size.width;
        final h = vc.value.size.height;
        final hasSize = w > 0 && h > 0;
        // 旋转：用独立的 ValueNotifier 只重建视频层，避免整 Stack 灰屏
        return ValueListenableBuilder<int>(
          valueListenable: controller.videoRotation,
          builder: (context, rot, _) {
            return SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.contain,
                child: RotatedBox(
                  quarterTurns: rot,
                  child: SizedBox(
                    width: hasSize ? w : 16,
                    height: hasSize ? h : 9,
                    child: VideoPlayer(vc),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
