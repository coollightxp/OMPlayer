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
  State<LeftChannelDrawer> createState() => _LeftChannelDrawerState();
}

class _LeftChannelDrawerState extends State<LeftChannelDrawer> {
  ChannelCategory? _selectedCategory;
  final ScrollController _categoryScroll = ScrollController();
  final ScrollController _channelScroll = ScrollController();

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
      final controller = context.read<PlayerController>();
      final cur = controller.currentChannel;
      if (cur != null) {
        for (final cat in controller.categories) {
          if (cat.channels.any((ch) => ch.id == cur.id)) {
            if (_selectedCategory != cat) {
              setState(() => _selectedCategory = cat);
            }
            break;
          }
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrentChannel();
      });
    }
  }

  /// 滚动频道列表到当前播放频道
  void _scrollToCurrentChannel() {
    if (!mounted) return;
    final controller = context.read<PlayerController>();
    final cat = _selectedCategory;
    if (cat == null || !_channelScroll.hasClients) return;
    final idx = cat.channels
        .indexWhere((ch) => ch.id == controller.currentChannel?.id);
    if (idx < 0) return;
    // 每条目约 64px（上下 padding 12 + 图标 40）
    const itemHeight = 64.0;
    final target = (idx * itemHeight - 120)
        .clamp(0.0, _channelScroll.position.maxScrollExtent);
    _channelScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
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
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.playlist_add, size: 56, color: Colors.white38),
              SizedBox(height: 16),
              Text(
                '暂无频道列表',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                '请在设置中添加 M3U/TXT 播放列表',
                style: TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 20),
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
        return _CategoryTile(
          category: cat,
          onTap: () => setState(() => _selectedCategory = cat),
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
        return _ChannelTile(
          channel: channel,
          number: number,
          isSelected: isCurrent,
          onTap: () {
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

  const _CategoryTile({required this.category, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            const Icon(Icons.chevron_right, color: Colors.white38),
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

  const _ChannelTile({
    required this.channel,
    required this.number,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.blueAccent.withOpacity(0.2)
              : Colors.transparent,
          border: isSelected
              ? Border.all(color: Colors.blueAccent, width: 1)
              : null,
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
