import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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
  static const _drawerAutoHide = Duration(seconds: 3);

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

  // 根焦点：硬件快捷键（含数字选台）都挂在这个节点上。
  // 点击抽屉/面板内按钮后焦点会跑到子节点甚至随面板销毁而丢失，
  // 导致数字键/快捷键失灵，需要在交互后把焦点抢回来。
  final FocusNode _rootFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 全局硬件键盘监听：不依赖 Flutter 焦点，任何控件持有焦点、面板
    // 关闭后都能收到按键；中文输入法状态下硬件 KeyDown 照样送达。
    HardwareKeyboard.instance.addHandler(_onGlobalKeyEvent);
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

  // 物理键（USB HID 码）：与输入法/布局无关，主键盘数字行
  static const List<PhysicalKeyboardKey> _physDigitKeys = [
    PhysicalKeyboardKey.digit0,
    PhysicalKeyboardKey.digit1,
    PhysicalKeyboardKey.digit2,
    PhysicalKeyboardKey.digit3,
    PhysicalKeyboardKey.digit4,
    PhysicalKeyboardKey.digit5,
    PhysicalKeyboardKey.digit6,
    PhysicalKeyboardKey.digit7,
    PhysicalKeyboardKey.digit8,
    PhysicalKeyboardKey.digit9,
  ];

  // 小键盘数字（含安卓遥控器数字键常见映射）
  static const List<PhysicalKeyboardKey> _physNumpadKeys = [
    PhysicalKeyboardKey.numpad0,
    PhysicalKeyboardKey.numpad1,
    PhysicalKeyboardKey.numpad2,
    PhysicalKeyboardKey.numpad3,
    PhysicalKeyboardKey.numpad4,
    PhysicalKeyboardKey.numpad5,
    PhysicalKeyboardKey.numpad6,
    PhysicalKeyboardKey.numpad7,
    PhysicalKeyboardKey.numpad8,
    PhysicalKeyboardKey.numpad9,
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

  /// 鼠标在抽屉内：始终保持显示
  void _cancelDrawerHide() {
    _drawerHideTimer?.cancel();
  }

  /// 抽屉打开（桌面端 3 秒后无悬停自动隐藏；移动端需手动关闭）
  void _armDrawerAutoHide() {
    final desktop = context.read<PlayerController>().isDesktop;
    if (!desktop) return;
    _startDrawerHideTimer();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKeyEvent);
    _cursorHideTimer?.cancel();
    _drawerHideTimer?.cancel();
    _osdTimer?.cancel();
    _numTimer?.cancel();
    _rootFocusNode.dispose();
    _controllerRef?.removeListener(_onControllerChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 把焦点收回根节点，保证硬件快捷键/数字选台随时可响应。
  /// 设置面板打开时不抢焦点（里面有输入框）。
  void _ensureShortcutFocus() {
    if (_settingsOpen) return;
    if (_rootFocusNode.hasPrimaryFocus) return;
    _rootFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
      return Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        child: Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        cursor: _cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
        onHover: (event) {
          _pokeCursor();
          // 鼠标靠近屏幕顶部时呼出悬停标题栏
          final nearTop = event.position.dy < 40;
          if (nearTop != _topBarVisible) {
            setState(() => _topBarVisible = nearTop);
          }
        },
        child: Listener(
          // 任何鼠标/触摸活动都恢复显示鼠标，并把快捷键焦点收回根节点
          onPointerDown: (_) {
            _pokeCursor();
            // 面板可能在静止光标下滑出（无 hover 事件），
            // 用户开始点击时保持面板不自动隐藏
            if (_leftDrawerOpen || _rightEpgOpen) {
              _cancelDrawerHide();
            }
            _ensureShortcutFocus();
          },
          onPointerMove: (_) {
            _pokeCursor();
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

                  // 网页频道：内嵌网页控件充满整个窗口（在视频之上，
                  // OSD/时钟/节目单/EPG/信息面板等浮层之下）。
                  // 网站自身播放器播放，节目信息直接看网页。
                  if (controller.webPageActive &&
                      (controller.currentChannel?.webPageUrl.isNotEmpty ??
                          false))
                    Positioned.fill(
                      child: _WebChannelOverlay(
                        key: ValueKey(controller.currentChannel!.webPageUrl),
                        url: controller.currentChannel!.webPageUrl,
                        title: controller.currentChannel!.name,
                        onExit: () => controller.exitWebPage(),
                      ),
                    ),

                  // 切台 OSD（左上角序号/台名/节目名）
                  // 放在手势层与各面板【之下】：面板滑出时盖住它，
                  // 避免 OSD 卡片挡住频道面板顶部的返回按钮
                  _buildChannelOsd(controller),

                  // 右上角系统时间：在视频画面之上、所有弹出面板之下
                  if (controller.settings.showClock) _buildClock(),

                  // 手势检测层（网页模式下跳过：全屏手势会拦截网页点击，
                  // 面板改由边缘触发区与网页上的关闭/切换按钮控制）
                  if (!controller.webPageActive) _buildGestureLayer(controller),

                  // 左右边缘点击区（移动端；桌面端用 hover 自动弹出）
                  if (!controller.isDesktop) _buildEdgeTapZones(),

                  // 桌面端 hover 边缘自动弹出
                  if (controller.isDesktop) ...[
                    // 左边缘：不在 onExit 里启动隐藏计时——面板滑入会覆盖
                    // 这个 20px 触发区，触发区合成 onExit 与面板 onEnter 的
                    // 回调顺序若为「先入后出」，会把面板刚取消的隐藏定时器
                    // 重新启动，导致光标明明停在面板内、3 秒后仍自动关闭，
                    // 表现为顶部返回/关闭钮点不到。隐藏统一由面板自身
                    // onExit 负责。
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: MouseRegion(
                        onEnter: (_) {
                          if (_leftDrawerOpen) {
                            _cancelDrawerHide();
                          } else {
                            _openDrawer(left: true);
                          }
                        },
                      ),
                    ),
                    // 右边缘
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: MouseRegion(
                        onEnter: (_) {
                          if (_rightEpgOpen) {
                            _cancelDrawerHide();
                          } else {
                            _openDrawer(left: false);
                          }
                        },
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
                    onHoverMove: _cancelBottomHide,
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
                    onClose: () {
                      setState(() => _leftDrawerOpen = false);
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _ensureShortcutFocus());
                    },
                    onHoverEnter: _cancelDrawerHide,
                    onHoverExit: _startDrawerHideTimer,
                    onHoverMove: _cancelDrawerHide,
                  ),

                  // 右侧 EPG 面板
                  RightEpgPanel(
                    isOpen: _rightEpgOpen,
                    onClose: () {
                      setState(() => _rightEpgOpen = false);
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _ensureShortcutFocus());
                    },
                    onHoverEnter: _cancelDrawerHide,
                    onHoverExit: _startDrawerHideTimer,
                    onHoverMove: _cancelDrawerHide,
                  ),

                  // 设置面板
                  SettingsPanel(
                    isOpen: _settingsOpen,
                    onClose: () {
                      setState(() => _settingsOpen = false);
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _ensureShortcutFocus());
                    },
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
      );
  }

  // ==================== 硬件按键快捷键 ====================

  /// 全局硬件按键处理（注册在 HardwareKeyboard 上，不依赖焦点）。
  /// 返回 true 表示事件已消费，不再向焦点链传递。
  bool _onGlobalKeyEvent(KeyEvent event) {
    // 只处理首次按下；长按重复事件是 KeyRepeatEvent，天然被排除
    if (event is! KeyDownEvent) return false;
    // 设置面板里有输入框（URL、数字等）：所有按键放行
    if (_settingsOpen) return false;

    final k = event.logicalKey;
    final p = event.physicalKey;

    // 数字键（主键盘 / 小键盘）选台。
    // 同时按逻辑键与物理键（USB HID 码）匹配：
    // 物理键不受输入法/键盘布局影响，避免中文输入法下逻辑键
    // 映射异常导致数字选台失灵；安卓遥控器数字键也走小键盘码。
    for (var i = 0; i < 10; i++) {
      if (k == _digitKeys[i] ||
          k == _numpadKeys[i] ||
          p == _physDigitKeys[i] ||
          p == _physNumpadKeys[i]) {
        _onNumberKey(i);
        return true;
      }
    }

    if (k == LogicalKeyboardKey.escape) {
      context.read<PlayerController>().exitFullscreenIfNeeded();
      return true;
    }

    String? action;
    if (k == LogicalKeyboardKey.space) {
      action = 'playpause';
    } else if (k == LogicalKeyboardKey.keyF ||
        k == LogicalKeyboardKey.f11) {
      action = 'fullscreen';
    } else if (k == LogicalKeyboardKey.keyM) {
      action = 'mute';
    } else if (k == LogicalKeyboardKey.printScreen) {
      action = 'screenshot';
    } else if (k == LogicalKeyboardKey.keyC) {
      action = 'channels';
    } else if (k == LogicalKeyboardKey.keyE) {
      action = 'epg';
    } else if (k == LogicalKeyboardKey.keyS) {
      action = 'settings';
    } else if (k == LogicalKeyboardKey.keyR) {
      action = 'record';
    }
    if (action != null) {
      _onShortcut(action);
      return true;
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      _onArrow('prevSource');
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _onArrow('nextSource');
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _onArrow('prevChannel');
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _onArrow('nextChannel');
      return true;
    }

    return false;
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
    _armDrawerAutoHide();
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
    _armDrawerAutoHide();
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
          // 与屏幕上边、右边保持约一行的距离（桌面无 SafeArea 边距，
          // 这里显式留白）
          padding: const EdgeInsets.only(top: 20, right: 28, bottom: 8),
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
    _bottomHideTimer?.cancel();
    // 避免鼠标每次移动都触发重建
    if (!_bottomHovering && mounted) {
      setState(() => _bottomHovering = true);
    }
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

  /// 抽屉 hover 移出后 3 秒自动隐藏
  void _startDrawerHideTimer() {
    _drawerHideTimer?.cancel();
    _drawerHideTimer = Timer(_drawerAutoHide, () {
      if (mounted) {
        setState(() {
          _leftDrawerOpen = false;
          _rightEpgOpen = false;
        });
        _ensureShortcutFocus();
      }
    });
  }
}

/// 内嵌网页频道控件：充满整个窗口，由网站自身播放器播放
/// （如央视频网页版）。信息面板/节目单/EPG 抽屉由 PlayerScreen
/// 叠加在本控件之上；左上角提供关闭按钮返回普通播放界面。
class _WebChannelOverlay extends StatefulWidget {
  final String url;
  final String title;
  final VoidCallback onExit;

  const _WebChannelOverlay({
    super.key,
    required this.url,
    required this.title,
    required this.onExit,
  });

  @override
  State<_WebChannelOverlay> createState() => _WebChannelOverlayState();
}

class _WebChannelOverlayState extends State<_WebChannelOverlay> {
  bool _loaded = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
            // 网页播放器（如央视频）自动开播，无需用户先点击网页
            mediaPlaybackRequiresUserGesture: false,
            supportZoom: false,
            transparentBackground: false,
          ),
          onLoadStop: (_, __) {
            if (mounted) setState(() => _loaded = true);
          },
          onReceivedError: (controller, request, error) {
            // 主文档加载失败才提示（子资源失败不影响播放）
            if (request.isForMainFrame ?? false) {
              if (mounted) {
                setState(() => _error = error.description);
              }
            }
          },
        ),
        if (!_loaded && _error == null)
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在打开网页频道...',
                    style: TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        if (_error != null)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off, color: Colors.white54, size: 40),
                const SizedBox(height: 8),
                Text('网页打开失败：$_error',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        // 左上角关闭按钮：浮在网页之上，返回普通播放界面
        Positioned(
          top: 12,
          left: 12,
          child: Material(
            color: Colors.black.withOpacity(0.55),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: Tooltip(
              message: '关闭网页频道',
              child: InkWell(
                onTap: widget.onExit,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child:
                      Icon(Icons.close, color: Colors.white, size: 22),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
