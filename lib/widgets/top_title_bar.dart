import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/player_controller.dart';
import '../services/window_drag.dart';

/// 顶部悬停标题栏：平时隐藏，鼠标移到顶部出现。
/// 提供 最小化 / 最大化还原 / 关闭 按钮，可拖动窗口，双击切换最大化。
/// 配合主窗口 TitleBarStyle.hidden 使用（桌面端）。
class TopTitleBar extends StatelessWidget {
  final bool visible;
  final VoidCallback onHide;

  const TopTitleBar({
    super.key,
    required this.visible,
    required this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: MouseRegion(
          onExit: (_) => onHide(),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: visible ? 1.0 : 0.0,
            child: Container(
              height: 44,
              color: Colors.black.withOpacity(0.72),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => startWindowDrag(),
                onDoubleTap: () async {
                  // 全屏状态下双击标题栏先退出全屏（同步控制器状态）
                  if (context.mounted &&
                      await context.read<PlayerController>().exitFullscreenIfNeeded()) {
                    return;
                  }
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    const Icon(Icons.live_tv,
                        color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'OMPlayer',
                      style: TextStyle(
                          color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    _winButton(Icons.minimize, '最小化',
                        () => windowManager.minimize()),
                    _winButton(Icons.crop_square, '最大化/还原',
                        () async {
                      // 全屏状态下先退出全屏（同步控制器状态），否则在
                      // 系统全屏层上做 maximize 视觉无变化，像按钮坏了
                      if (await context
                          .read<PlayerController>()
                          .exitFullscreenIfNeeded()) {
                        return;
                      }
                      if (await windowManager.isMaximized()) {
                        await windowManager.unmaximize();
                      } else {
                        await windowManager.maximize();
                      }
                    }),
                    _winButton(Icons.close, '关闭',
                        () => windowManager.close(),
                        hoverColor: Colors.red),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _winButton(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    Color hoverColor = Colors.white12,
  }) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: HoverContainer(hoverColor: hoverColor, icon: icon),
        ),
      ),
    );
  }
}

class HoverContainer extends StatefulWidget {
  final Color hoverColor;
  final IconData icon;

  const HoverContainer({
    super.key,
    required this.hoverColor,
    required this.icon,
  });

  @override
  State<HoverContainer> createState() => _HoverContainerState();
}

class _HoverContainerState extends State<HoverContainer> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        width: 46,
        height: 44,
        color: _hover ? widget.hoverColor : Colors.transparent,
        alignment: Alignment.center,
        child: Icon(widget.icon,
            color: _hover ? Colors.white : Colors.white70, size: 20),
      ),
    );
  }
}
