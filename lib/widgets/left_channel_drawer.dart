import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

/// 左侧两级抽屉式频道面板
/// 第一级：频道分类列表
/// 第二级：选中分类下的频道列表
class LeftChannelDrawer extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  /// 鼠标悬停在面板上/移出面板（悬停期间不自动隐藏）
  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;
  final VoidCallback? onHoverMove;

  /// 点击频道后回调（用于重置光标隐藏定时器等）
  final VoidCallback? onChannelTap;

  /// 空列表时「去设置添加」按钮回调
  final VoidCallback? onOpenSettings;

  const LeftChannelDrawer({
    super.key,
    required this.isOpen,
    required this.onClose,
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
    this.onChannelTap,
    this.onOpenSettings,
  });

  @override
  State<LeftChannelDrawer> createState() => LeftChannelDrawerState();
}

class LeftChannelDrawerState extends State<LeftChannelDrawer> {
  ChannelCategory? _selectedCategory;
  final ScrollController _categoryScroll = ScrollController();
  final ScrollController _channelScroll = ScrollController();

  /// 遥控器/键盘导航的当前选中索引（与鼠标点击的 isCurrent 播放中区分）
  int _kbCategoryIndex = 0;
  int _kbChannelIndex = 0;

  /// 上次触发播放的时间，用于播放内核重建期间的防抖
  DateTime? _lastPlayAt;

  /// 频道条目的 GlobalKey，用于 ensureVisible 精准定位
  /// （替代固定 itemHeight 的手算，避免长频道名换行导致高度不一致）
  final Map<int, GlobalKey> _channelKeys = <int, GlobalKey>{};
  final Map<int, GlobalKey> _categoryKeys = <int, GlobalKey>{};

  /// 设计稿宽度（面板内容按此尺寸设计，缩放交给 ScaledPanel）
  static const double _designWidth = 320;

  @override
  void dispose() {
    _categoryScroll.dispose();
    _channelScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LeftChannelDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 打开时直接定位到当前播放频道所在分类，并滚动到当前频道
    if (!oldWidget.isOpen && widget.isOpen) {
      // 清空 GlobalKey 映射：切换分类/频道列表刷新后，
      // 旧索引的 key 可能已失效，需重建
      _channelKeys.clear();
      _categoryKeys.clear();
      final controller = context.read<PlayerController>();
      final cur = controller.currentChannel;
      if (cur != null) {
        var catIndex = 0;
        for (final cat in controller.categories) {
          if (cat.channels.any((ch) => ch.id == cur.id)) {
            if (_selectedCategory != cat) {
              setState(() => _selectedCategory = cat);
            }
            _kbCategoryIndex = catIndex;
            _kbChannelIndex = cat.channels
                .indexWhere((ch) => ch.id == cur.id)
                .clamp(0, cat.channels.length - 1);
            break;
          }
          catIndex++;
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrentChannel();
      });
    }
  }

  /// 遥控器/键盘按键入口（由 PlayerScreen 统一分发，Windows 低级钩子
  /// 与 HardwareKeyboard 走同一入口）。
  /// action: up/down/left/right/ok/back；back 与 ok 在按下边沿触发。
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!widget.isOpen || !mounted) return;
    if (action == 'back') {
      if (isDown) widget.onClose();
      return;
    }
    // 其余动作只在按下边沿处理一次（长按重复由系统 repeat 过滤在上游）
    if (!isDown) return;
    final controller = context.read<PlayerController>();
    final cats = controller.categories;
    final cat = _selectedCategory;
    if (cat == null) {
      // ===== 第一级：分类列表 =====
      if (cats.isEmpty) return;
      switch (action) {
        case 'up':
          setState(() => _kbCategoryIndex =
              (_kbCategoryIndex - 1).clamp(0, cats.length - 1));
          _scrollKeyboardTo(_categoryKeys, _kbCategoryIndex);
        case 'down':
          setState(() => _kbCategoryIndex =
              (_kbCategoryIndex + 1).clamp(0, cats.length - 1));
          _scrollKeyboardTo(_categoryKeys, _kbCategoryIndex);
        case 'ok':
        case 'right':
          final next = cats[_kbCategoryIndex];
          setState(() {
            _selectedCategory = next;
            final curId = controller.currentChannel?.id;
            final idx = next.channels.indexWhere((ch) => ch.id == curId);
            // 进入分类时默认选中当前播放频道，没有则选第一条
            _kbChannelIndex =
                idx >= 0 ? idx.clamp(0, next.channels.length - 1) : 0;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToCurrentChannel();
            _scrollKeyboardTo(_channelKeys, _kbChannelIndex);
          });
      }
    } else {
      // ===== 第二级：频道列表 =====
      final channels = cat.channels;
      switch (action) {
        case 'up':
          if (channels.isEmpty) break;
          setState(() => _kbChannelIndex =
              (_kbChannelIndex - 1).clamp(0, channels.length - 1));
          _scrollKeyboardTo(_channelKeys, _kbChannelIndex);
        case 'down':
          if (channels.isEmpty) break;
          setState(() => _kbChannelIndex =
              (_kbChannelIndex + 1).clamp(0, channels.length - 1));
          _scrollKeyboardTo(_channelKeys, _kbChannelIndex);
        case 'left':
          setState(() => _selectedCategory = null);
        case 'ok':
          if (channels.isEmpty) break;
          // 播放内核重建期间防抖：连按 OK 只执行一次，避免频道乱跳
          if (_lastPlayAt != null &&
              DateTime.now().difference(_lastPlayAt!) <
                  const Duration(milliseconds: 800)) {
            break;
          }
          // 索引边界检查：EPG/频道列表刷新可能导致数组长度变化
          final idx = _kbChannelIndex.clamp(0, channels.length - 1);
          _lastPlayAt = DateTime.now();
          final channel = channels[idx];
          controller.playChannel(channel);
          widget.onChannelTap?.call();
          widget.onClose();
      }
    }
  }

  /// 滚动列表让键盘选中项可见。
  /// ListView 懒加载：目标条目在视口外很远时 GlobalKey 还没有
  /// currentContext，ensureVisible 会静默失败；此时先用估算高度粗跳
  /// 到目标附近让条目构建，下一帧再精准居中。
  void _ensureVisibleIndex(ScrollController sc, Map<int, GlobalKey> keys,
      int index, Duration duration) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !sc.hasClients) return;
      final ctx = keys[index]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: duration,
          curve: Curves.easeOut,
          alignment: 0.5,
        );
        return;
      }
      // 目标尚未构建：粗跳到目标附近（频道条目约 64px）
      final pos = sc.position;
      const estItemHeight = 64.0;
      final rough = (index * estItemHeight - pos.viewportDimension / 2)
          .clamp(0.0, pos.maxScrollExtent);
      pos.jumpTo(rough);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !sc.hasClients) return;
        final c2 = keys[index]?.currentContext;
        if (c2 != null) {
          Scrollable.ensureVisible(
            c2,
            duration: duration,
            curve: Curves.easeOut,
            alignment: 0.5,
          );
        }
      });
    });
  }

  /// 滚动列表让键盘选中项保持在可视区
  void _scrollKeyboardTo(Map<int, GlobalKey> keys, int index) {
    _ensureVisibleIndex(
        _scrollOf(keys), keys, index, const Duration(milliseconds: 200));
  }

  ScrollController _scrollOf(Map<int, GlobalKey> keys) =>
      identical(keys, _categoryKeys) ? _categoryScroll : _channelScroll;

  /// 滚动频道列表到当前播放频道
  void _scrollToCurrentChannel() {
    if (!mounted) return;
    final controller = context.read<PlayerController>();
    final cat = _selectedCategory;
    if (cat == null) return;
    final idx = cat.channels
        .indexWhere((ch) => ch.id == controller.currentChannel?.id);
    if (idx < 0) return;
    // 注意：打开瞬间 _channelScroll 还没有 clients，
    // 不能在这里同步判断 hasClients，交给 postFrame
    _ensureVisibleIndex(_channelScroll, _channelKeys, idx,
        const Duration(milliseconds: 300));
  }

  /// 频道全局序号（跨分类累加，1 起），与数字选台/OSD 序号一致
  int _globalIndexOf(PlayerController controller, ChannelCategory cat,
      int indexInCat) {
    var offset = 0;
    for (final c in controller.categories) {
      if (c == cat) return offset + indexInCat + 1;
      offset += c.channels.length;
    }
    return indexInCat + 1;
  }

  @override
  Widget build(BuildContext context) {
    final scale = panelScaleOf(context);
    final drawerW = _designWidth * scale;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      left: widget.isOpen ? 0 : -drawerW,
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
            alignment: Alignment.centerLeft,
            scale: scale,
            child: Material(
              color: Colors.black87,
              elevation: 16,
              child: SafeArea(
                child: Column(
                  children: [
                    _buildHeader(),
                    Expanded(child: _buildBody()),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.live_tv, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _selectedCategory == null ? '频道列表' : _selectedCategory!.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_selectedCategory != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white70),
              onPressed: () => setState(() => _selectedCategory = null),
            ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    // 顶层监听控制器：切换节目源（分类列表整体替换）后立即刷新
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final cats = controller.categories;
        // 当前选中的分类对象已不在新列表中（说明刚切换了节目源），
        // 自动回到第一级分类列表
        if (_selectedCategory != null &&
            !cats.contains(_selectedCategory)) {
          _selectedCategory = null;
          // 本帧先按第一级渲染，下一帧刷新标题栏（标题栏在 Consumer 外）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        if (_selectedCategory == null) {
          return _buildCategoryList(cats);
        }
        return _buildChannelList(_selectedCategory!, controller);
      },
    );
  }

  /// 第一级：分类列表
  Widget _buildCategoryList(List<ChannelCategory> cats) {
    if (cats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.playlist_add, size: 56, color: Colors.white38),
              const SizedBox(height: 16),
              const Text(
                '暂无频道列表',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                '请在设置中添加 M3U/TXT 播放列表',
                style: TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings, size: 18),
                label: const Text('去设置添加'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _categoryScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: cats.length,
      itemBuilder: (context, index) {
        final cat = cats[index];
        final key = _categoryKeys.putIfAbsent(index, GlobalKey.new);
        return _CategoryTile(
          key: key,
          category: cat,
          keyboardSelected: index == _kbCategoryIndex,
          onTap: () => setState(() {
            _selectedCategory = cat;
            _kbCategoryIndex = index;
            _kbChannelIndex = 0;
          }),
        );
      },
    );
  }

  /// 第二级：频道列表
  Widget _buildChannelList(
      ChannelCategory category, PlayerController controller) {
    return ListView.builder(
      controller: _channelScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: category.channels.length,
      itemBuilder: (context, index) {
        final channel = category.channels[index];
        final isCurrent = controller.currentChannel?.id == channel.id;
        final number = _globalIndexOf(controller, category, index);
        final key = _channelKeys.putIfAbsent(index, GlobalKey.new);
        return _ChannelTile(
          key: key,
          channel: channel,
          number: number,
          isSelected: isCurrent,
          keyboardSelected: index == _kbChannelIndex,
          onTap: () {
            _kbChannelIndex = index;
            controller.playChannel(channel);
            widget.onChannelTap?.call();
            widget.onClose();
          },
        );
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final ChannelCategory category;
  final VoidCallback onTap;

  /// 遥控器/键盘焦点高亮（区别于鼠标）
  final bool keyboardSelected;

  const _CategoryTile({
    super.key,
    required this.category,
    required this.onTap,
    this.keyboardSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: keyboardSelected
              ? Colors.white.withOpacity(0.10)
              : Colors.transparent,
          border: keyboardSelected
              ? Border.all(color: Colors.white70, width: 1.2)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.category,
                  color: Colors.blueAccent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${category.channels.length} 个频道',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: keyboardSelected ? Colors.white : Colors.white38,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final int number;
  final bool isSelected;
  final VoidCallback onTap;

  /// 遥控器/键盘焦点高亮
  final bool keyboardSelected;

  const _ChannelTile({
    super.key,
    required this.channel,
    required this.number,
    required this.isSelected,
    required this.onTap,
    this.keyboardSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent.withOpacity(0.2)
              : (keyboardSelected
                  ? Colors.white.withOpacity(0.08)
                  : Colors.transparent),
          border: Border.all(
            color: keyboardSelected
                ? Colors.white70
                : (isSelected ? Colors.blueAccent : Colors.transparent),
            width: keyboardSelected ? 1.2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            // 频道序号（与数字选台）。强制单行等比缩小，避免折行
            SizedBox(
              width: 42,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  number.toString().padLeft(2, '0'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: isSelected ? Colors.blueAccent : Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isSelected ? Colors.blueAccent : Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.tv,
                color: isSelected ? Colors.white : Colors.white70,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                channel.name,
                style: TextStyle(
                  color: isSelected ? Colors.blueAccent : Colors.white,
                  fontSize: 14,
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            if (channel.isFavorite)
              const Icon(Icons.star, color: Colors.amber, size: 16),
            if (isSelected)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child:
                    Icon(Icons.play_arrow, color: Colors.blueAccent, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}
