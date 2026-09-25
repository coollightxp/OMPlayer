import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/player_controller.dart';

/// 底部隐藏面板 - 显示当前播放节目的名称信息
class BottomProgramPanel extends StatefulWidget {
  final bool isVisible;
  final VoidCallback onTogglePlayPause;

  const BottomProgramPanel({
    super.key,
    required this.isVisible,
    required this.onTogglePlayPause,
  });

  @override
  State<BottomProgramPanel> createState() => _BottomProgramPanelState();
}

class _BottomProgramPanelState extends State<BottomProgramPanel> {
  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      left: 0,
      right: 0,
      bottom: widget.isVisible ? 0 : -120,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: widget.isVisible ? 1.0 : 0.0,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withOpacity(0.7),
                Colors.black.withOpacity(0.9),
              ],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 30, 20, 16),
              child: _buildContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final info = controller.getNowPlayingInfo();
        if (info.isEmpty) {
          return const SizedBox.shrink();
        }
        return Row(
          children: [
            // 节目信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 频道名
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          info.channelName,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 当前节目名 + 时间段
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          info.programTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (info.timeRange != null) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            info.timeRange!,
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  // 下一节目
                  if (info.nextProgramTitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '接下来：${info.nextProgramTitle}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  // 节目结束时间倒计时
                  if (info.programEndTime != null)
                    _buildCountdown(info.programEndTime!),
                ],
              ),
            ),
            // 控制按钮
            const SizedBox(width: 16),
            _buildControlButtons(controller),
          ],
        );
      },
    );
  }

  Widget _buildCountdown(DateTime endTime) {
    final diff = endTime.difference(DateTime.now());
    if (diff.isNegative) return const SizedBox.shrink();
    final minutes = diff.inMinutes;
    final seconds = diff.inSeconds.remainder(60);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '距结束 ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
        style: const TextStyle(color: Colors.amber, fontSize: 11),
      ),
    );
  }

  Widget _buildControlButtons(PlayerController controller) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上一个播放源（无更多源时禁用）
        IconButton(
          icon: const Icon(Icons.skip_previous, size: 24),
          color: Colors.white,
          disabledColor: Colors.white24,
          onPressed: controller.hasPrevSource ? controller.prevSource : null,
          tooltip: '上一个源',
        ),
        // 源序号
        Text(
          '源${controller.sourceIndex + 1}/${controller.sourceCount}',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        // 下一个播放源（无更多源时禁用）
        IconButton(
          icon: const Icon(Icons.skip_next, size: 24),
          color: Colors.white,
          disabledColor: Colors.white24,
          onPressed: controller.hasNextSource ? controller.nextSource : null,
          tooltip: '下一个源',
        ),
        const SizedBox(width: 4),
        // 播放/暂停
        IconButton(
          icon: Icon(
            controller.isPlaying ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
            size: 28,
          ),
          onPressed: widget.onTogglePlayPause,
        ),
      ],
    );
  }
}
