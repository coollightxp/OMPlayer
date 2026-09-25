import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/player_controller.dart';

/// 右侧隐藏式 EPG 节目菜单面板
/// 显示与当前直播频道对应的节目单
class RightEpgPanel extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  const RightEpgPanel({
    super.key,
    required this.isOpen,
    required this.onClose,
  });

  @override
  State<RightEpgPanel> createState() => _RightEpgPanelState();
}

class _RightEpgPanelState extends State<RightEpgPanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      right: widget.isOpen ? 0 : -340,
      top: 0,
      bottom: 0,
      width: 340,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: widget.isOpen ? 1.0 : 0.0,
        child: Material(
          color: Colors.black87,
          elevation: 16,
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                const Divider(height: 1, color: Colors.white12),
                Expanded(child: _buildEpgList()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.menu_open, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '节目单 EPG',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      controller.currentChannel?.name ?? '未选择频道',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: widget.onClose,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEpgList() {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final epg = controller.getCurrentEpg();
        if (epg.isEmpty) {
          return const Center(
            child: Text(
              '暂无节目单',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: epg.length,
          itemBuilder: (context, index) {
            return _EpgProgramTile(program: epg[index]);
          },
        );
      },
    );
  }
}

class _EpgProgramTile extends StatelessWidget {
  final EpgProgram program;

  const _EpgProgramTile({required this.program});

  @override
  Widget build(BuildContext context) {
    final isNow = program.isNowPlaying;
    final isPast = program.isPast;
    final canReserve = !isPast;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isNow
            ? Colors.blueAccent.withOpacity(0.25)
            : Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isNow ? Colors.blueAccent : Colors.transparent,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _statusIcon(),
                size: 14,
                color: isNow
                    ? Colors.greenAccent
                    : (isPast ? Colors.white38 : Colors.white70),
              ),
              const SizedBox(width: 6),
              Text(
                program.timeRange,
                style: TextStyle(
                  color: isNow ? Colors.greenAccent : Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (isNow)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text(
                    '直播中',
                    style: TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              const Spacer(),
              // 预约按钮
              if (canReserve)
                Consumer<PlayerController>(
                  builder: (context, controller, _) {
                    final reserved = controller.isProgramReserved(program);
                    return IconButton(
                      icon: Icon(
                        reserved
                            ? Icons.alarm_on
                            : Icons.alarm_add,
                        color: reserved ? Colors.amber : Colors.white54,
                        size: 20,
                      ),
                      onPressed: () {
                        controller.toggleReservation(program);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(reserved
                                ? '已取消预约：${program.title}'
                                : '已预约：${program.title}，到时间将自动播放'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      tooltip: reserved ? '取消预约' : '预约节目',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            program.title,
            style: TextStyle(
              color: isPast ? Colors.white38 : Colors.white,
              fontSize: 14,
              fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (program.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              program.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isPast ? Colors.white24 : Colors.white54,
                fontSize: 11,
              ),
            ),
          ],
          if (isNow) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: program.progress,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(
                    Colors.greenAccent),
                minHeight: 3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _statusIcon() {
    if (program.isNowPlaying) return Icons.play_circle_fill;
    if (program.isPast) return Icons.check_circle_outline;
    return Icons.schedule;
  }
}
