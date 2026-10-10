import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/osd_bus.dart';
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

  /// 选中节目的稳定标识（频道ID@开始时间毫秒）。
  /// EPG 数据刷新/头部裁剪后仅靠索引会指向别的节目，
  /// 用节目身份在每次构建时把 _kbIndex 重新对齐
  String? _kbSelectionKey;

  static String _programKey(EpgProgram p) =>
      '${p.channelId}@${p.startTime.millisecondsSinceEpoch}';

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
      _kbSelectionKey = null;
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
        // 记录节目身份：EPG 刷新后按身份把索引对齐回来，
        // 避免选中框/预约串到别的节目
        _kbSelectionKey = _programKey(epg[_kbIndex]);
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
    if (program.isPast) {
      OsdBus.show('该节目已结束，无法预约', icon: Icons.alarm_off);
      return;
    }
    final controller = context.read<PlayerController>();
    final reserved = controller.isProgramReserved(program);
    controller.toggleReservation(program);
    OsdBus.show(
      reserved
          ? '已取消预约：${program.title}'
          : '已预约：${program.title}，到时间将自动播放',
      icon: reserved ? Icons.alarm_off : Icons.alarm_on,
    );
  }

  /// 上下移动时让键盘选中节目可见。
  /// ListView 懒加载：目标条目在视口外很远时其 GlobalKey 还没有
  /// currentContext，ensureVisible 会静默失败。此时先用估算高度粗跳
  /// 到目标附近让条目构建，下一帧再精准居中。
  void _scrollKeyboardTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final ctx = _itemKeys.length > index
          ? _itemKeys[index].currentContext
          : null;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.5, // 尽量滚到视口中部
        );
        return;
      }
      // 目标尚未构建：粗跳到目标附近
      final pos = _scrollController.position;
      const estItemHeight = 90.0; // 含描述/进度条的条目估算高度
      final rough = (index * estItemHeight - pos.viewportDimension / 2)
          .clamp(0.0, pos.maxScrollExtent);
      pos.jumpTo(rough);
      // 下一帧条目已构建，再精准居中
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final c2 =
            _itemKeys.length > index ? _itemKeys[index].currentContext : null;
        if (c2 != null) {
          Scrollable.ensureVisible(
            c2,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0.5,
          );
        }
      });
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
          _kbSelectionKey = _programKey(epg[_kbIndex]);
        } else if (_kbSelectionKey != null) {
          // EPG 刷新后（头部裁剪/重新解析）按节目身份重新对齐索引，
          // 防止选中框和预约操作串到别的节目
          final found = epg.indexWhere((p) => _programKey(p) == _kbSelectionKey);
          if (found >= 0) {
            _kbIndex = found;
          } else {
            // 选中节目已不在列表（通常是已过期被裁剪）：钳制到边界
            _kbIndex = _kbIndex.clamp(0, epg.length - 1);
            _kbSelectionKey = _programKey(epg[_kbIndex]);
          }
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
                        OsdBus.show(
                          reserved
                              ? '已取消预约：${program.title}'
                              : '已预约：${program.title}，到时间将自动播放',
                          icon: reserved ? Icons.alarm_off : Icons.alarm_on,
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
