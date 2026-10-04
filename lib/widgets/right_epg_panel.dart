import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

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
  State<RightEpgPanel> createState() => RightEpgPanelState();
}

class RightEpgPanelState extends State<RightEpgPanel> {
  final ScrollController _scrollController = ScrollController();
  // 记录已定位过的节目单首项，避免每次 tick 都重复滚动
  String? _lastScrolledKey;

  /// 遥控器/键盘导航选中的节目索引
  int _kbIndex = 0;
  bool _kbInitialized = false;

  /// OK 按下保持标记：按住时系统自动重复的 down 事件只触发一次预约
  bool _okHeld = false;

  /// 上次预约/取消预约的时间，长按期间的二次触发忽略，
  /// 避免网络/EPG 数据刷新时连续 toggle 产生混乱提示
  DateTime? _lastToggleAt;

  /// 各条目的 GlobalKey，用于 Scrollable.ensureVisible 精准定位
  /// （替代固定 _itemHeight 的手算，解决 description/进度条导致的高度差异）
  final List<GlobalKey> _itemKeys = <GlobalKey>[];

  /// 设计稿宽度
  static const double _designWidth = 340;

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
      _kbInitialized = false;
      _kbIndex = 0;
      _okHeld = false;
    }
  }

  /// 遥控器/键盘按键入口（由 PlayerScreen 统一分发）。
  /// 上下选择节目；单按 OK 预约/取消（按住不重复触发）；返回关闭。
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!widget.isOpen || !mounted) return;
    if (action == 'back') {
      if (isDown) {
        _okHeld = false;
        widget.onClose();
      }
      return;
    }
    final epg = context.read<PlayerController>().getCurrentEpg();
    if (epg.isEmpty) return;
    if (action == 'up' || action == 'down') {
      if (!isDown) return;
      setState(() {
        _kbIndex = (_kbIndex + (action == 'down' ? 1 : -1))
            .clamp(0, epg.length - 1);
      });
      _scrollKeyboardTo(_kbIndex);
      return;
    }
    if (action == 'ok') {
      if (isDown) {
        // 单按 OK 直接预约/取消：按住时系统重复 down 事件由 _okHeld 去重，
        // 按住不重复触发（否则会连环 toggle 且 EPG 刷新后索引偏移，
        // 把"下面好几个节目"也预约上）
        if (_okHeld) return;
        _okHeld = true;
        if (_lastToggleAt != null &&
            DateTime.now().difference(_lastToggleAt!) <
                const Duration(milliseconds: 800)) {
          return;
        }
        _lastToggleAt = DateTime.now();
        _toggleReservation(epg[_kbIndex.clamp(0, epg.length - 1)]);
      } else {
        _okHeld = false;
      }
    }
  }

  /// 预约/取消预约，并给出结果提示
  void _toggleReservation(EpgProgram program) {
    final messenger = ScaffoldMessenger.of(context);
    if (program.isPast) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('该节目已结束，无法预约'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final controller = context.read<PlayerController>();
    final reserved = controller.isProgramReserved(program);
    controller.toggleReservation(program);
    messenger.showSnackBar(
      SnackBar(
        content: Text(reserved
            ? '已取消预约：${program.title}'
            : '已预约：${program.title}，到时间将自动播放'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 上下移动时让键盘选中节目可见：用 Scrollable.ensureVisible 精准定位，
  /// 不再手算 itemHeight（各条目因 description/进度条存在高度差异，
  /// 手算会累积误差导致选中框滚出视口）
  void _scrollKeyboardTo(int index) {
    if (index < 0 || index >= _itemKeys.length) return;
    final key = _itemKeys[index];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: 0.5, // 尽量滚到视口中部
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scale = panelScaleOf(context);
    final drawerW = _designWidth * scale;
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
          child: ScaledPanel(
            designWidth: _designWidth,
            alignment: Alignment.centerRight,
            scale: scale,
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
        // 打开后首次构建：键盘焦点落在当前正在播放的节目
        if (!_kbInitialized) {
          _kbInitialized = true;
          final nowIdx = epg.indexWhere((p) => p.isNowPlaying);
          _kbIndex = nowIdx >= 0 ? nowIdx.clamp(0, epg.length - 1) : 0;
        }
        // 同步维护与条目数一致的 GlobalKey 列表
        while (_itemKeys.length < epg.length) {
          _itemKeys.add(GlobalKey());
        }
        if (_itemKeys.length > epg.length) {
          _itemKeys.removeRange(epg.length, _itemKeys.length);
        }
        final list = ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: epg.length,
          itemBuilder: (context, index) {
            return _EpgProgramTile(
              key: _itemKeys[index],
              program: epg[index],
              keyboardSelected: index == _kbIndex,
            );
          },
        );
        _maybeScrollToNow(epg);
        return list;
      },
    );
  }

  /// 打开节目单时，自动滚动定位到当前正在播放的节目。
  /// 用 GlobalKey + ensureVisible 精准定位，不再手算 itemHeight
  void _maybeScrollToNow(List<EpgProgram> epg) {
    final key = epg.isEmpty ? '' : epg.first.channelId;
    if (_lastScrolledKey == key) return;
    _lastScrolledKey = key;
    if (epg.isEmpty) return;
    final idx = epg.indexWhere((p) => p.isNowPlaying);
    if (idx < 0) return;
    _scrollKeyboardTo(idx);
  }
}

class _EpgProgramTile extends StatelessWidget {
  final EpgProgram program;

  /// 遥控器/键盘焦点高亮
  final bool keyboardSelected;

  const _EpgProgramTile({
    super.key,
    required this.program,
    this.keyboardSelected = false,
  });

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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isNow
            ? Colors.blueAccent.withOpacity(0.25)
            : (keyboardSelected
                ? Colors.white.withOpacity(0.10)
                : Colors.white.withOpacity(0.04)),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: keyboardSelected
              ? Colors.white70
              : (isNow ? Colors.blueAccent : Colors.transparent),
          width: keyboardSelected ? 1.2 : 1,
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
