import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/player_controller.dart';
import '../services/window_drag.dart';
import '../widgets/bottom_program_panel.dart';
import '../widgets/gesture_indicator_overlay.dart';
import '../widgets/left_channel_drawer.dart';
import '../widgets/right_epg_panel.dart';
import '../widgets/settings_panel.dart';
import '../widgets/video_player_widget.dart';

/// 主播放器界面
/// 布局：
/// - 中间：视频播放区域
/// - 左侧：上下滑动调节亮度
/// - 右侧：上下滑动调节音量
/// - 左边缘右滑：打开频道抽屉
/// - 右边缘左滑：打开 EPG 面板
/// - 点击中间：显示/隐藏底部控制栏
/// - 双击中间：移动端播放/暂停，桌面端切换全屏
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // 面板显隐状态
  bool _leftDrawerOpen = false;
  bool _rightEpgOpen = false;
  bool _bottomPanelVisible = false;
  bool _settingsOpen = false;

  // 手势调节状态
  bool _showBrightnessIndicator = false;
  bool _showVolumeIndicator = false;

  // 手势检测
  double? _dragStartY;
  double? _dragStartX;
  double _lastBrightness = 0.8;
  double _lastVolume = 0.8;
  bool _isHorizontalDrag = false;
  static const double _edgeWidth = 30; // 边缘触发宽度
  static const double _dragSensitivity = 0.005; // 滑动灵敏度

  // 自动隐藏定时器
  DateTime? _lastInteraction;

  // 控制器监听（用于播放开始时自动弹出底部面板）
  PlayerController? _controllerRef;
  PlayerState _prevState = PlayerState.idle;

  // 鼠标自动隐藏（播放中 3 秒无动作隐藏）
  Timer? _cursorHideTimer;
  bool _cursorHidden = false;

  @override
  void initState() {
    super.initState();
    // 全屏沉浸模式
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<PlayerController>();
    if (_controllerRef != c) {
      _controllerRef?.removeListener(_onControllerChanged);
      _controllerRef = c..addListener(_onControllerChanged);
    }
  }

  /// 频道开始播放时自动显示底部节目信息面板（随后按设置自动隐藏）
  void _onControllerChanged() {
    final c = _controllerRef;
    if (c == null || !mounted) return;
    final becamePlaying =
        c.state == PlayerState.playing && _prevState != PlayerState.playing;
    _prevState = c.state;
    if (becamePlaying && c.currentChannel != null) {
      setState(() {
        _bottomPanelVisible = true;
        _lastInteraction = DateTime.now();
      });
      _scheduleAutoHide();
      _pokeCursor();
    }
  }

  /// 鼠标活动：恢复显示并重置 3 秒隐藏计时（仅播放中计时）
  void _pokeCursor() {
    if (!mounted) return;
    if (_cursorHidden) setState(() => _cursorHidden = false);
    _cursorHideTimer?.cancel();
    final controller = context.read<PlayerController>();
    if (!controller.isPlaying) return;
    _cursorHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted &&
          controller.isPlaying &&
          !_settingsOpen &&
          !_leftDrawerOpen &&
          !_rightEpgOpen) {
        setState(() => _cursorHidden = true);
      }
    });
  }

  @override
  void dispose() {
    _cursorHideTimer?.cancel();
    _controllerRef?.removeListener(_onControllerChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(bindings: {
        // 桌面端全屏时按 ESC 退出全屏
        const SingleActivator(LogicalKeyboardKey.escape): () {
          context.read<PlayerController>().exitFullscreenIfNeeded();
        },
        // C 频道列表 / E 节目单 / S 设置 / R 录制
        const SingleActivator(LogicalKeyboardKey.keyC): () =>
            _onShortcut('channels'),
        const SingleActivator(LogicalKeyboardKey.keyE): () =>
            _onShortcut('epg'),
        const SingleActivator(LogicalKeyboardKey.keyS): () =>
            _onShortcut('settings'),
        const SingleActivator(LogicalKeyboardKey.keyR): () =>
            _onShortcut('record'),
        // ←/→ 切换播放源，↑/↓ 切换频道
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _onArrow('prevSource'),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _onArrow('nextSource'),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _onArrow('prevChannel'),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _onArrow('nextChannel'),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: Colors.black,
  body: MouseRegion(
    // 播放中 3 秒无动作隐藏鼠标
    cursor: _cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
    onHover: (_) => _pokeCursor(),
    child: Consumer<PlayerController>(
        builder: (context, controller, _) {
          return Stack(
            children: [
              // 视频播放层
              const Positioned.fill(child: VideoPlayerWidget()),

              // 手势检测层
              _buildGestureLayer(controller),

              // 底部面板
              BottomProgramPanel(
                isVisible: _bottomPanelVisible,
                onTogglePlayPause: controller.togglePlayPause,
              ),

              // 顶部栏：未播放时常驻（保证设置入口可达），播放时随底部面板一起显隐
              // 注意：必须放在抽屉/面板之前，否则会盖住它们的头部按钮
              if (_bottomPanelVisible ||
                  controller.state != PlayerState.playing)
                _buildTopBar(),

              // 左侧频道抽屉
              LeftChannelDrawer(
                isOpen: _leftDrawerOpen,
                onClose: () => setState(() => _leftDrawerOpen = false),
              ),

              // 右侧 EPG 面板
              RightEpgPanel(
                isOpen: _rightEpgOpen,
                onClose: () => setState(() => _rightEpgOpen = false),
              ),

              // 设置面板
              SettingsPanel(
                isOpen: _settingsOpen,
                onClose: () => setState(() => _settingsOpen = false),
              ),

              // 亮度调节指示
              GestureIndicatorOverlay(
                isVisible: _showBrightnessIndicator,
                icon: Icons.brightness_6,
                iconColor: Colors.amber,
                value: controller.brightness,
                label: '亮度 ${(controller.brightness * 100).round()}%',
              ),

              // 音量调节指示
              GestureIndicatorOverlay(
                isVisible: _showVolumeIndicator,
                icon: controller.volume == 0
                    ? Icons.volume_off
                    : (controller.volume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up),
                iconColor: Colors.blueAccent,
                value: controller.volume,
                label: '音量 ${(controller.volume * 100).round()}%',
              ),

              // 边缘打开抽屉的提示条
              if (!_leftDrawerOpen && !_rightEpgOpen)
                _buildEdgeHints(),
            ],
          );
        },
      ),
    ),
        ),
      ),
    );
  }

  /// 手势检测层
  /// 屏幕分为左、中、右三部分：
  /// - 左三分之一：上下滑动调亮度；从左边缘向右滑打开频道抽屉
  /// - 中三分之一：点击显示/隐藏底部栏，双击播放暂停
  /// - 右三分之一：上下滑动调音量；从右边缘向左滑打开 EPG
  Widget _buildGestureLayer(PlayerController controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Row(
          children: [
            // 左侧：亮度调节 + 左边缘滑出抽屉
            Expanded(
              child: GestureDetector(
                onVerticalDragStart: (details) {
                  _isHorizontalDrag = false;
                  _dragStartY = details.globalPosition.dy;
                  _dragStartX = details.globalPosition.dx;
                  _lastBrightness = controller.brightness;
                  setState(() => _showBrightnessIndicator = true);
                },
                onVerticalDragUpdate: (details) {
                  if (_isHorizontalDrag || _dragStartY == null) return;
                  final dy = _dragStartY! - details.globalPosition.dy;
                  controller.setBrightness(
                      _lastBrightness + dy * _dragSensitivity);
                },
                onVerticalDragEnd: (_) => _onBrightnessDragEnd(),
                onHorizontalDragStart: (details) {
                  _isHorizontalDrag = true;
                  _dragStartX = details.globalPosition.dx;
                },
                onHorizontalDragUpdate: (details) {
                  // 仅从左边缘开始的右滑才打开抽屉
                },
                onHorizontalDragEnd: (details) {
                  if (_dragStartX != null &&
                      _dragStartX! <= _edgeWidth &&
                      details.velocity.pixelsPerSecond.dx > 100) {
                    setState(() => _leftDrawerOpen = true);
                  }
                },
              ),
            ),
            // 中间：点击切换面板显示，双击播放暂停（桌面端双击切换全屏，按住左键拖动窗口）
            Expanded(
              child: GestureDetector(
                onTap: _toggleBottomPanel,
                onDoubleTap: controller.isDesktop
                    ? controller.toggleFullscreen
                    : controller.togglePlayPause,
                // 桌面端：按住左键拖动可移动窗口（快速点击仍是 tap，不受影响）
                onPanStart: controller.isDesktop
                    ? (_) => startWindowDrag()
                    : null,
              ),
            ),
            // 右侧：音量调节 + 右边缘滑出 EPG
            Expanded(
              child: GestureDetector(
                onVerticalDragStart: (details) {
                  _isHorizontalDrag = false;
                  _dragStartY = details.globalPosition.dy;
                  _lastVolume = controller.volume;
                  setState(() => _showVolumeIndicator = true);
                },
                onVerticalDragUpdate: (details) {
                  if (_isHorizontalDrag || _dragStartY == null) return;
                  final dy = _dragStartY! - details.globalPosition.dy;
                  controller.setVolume(_lastVolume + dy * _dragSensitivity);
                },
                onVerticalDragEnd: (_) => _onVolumeDragEnd(),
                onHorizontalDragStart: (details) {
                  _isHorizontalDrag = true;
                  _dragStartX = details.globalPosition.dx;
                },
                onHorizontalDragEnd: (details) {
                  if (_dragStartX != null &&
                      _dragStartX! >= width - _edgeWidth &&
                      details.velocity.pixelsPerSecond.dx < -100) {
                    setState(() => _rightEpgOpen = true);
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // ==================== 亮度手势 ====================

  void _onBrightnessDragEnd() {
    _dragStartY = null;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showBrightnessIndicator = false);
    });
  }

  // ==================== 音量手势 ====================

  void _onVolumeDragEnd() {
    _dragStartY = null;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
  }

  // ==================== 面板控制 ====================

  void _toggleBottomPanel() {
    setState(() {
      _bottomPanelVisible = !_bottomPanelVisible;
      if (_bottomPanelVisible) {
        _lastInteraction = DateTime.now();
        _scheduleAutoHide();
      }
    });
  }

  void _toggleSettings() {
    setState(() => _settingsOpen = !_settingsOpen);
  }

  /// 桌面端快捷键处理
  /// C 频道列表 / E 节目单 / S 设置 / R 录制
  void _onShortcut(String action) {
    // 设置面板打开时可能在输入框打字，除 S 外不响应字母快捷键
    if (_settingsOpen && action != 'settings') return;
    switch (action) {
      case 'channels':
        setState(() {
          _leftDrawerOpen = !_leftDrawerOpen;
          if (_leftDrawerOpen) _rightEpgOpen = false;
        });
      case 'epg':
        setState(() {
          _rightEpgOpen = !_rightEpgOpen;
          if (_rightEpgOpen) _leftDrawerOpen = false;
        });
      case 'settings':
        _toggleSettings();
      case 'record':
        _toggleRecording(context.read<PlayerController>());
    }
  }

  /// 方向键：←/→ 切换播放源，↑/↓ 切换频道
  /// 抽屉或设置打开时不响应，避免与列表滚动、输入框光标移动冲突
  void _onArrow(String action) {
    if (_settingsOpen || _leftDrawerOpen || _rightEpgOpen) return;
    final controller = context.read<PlayerController>();
    switch (action) {
      case 'prevSource':
        controller.prevSource();
      case 'nextSource':
        controller.nextSource();
      case 'prevChannel':
        controller.previousChannel();
      case 'nextChannel':
        controller.nextChannel();
    }
  }

  /// 开始/停止录制（顶栏按钮与 R 快捷键共用）
  Future<void> _toggleRecording(PlayerController controller) async {
    if (!controller.isDesktop) return;
    if (controller.isRecording) {
      final path = await controller.stopRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('录制已停止，保存至: ${path ?? "未知"}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } else {
      final ok = await controller.startRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? '开始录制...' : '录制失败，请确保已安装 ffmpeg'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _scheduleAutoHide() {
    Future.delayed(Duration(
      milliseconds: context.read<PlayerController>().settings.autoHideDelay,
    ), () {
      if (mounted &&
          _lastInteraction != null &&
          DateTime.now().difference(_lastInteraction!).inMilliseconds >=
              context.read<PlayerController>().settings.autoHideDelay) {
        setState(() {
          _bottomPanelVisible = false;
        });
      }
    });
  }

  /// 边缘打开抽屉的提示条
  Widget _buildEdgeHints() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Row(
          children: [
            // 左边缘提示
            Container(
              width: 2,
              color: Colors.white24,
            ),
            const Spacer(),
            // 右边缘提示
            Container(
              width: 2,
              color: Colors.white24,
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部栏（显示当前频道 + 返回）
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.7),
                Colors.transparent,
              ],
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.menu, color: Colors.white),
                onPressed: () =>
                    setState(() => _leftDrawerOpen = true),
                tooltip: '频道列表',
              ),
              const Spacer(),
              Consumer<PlayerController>(
                builder: (context, controller, _) {
                  return Text(
                    controller.currentChannel?.name ?? 'OMPlayer',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  );
                },
              ),
              const Spacer(),
              Consumer<PlayerController>(
                builder: (context, controller, _) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controller.isDesktop) ...[
                        // 截图按钮
                        IconButton(
                          icon: const Icon(Icons.camera_alt,
                              color: Colors.white),
                          onPressed: () async {
                            final path = await controller.takeScreenshot();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(path != null
                                      ? '截图已保存: $path'
                                      : '截图失败'),
                                  duration: const Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                          tooltip: '截图',
                        ),
                        // 录制按钮
                        IconButton(
                          icon: Icon(
                            controller.isRecording
                                ? Icons.stop_circle
                                : Icons.fiber_manual_record,
                            color: controller.isRecording
                                ? Colors.redAccent
                                : Colors.white,
                          ),
                          onPressed: () => _toggleRecording(controller),
                          tooltip: controller.isRecording ? '停止录制' : '录制',
                        ),
                        const SizedBox(width: 8),
                      ],
                      IconButton(
                        icon: const Icon(Icons.menu_book, color: Colors.white),
                        onPressed: () =>
                            setState(() => _rightEpgOpen = true),
                        tooltip: '节目单',
                      ),
                      // 设置按钮（挪到顶栏，未播放时也可打开）
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white),
                        onPressed: _toggleSettings,
                        tooltip: '设置',
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
