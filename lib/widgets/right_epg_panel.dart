import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/player_controller.dart';

/// 右侧隐藏式 EPG 节目菜单面板
/// 显示与当前直播频道对应的节目单
class RightEpgPanel extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  /// 鼠标悬停在面板上/移出面板（悬停期间不自动隐藏）
  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;
  final VoidCallback? onHoverMove;

  const RightEpgPanel({
    super.key,
    required this.isOpen,
    required this.onClose,
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
  });

  @override
  State<RightEpgPanel> createState() => _RightEpgPanelState();
}

class _RightEpgPanelState extends State<RightEpgPanel> {
  final ScrollController _scrollController = ScrollController();
  // 记录已定位过的节目单首项，避免每次 tick 都重复滚动
  String? _lastScrolledKey;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RightEpgPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板由开变关时重置定位标记，下次打开重新滚动到当前节目
    if (oldWidget.isOpen && !widget.isOpen) {
      _lastScrolledKey = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    // 平台 + 最短边：手机横屏 width 是长边，按 width 会误判
    final isPhone = defaultTargetPlatform == TargetPlatform.android &&
        MediaQuery.of(context).size.shortestSide < 600;
    final drawerW = isPhone ? (screenW * 0.78).clamp(220.0, 270.0) : 340.0;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      right: widget.isOpen ? 0 : -drawerW,
      top: 0,
      bottom: 0,
      width: drawerW,
      child: MouseRegion(
        onEnter: (_) => widget.onHoverEnter?.call(),
        onExit: (_) => widget.onHoverExit?.call(),
        onHover: (_) => widget.onHoverMove?.call(),
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
      ),
    );
  }

  Widget _buildHeader() {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final isPhone = defaultTargetPlatform == TargetPlatform.android &&
            MediaQuery.of(context).size.shortestSide < 600;
        return Container(
          padding: EdgeInsets.symmetric(
              horizontal: isPhone ? 12 : 16, vertical: isPhone ? 10 : 12),
          child: Row(
            children: [
              Icon(Icons.menu_open,
                  color: Colors.white, size: isPhone ? 20 : 22),
              SizedBox(width: isPhone ? 8 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '节目单 EPG',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isPhone ? 15 : 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      controller.currentChannel?.name ?? '未选择频道',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                    // 联动显示当前正在播放的节目名
                    if (controller.currentProgram != null)
                      Text(
                        '正在直播：${controller.currentProgram!.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.greenAccent, fontSize: 12),
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
        final list = ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: epg.length,
          itemBuilder: (context, index) {
            return _EpgProgramTile(program: epg[index]);
          },
        );
        _maybeScrollToNow(epg);
        return list;
      },
    );
  }

  /// 打开节目单时，自动滚动定位到当前正在播放的节目
  void _maybeScrollToNow(List<EpgProgram> epg) {
    final key = epg.isEmpty ? '' : epg.first.channelId;
    if (_lastScrolledKey == key) return;
    _lastScrolledKey = key;
    if (epg.isEmpty) return;
    final idx = epg.indexWhere((p) => p.isNowPlaying);
    if (idx < 0) return;
    // 单条节目卡片估算高度：外边距 8 + 内边距 24 + 三行文字 ~64 ≈ 96
    const itemHeight = 96.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final viewport = _scrollController.position.viewportDimension;
      final target = (idx * itemHeight - viewport / 2 + itemHeight / 2)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
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

    // 节目条目本身不可点击（避免误触切台）；
    // 只有右侧的“预约”按钮可操作
    return _buildCard(context, isNow, isPast, canReserve);
  }

  Widget _buildCard(
      BuildContext context, bool isNow, bool isPast, bool canReserve) {
    final isPhone = defaultTargetPlatform == TargetPlatform.android &&
        MediaQuery.of(context).size.shortestSide < 600;
    return Container(
      margin: EdgeInsets.symmetric(
          horizontal: isPhone ? 10 : 12, vertical: isPhone ? 3 : 4),
      padding: EdgeInsets.all(isPhone ? 10 : 12),
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
