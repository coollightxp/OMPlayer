import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/player_controller.dart';
import '../services/window_drag.dart';
import '../widgets/bottom_program_panel.dart';
import '../widgets/gesture_indicator_overlay.dart';
import '../widgets/left_channel_drawer.dart';
import '../widgets/right_epg_panel.dart';
import '../widgets/settings_panel.dart';
import '../widgets/top_title_bar.dart';
import '../widgets/video_player_widget.dart';

/// 主播放器界面
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
  static const double _edgeWidth = 30;
  static const double _dragSensitivity = 0.005;

  // 底部面板自动隐藏定时器
  Timer? _bottomHideTimer;

  // 控制器监听
  PlayerController? _controllerRef;
  PlayerState _prevState = PlayerState.idle;
  String? _prevChannelId;

  // 鼠标自动隐藏（播放中 3 秒无动作）
  Timer? _cursorHideTimer;
  bool _cursorHidden = false;

  // 侧边抽屉自动隐藏
  Timer? _drawerHideTimer;
  static const _drawerAutoHide = Duration(seconds: 4);

  // 切台 OSD
  Timer? _osdTimer;
  bool _osdVisible = false;

  // 数字选台输入缓存
  String _numBuffer = '';
  Timer? _numTimer;

  // 底部面板 hover 状态（悬停时不自动隐藏）
  bool _bottomHovering = false;

  // 顶部悬停标题栏
  bool _topBarVisible = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<PlayerController>();
    if (_controllerRef != c) {
      _controllerRef?.removeListener(_onControllerChanged);
      _controllerRef = c..addListener(_onControllerChanged);
      // 首帧布局完成后，按「启动全屏」设置决定是否进入全屏（只执行一次）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) c.applyStartupFullscreen();
      });
    }
  }

  void _onControllerChanged() {
    final c = _controllerRef;
    if (c == null || !mounted) return;
    final becamePlaying =
        c.state == PlayerState.playing && _prevState != PlayerState.playing;
    _prevState = c.state;

    // 切台：显示左上角台名/节目名 OSD
    final cid = c.currentChannel?.id;
    if (cid != null && cid != _prevChannelId) {
      _showChannelOsd();
    }
    _prevChannelId = cid;

    if (becamePlaying && c.currentChannel != null) {
      setState(() {
        _bottomPanelVisible = true;
        _bottomHovering = false;
      });
      _scheduleBottomHide();
      _pokeCursor();
    }
  }

  /// 切台提示：大字台名 + 小字当前节目，8 秒后消失
  void _showChannelOsd() {
    _osdTimer?.cancel();
    setState(() => _osdVisible = true);
    _osdTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _osdVisible = false);
    });
  }

  /// 数字键选台：追加到缓存，1.5 秒后跳转
  void _onNumberKey(int n) {
    // 设置面板打开时不拦截数字键（避免影响输入框）
    if (_settingsOpen) return;
    setState(() {
      _numBuffer += n.toString();
      _osdVisible = true;
    });
    _numTimer?.cancel();
    _numTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _numBuffer.isNotEmpty) {
        final number = int.tryParse(_numBuffer);
        if (number != null) {
          context.read<PlayerController>().playChannelByNumber(number);
        }
        setState(() => _numBuffer = '');
      }
    });
  }

  // 数字键（主键盘 + 小键盘）
  static const List<LogicalKeyboardKey> _digitKeys = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  static const List<LogicalKeyboardKey> _numpadKeys = [
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];

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

  /// 抽屉打开后 4 秒无操作自动隐藏
  void _bumpDrawers() {
    if (!_leftDrawerOpen && !_rightEpgOpen) return;
    _drawerHideTimer?.cancel();
    _drawerHideTimer = Timer(_drawerAutoHide, () {
      if (mounted) setState(() {
        _leftDrawerOpen = false;
        _rightEpgOpen = false;
      });
    });
  }

  @override
  void dispose() {
    _cursorHideTimer?.cancel();
    _drawerHideTimer?.cancel();
    _osdTimer?.cancel();
    _numTimer?.cancel();
    _controllerRef?.removeListener(_onControllerChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          context.read<PlayerController>().exitFullscreenIfNeeded();
        },
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _onShortcut('playpause'),
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            _onShortcut('fullscreen'),
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            _onShortcut('fullscreen'),
        const SingleActivator(LogicalKeyboardKey.keyM): () =>
            _onShortcut('mute'),
        const SingleActivator(LogicalKeyboardKey.printScreen): () =>
            _onShortcut('screenshot'),
        const SingleActivator(LogicalKeyboardKey.keyC): () =>
            _onShortcut('channels'),
        const SingleActivator(LogicalKeyboardKey.keyE): () =>
            _onShortcut('epg'),
        const SingleActivator(LogicalKeyboardKey.keyS): () =>
            _onShortcut('settings'),
        const SingleActivator(LogicalKeyboardKey.keyR): () =>
            _onShortcut('record'),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _onArrow('prevSource'),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _onArrow('nextSource'),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _onArrow('prevChannel'),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _onArrow('nextChannel'),
        for (var i = 0; i < 10; i++)
          SingleActivator(_digitKeys[i]): () => _onNumberKey(i),
        for (var i = 0; i < 10; i++)
          SingleActivator(_numpadKeys[i]): () => _onNumberKey(i),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        cursor: _cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: (event) {
          _pokeCursor();
          _bumpDrawers();
          // 鼠标靠近屏幕顶部时呼出悬停标题栏
          final nearTop = event.position.dy < 40;
          if (nearTop != _topBarVisible) {
            setState(() => _topBarVisible = nearTop);
          }
        },
        child: Listener(
          // 任何鼠标/触摸活动都重置抽屉隐藏计时并显示鼠标
          onPointerDown: (_) {
            _pokeCursor();
            _bumpDrawers();
          },
          onPointerMove: (_) {
            _pokeCursor();
            _bumpDrawers();
          },
          child: Consumer<PlayerController>(
            builder: (context, controller, _) {
              final panelVisible =
                  _bottomPanelVisible ||
                      controller.state != PlayerState.playing;
              return Stack(
                children: [
                  // 视频播放层
                  const Positioned.fill(child: VideoPlayerWidget()),

                  // 桌面端亮度调节：屏幕前叠加黑色遮罩（screen_brightness 在多数桌面机无效）
                  if (controller.isDesktop)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: Colors.black.withOpacity(
                              (1.0 - controller.brightness) * 0.9),
                        ),
                      ),
                    ),

                  // 手势检测层
                  _buildGestureLayer(controller),

                  // 左右边缘点击区（移动端；桌面端用 hover 自动弹出）
                  if (!controller.isDesktop) _buildEdgeTapZones(),

                  // 桌面端 hover 边缘自动弹出
                  if (controller.isDesktop) ...[
                    // 左边缘
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: MouseRegion(
                        onEnter: (_) => _openDrawer(left: true),
                        onExit: (_) => _startDrawerHideTimer(),
                      ),
                    ),
                    // 右边缘
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: MouseRegion(
                        onEnter: (_) => _openDrawer(left: false),
                        onExit: (_) => _startDrawerHideTimer(),
                      ),
                    ),
                    // 底部边缘
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 20,
                      child: MouseRegion(
                        onEnter: (_) => _showBottomPanel(),
                        onExit: (_) => _scheduleBottomHide(),
                      ),
                    ),
                  ],

                  // 底部信息/控制面板（hover 回调由面板内部 MouseRegion 处理，
                  // 不能在外面用 MouseRegion 包裹：根是 AnimatedPositioned 的
                  // 组件被其它 RenderObjectWidget 包裹会破坏 Stack parentData，
                  // release 下直接灰屏）
                  BottomProgramPanel(
                    isVisible: panelVisible,
                    onHoverEnter: _cancelBottomHide,
                    onHoverExit: _scheduleBottomHide,
                    onTogglePlayPause: controller.togglePlayPause,
                    onOpenChannels: () => _openDrawer(left: true),
                    onOpenEpg: () => _openDrawer(left: false),
                    onOpenSettings: _toggleSettings,
                    onScreenshot: _takeScreenshot,
                    onToggleRecord: () => _toggleRecording(controller),
                  ),

                  // 左侧频道抽屉
                  LeftChannelDrawer(
                    isOpen: _leftDrawerOpen,
                    onClose: () => setState(() => _leftDrawerOpen = false),
                    onHoverEnter: () => _drawerHideTimer?.cancel(),
                    onHoverExit: _startDrawerHideTimer,
                  ),

                  // 右侧 EPG 面板
                  RightEpgPanel(
                    isOpen: _rightEpgOpen,
                    onClose: () => setState(() => _rightEpgOpen = false),
                    onHoverEnter: () => _drawerHideTimer?.cancel(),
                    onHoverExit: _startDrawerHideTimer,
                  ),

                  // 切台 OSD（左上角大字台名 + 小字节目名）
                  _buildChannelOsd(controller),

                  // 右上角常驻系统时间
                  if (controller.settings.showClock) _buildClock(),

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

                  // 顶部悬停标题栏（桌面端，置于最顶层，
                  // 避免被右上角时钟/切台 OSD 遮挡导致点不到）
                  // 频道抽屉 / EPG / 设置打开时不显示，以免挡住它们
                  // 顶部的关闭、返回按钮
                  if (controller.isDesktop &&
                      !_leftDrawerOpen &&
                      !_rightEpgOpen &&
                      !_settingsOpen)
                    TopTitleBar(
                      visible: _topBarVisible,
                      onHide: () {
                        if (_topBarVisible) {
                          setState(() => _topBarVisible = false);
                        }
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
        ),
      ),
    );
  }

  // ==================== 边缘点击区 ====================

  Widget _buildEdgeTapZones() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _openDrawer(left: true),
              child: Container(
                width: _edgeWidth.toDouble(),
                alignment: Alignment.centerLeft,
                child: const SizedBox.expand(),
              ),
            ),
            const Spacer(),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _openDrawer(left: false),
              child: Container(
                width: _edgeWidth.toDouble(),
                alignment: Alignment.centerRight,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDrawer({required bool left}) {
    setState(() {
      // 打开面板时隐藏悬停标题栏，避免遮挡面板顶部按钮
      _topBarVisible = false;
      if (left) {
        _leftDrawerOpen = true;
        _rightEpgOpen = false;
      } else {
        _rightEpgOpen = true;
        _leftDrawerOpen = false;
      }
    });
    _bumpDrawers();
  }

  /// 快捷键用：再次按键时关闭对应面板
  void _toggleDrawer({required bool left}) {
    setState(() {
      _topBarVisible = false;
      if (left) {
        if (_leftDrawerOpen) {
          _leftDrawerOpen = false;
        } else {
          _leftDrawerOpen = true;
          _rightEpgOpen = false;
        }
      } else {
        if (_rightEpgOpen) {
          _rightEpgOpen = false;
        } else {
          _rightEpgOpen = true;
          _leftDrawerOpen = false;
        }
      }
    });
    _bumpDrawers();
  }

  // ==================== 切台 OSD / 时钟 ====================

  Widget _buildChannelOsd(PlayerController controller) {
    final ch = controller.currentChannel;
    final program = controller.currentProgram?.title;
    final number = controller.currentChannelNumber;
    final showOsd = (_osdVisible && ch != null) || _numBuffer.isNotEmpty;
    return Positioned(
      top: 0,
      left: 0,
      child: AnimatedOpacity(
        opacity: showOsd ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: const Color(0xCC1A1A2E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 第一行：大号数字 + 频道名
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        number != null ? number.toString().padLeft(2, '0') : '--',
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        ch?.name ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  // 第二行：正在直播 + 当前节目
                  if (program != null && program.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '正在直播 · $program',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  // 数字选台输入提示
                  if (_numBuffer.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '输入: $_numBuffer',
                        style: const TextStyle(
                          color: Colors.blueAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClock() {
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: StreamBuilder<int>(
            stream: _clockStream,
            builder: (context, _) {
              final now = DateTime.now();
              return Text(
                DateFormat('HH:mm').format(now),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static final Stream<int> _clockStream =
      Stream.periodic(const Duration(seconds: 1), (i) => i);

  // ==================== 手势层 ====================

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
                onHorizontalDragEnd: (details) {
                  if (_dragStartX != null &&
                      _dragStartX! <= _edgeWidth &&
                      details.velocity.pixelsPerSecond.dx > 100) {
                    _openDrawer(left: true);
                  }
                },
              ),
            ),
            // 中间：点击切换面板，双击播放暂停（桌面端双击全屏，按住拖动窗口）
            Expanded(
              child: GestureDetector(
                onTap: _toggleBottomPanel,
                onDoubleTap: controller.isDesktop
                    ? controller.toggleFullscreen
                    : controller.togglePlayPause,
                // 全屏状态下绝不能拖动窗口，否则窗口会掉到最底层、点击穿透
                onPanStart: (controller.isDesktop && !controller.isFullscreen)
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
                    _openDrawer(left: false);
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _onBrightnessDragEnd() {
    _dragStartY = null;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showBrightnessIndicator = false);
    });
  }

  void _onVolumeDragEnd() {
    _dragStartY = null;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
  }

  // ==================== 面板控制 ====================

  void _toggleBottomPanel() {
    final c = context.read<PlayerController>();
    // 未播放时面板常驻，不响应点击隐藏
    if (c.state != PlayerState.playing) return;
    setState(() {
      _bottomPanelVisible = !_bottomPanelVisible;
      if (_bottomPanelVisible) {
        _scheduleBottomHide();
      }
    });
  }

  void _toggleSettings() {
    setState(() {
      _settingsOpen = !_settingsOpen;
      // 打开设置时隐藏悬停标题栏
      if (_settingsOpen) _topBarVisible = false;
    });
  }

  /// 桌面端快捷键：空格 播放/暂停，F/F11 全屏，M 静音，
  /// PrintScreen 截屏，C 频道列表开/关，E 节目单开/关，S 设置，R 录制
  void _onShortcut(String action) {
    if (_settingsOpen && action != 'settings') return;
    final controller = context.read<PlayerController>();
    switch (action) {
      case 'channels':
        _toggleDrawer(left: true);
      case 'epg':
        _toggleDrawer(left: false);
      case 'settings':
        _toggleSettings();
      case 'record':
        _toggleRecording(controller);
      case 'playpause':
        controller.togglePlayPause();
      case 'fullscreen':
        controller.toggleFullscreen();
      case 'mute':
        controller.toggleMute();
      case 'screenshot':
        _takeScreenshot();
    }
  }

  /// 方向键：←/→ 切换播放源，↑/↓ 切换频道
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

  Future<void> _takeScreenshot() async {
    final controller = context.read<PlayerController>();
    final path = await controller.takeScreenshot();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(path != null ? '截图已保存: $path' : '截图失败'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

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
            content: Text(ok
                ? '开始录制，视频保存到程序所在文件夹的 recordings 子文件夹'
                : '录制失败'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 底部面板 hover 取消隐藏
  void _cancelBottomHide() {
    setState(() => _bottomHovering = true);
  }

  /// 底部面板 hover 离开后启动隐藏计时
  void _scheduleBottomHide() {
    setState(() => _bottomHovering = false);
    _bottomHideTimer?.cancel();
    final delay =
        context.read<PlayerController>().settings.autoHideDelay;
    _bottomHideTimer = Timer(Duration(milliseconds: delay), () {
      if (mounted && !_bottomHovering) {
        setState(() => _bottomPanelVisible = false);
      }
    });
  }

  /// 桌面端 hover 到底部边缘时显示面板
  void _showBottomPanel() {
    setState(() => _bottomPanelVisible = true);
    _bottomHideTimer?.cancel();
  }

  /// 抽屉 hover 移出后 4 秒自动隐藏
  void _startDrawerHideTimer() {
    _drawerHideTimer?.cancel();
    _drawerHideTimer = Timer(_drawerAutoHide, () {
      if (mounted) {
        setState(() {
          _leftDrawerOpen = false;
          _rightEpgOpen = false;
        });
      }
    });
  }
}
