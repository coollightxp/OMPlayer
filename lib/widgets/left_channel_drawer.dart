import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/player_controller.dart';

/// 左侧两级抽屉式频道面板
/// 第一级：频道分类列表
/// 第二级：选中分类下的频道列表
class LeftChannelDrawer extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  const LeftChannelDrawer({
    super.key,
    required this.isOpen,
    required this.onClose,
  });

  @override
  State<LeftChannelDrawer> createState() => _LeftChannelDrawerState();
}

class _LeftChannelDrawerState extends State<LeftChannelDrawer> {
  ChannelCategory? _selectedCategory;
  final ScrollController _categoryScroll = ScrollController();
  final ScrollController _channelScroll = ScrollController();

  @override
  void dispose() {
    _categoryScroll.dispose();
    _channelScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      left: widget.isOpen ? 0 : -320,
      top: 0,
      bottom: 0,
      width: 320,
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
                Expanded(child: _buildBody()),
              ],
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
    if (_selectedCategory == null) {
      return _buildCategoryList();
    }
    return _buildChannelList(_selectedCategory!);
  }

  /// 第一级：分类列表
  Widget _buildCategoryList() {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final cats = controller.categories;
        if (cats.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.playlist_add,
                      size: 56, color: Colors.white38),
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
      },
    );
  }

  /// 第二级：频道列表
  Widget _buildChannelList(ChannelCategory category) {
    final controller = context.read<PlayerController>();
    return ListView.builder(
      controller: _channelScroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: category.channels.length,
      itemBuilder: (context, index) {
        final channel = category.channels[index];
        final isCurrent = controller.currentChannel?.id == channel.id;
        return _ChannelTile(
          channel: channel,
          isSelected: isCurrent,
          onTap: () {
            controller.playChannel(channel);
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
  final bool isSelected;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isSelected
            ? Colors.blueAccent.withOpacity(0.2)
            : Colors.transparent,
        child: Row(
          children: [
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
