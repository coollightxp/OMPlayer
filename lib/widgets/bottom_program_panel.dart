import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

/// 底部信息/控制面板
/// 布局（参考电视播放器）：台标 | 当前节目(大字)+时段/频道/分辨率/线路 | 控制按钮
/// 点播文件时顶部显示可拖动进度条，直播流不显示
///
/// 遥控器导航（TV 盒子无鼠标）：面板可见时，←/→ 在可用按钮间移动高亮，
/// OK 激活当前按钮，返回键由播放页负责关闭面板。
class BottomProgramPanel extends StatefulWidget {
  final bool isVisible;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onOpenChannels;
  final VoidCallback onOpenEpg;
  final VoidCallback onOpenSettings;
  final VoidCallback onScreenshot;
  final VoidCallback onToggleRecord;

  /// 调出手机扫码管理页（地址为空时传 null，按钮不显示）
  final VoidCallback? onOpenRemoteAdmin;

  /// 遥控器激活「跳转类」按钮（频道/EPG/设置/扫码）后通知播放页关闭面板
  final VoidCallback? onDismissRemote;

  /// 鼠标悬停在面板上/移出面板（悬停期间不自动隐藏）
  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;
  final VoidCallback? onHoverMove;

  const BottomProgramPanel({
    super.key,
    required this.isVisible,
    required this.onTogglePlayPause,
    required this.onOpenChannels,
    required this.onOpenEpg,
    required this.onOpenSettings,
    required this.onScreenshot,
    required this.onToggleRecord,
    this.onOpenRemoteAdmin,
    this.onDismissRemote,
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
  });

  @override
  State<BottomProgramPanel> createState() => BottomProgramPanelState();
}

/// 面板内一个可由遥控器激活的按钮
class _KbAction {
  final String id;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 激活后是否关闭面板（跳转到其它面板/弹层 = true）
  final bool dismiss;

  const _KbAction(this.id, this.icon, this.tooltip, this.onPressed,
      {this.dismiss = false});
}

class BottomProgramPanelState extends State<BottomProgramPanel> {
  /// 遥控器当前高亮的按钮 id（null = 无高亮）。
  /// 用 id 而非索引：播放状态变化会让按钮顺序/可用性变化（如投屏按钮），
  /// 高亮不会因此错位。
  String? _kbId;

  /// 最近一次构建出的动作列表（与按钮排列顺序一致）
  List<_KbAction> _actions = const [];

  /// 当前可激活（未禁用）的动作
  List<_KbAction> get _enabledActions =>
      _actions.where((a) => a.onPressed != null).toList();

  @override
  void didUpdateWidget(BottomProgramPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板每次被呼出时，默认高亮「播放/暂停」（不可用时取第一个可用按钮）
    if (widget.isVisible && !oldWidget.isVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final enabled = _enabledActions;
        if (enabled.isEmpty) {
          setState(() => _kbId = null);
          return;
        }
        final play = enabled.where((a) => a.id == 'playpause');
        setState(() =>
            _kbId = play.isNotEmpty ? play.first.id : enabled.first.id);
      });
    }
  }

  /// 遥控器按键：←/→ 在【可用】按钮间移动高亮，OK 激活当前按钮
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!widget.isVisible) return;
    final enabled = _enabledActions;
    if (enabled.isEmpty) return;
    if (action == 'left' || action == 'right') {
      if (!isDown) return;
      var i = enabled.indexWhere((a) => a.id == _kbId);
      setState(() {
        if (i < 0) {
          i = action == 'right' ? 0 : enabled.length - 1;
        } else if (action == 'right') {
          i = (i + 1) % enabled.length;
        } else {
          i = (i - 1 + enabled.length) % enabled.length;
        }
        _kbId = enabled[i].id;
      });
      return;
    }
    if (action == 'ok' && isDown) {
      final i = enabled.indexWhere((a) => a.id == _kbId);
      final a = i >= 0 ? enabled[i] : enabled.first;
      a.onPressed?.call();
      if (a.dismiss) widget.onDismissRemote?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 宽屏（电视/桌面）：面板做成居中悬浮卡片，两侧留白、底边抬升；
    // 窄屏贴近两侧，避免内容被挤
    final screenW = MediaQuery.of(context).size.width;
    final scale = panelScaleOf(context);
    // 用户多次反馈手机面板要尽量宽：窄屏完全贴边（0 边距）
    final hPad = screenW > 1200 ? 72.0 : (screenW > 900 ? 40.0 : 0.0);
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      left: hPad,
      right: hPad,
      bottom: widget.isVisible ? (screenW > 900 ? 16 : 8) : -320,
      child: MouseRegion(
        onEnter: (_) => widget.onHoverEnter?.call(),
        onExit: (_) => widget.onHoverExit?.call(),
        onHover: (_) => widget.onHoverMove?.call(),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.isVisible ? 1.0 : 0.0,
          child: ScaledPanel(
            alignment: Alignment.bottomCenter,
            scale: scale,
            child: Container(
              decoration: BoxDecoration(
                // 悬浮卡片：深色半透明 + 圆角 + 细边框 + 上方渐隐衔接视频
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.55),
                    Colors.black.withOpacity(0.85),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  // 贴近屏幕左右两端（横向拉长），上下略加高保持比例
                  padding: scale < 1
                      ? const EdgeInsets.fromLTRB(6, 16, 4, 14)
                      : const EdgeInsets.fromLTRB(22, 16, 18, 10),
                  child: Consumer<PlayerController>(
                    builder: (context, c, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (c.isSeekable) _buildSeekBar(c),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _buildLogo(c, scale),
                            SizedBox(width: scale < 1 ? 12 : 28),
                            Expanded(child: _buildInfo(c, scale)),
                            Flexible(
                              flex: 0,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: _buildButtons(c),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== 台标 ====================

  Widget _buildLogo(PlayerController c, double scale) {
    // 手机台标 64→92：用户反馈偏小，配合面板整体加高
    final size = scale < 1 ? 92.0 : 128.0;
    final logo = c.currentLogo;
    Widget placeholder() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(scale < 1 ? 10 : 16),
          ),
          child: Icon(Icons.live_tv,
              color: Colors.white54, size: scale < 1 ? 46 : 64),
        );
    if (logo.isEmpty) return placeholder();
    return ClipRRect(
      borderRadius: BorderRadius.circular(scale < 1 ? 10 : 16),
      child: Image.network(
        logo,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => placeholder(),
      ),
    );
  }

  // ==================== 节目信息 ====================

  Widget _buildInfo(PlayerController c, double scale) {
    final info = c.getNowPlayingInfo();
    final current = c.currentProgram;
    final next = c.nextProgram;
    final hasChannel = c.currentChannel != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 大字：当前节目名（无 EPG 时显示频道名）
        Text(
          current?.title ?? (hasChannel ? info.channelName : '未选择频道'),
          style: TextStyle(
            color: Colors.white,
            fontSize: scale < 1 ? 17 : 22,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SizedBox(height: scale < 1 ? 3 : 5),
        // 时段 / 频道 / 分辨率 / 线路
        Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (current != null)
              _metaText(_range(current), Colors.amber),
            if (hasChannel) _metaText(info.channelName, Colors.white70),
            if (c.resolutionText.isNotEmpty)
              _badge(c.resolutionText),
            _badge('线路 ${c.sourceIndex + 1}/${c.sourceCount}'),
          ],
        ),
        const SizedBox(height: 3),
        // 即将播放（保留结束时间）
        if (next != null)
          Text(
            '${_range(next)}  ${next.title}',
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else if (!hasChannel)
          const Text(
            '点击屏幕或 ≡ 按钮打开频道列表',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
      ],
    );
  }

  Widget _metaText(String text, Color color) {
    return Text(text,
        style:
            TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500));
  }

  Widget _badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white30),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
    );
  }

  // ==================== 点播进度条 ====================

  Widget _buildSeekBar(PlayerController c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _SeekBar(controller: c, clock: _clock),
    );
  }

  // ==================== 控制按钮 ====================

  Widget _buildButtons(PlayerController c) {
    final hasVideo = c.currentChannel != null;
    // 可用动作：禁用按钮不进列表，遥控器只会高亮能点的按钮
    final actions = <_KbAction>[
      _KbAction('prevSource', Icons.skip_previous, '上一个源',
          c.hasPrevSource ? c.prevSource : null),
      _KbAction('nextSource', Icons.skip_next, '下一个源',
          c.hasNextSource ? c.nextSource : null),
      _KbAction(
          'playpause',
          c.isPlaying ? Icons.pause : Icons.play_arrow,
          c.isPlaying ? '暂停' : '播放',
          hasVideo ? widget.onTogglePlayPause : null),
      if (c.isDesktop) ...[
        _KbAction('screenshot', Icons.camera_alt, '截图',
            hasVideo ? widget.onScreenshot : null),
        _KbAction(
            'record',
            c.isRecording ? Icons.stop_rounded : Icons.fiber_manual_record,
            c.isRecording ? '停止录制' : '开始录制',
            hasVideo ? widget.onToggleRecord : null),
      ],
      _KbAction(
          'rotate',
          Icons.screen_rotation,
          c.videoRotation.value == 0 ? '旋转画面' : '恢复原始方向',
          hasVideo ? c.cycleVideoRotation : null),
      _KbAction('channels', Icons.list, '频道列表', widget.onOpenChannels,
          dismiss: true),
      _KbAction('epg', Icons.menu_book, '节目单', widget.onOpenEpg,
          dismiss: true),
      if (widget.onOpenRemoteAdmin != null)
        _KbAction('remoteAdmin', Icons.qr_code_2, '手机扫码管理',
            widget.onOpenRemoteAdmin,
            dismiss: true),
      _KbAction('settings', Icons.settings, '设置', widget.onOpenSettings,
          dismiss: true),
      if (c.isCasting)
        _KbAction('cast', Icons.cast_connected, '断开投屏',
            c.stopCastAndRestore),
    ];
    _actions = actions;
    // 当前高亮的动作若已消失（如断开投屏），清除高亮，等下次方向键重选
    if (_kbId != null && !actions.any((a) => a.id == _kbId)) _kbId = null;

    final children = <Widget>[
      // 源切换文字夹在两个按钮中间，不占遥控器动作位
      _btn(actions[0], big: true),
      Text('源${c.sourceIndex + 1}/${c.sourceCount}',
          style: const TextStyle(color: Colors.white54, fontSize: 11)),
      _btn(actions[1], big: true),
      _btn(actions[2], big: true),
    ];
    if (c.isDesktop) {
      children.addAll([
        const SizedBox(width: 4),
        _btn(actions.firstWhere((a) => a.id == 'screenshot')),
        _btn(actions.firstWhere((a) => a.id == 'record'), big: true),
        const SizedBox(width: 4),
      ]);
    }
    children.add(_btn(actions.firstWhere((a) => a.id == 'rotate')));

    void addById(String id) {
      final i = actions.indexWhere((a) => a.id == id);
      if (i >= 0) children.add(_btn(actions[i]));
    }

    addById('channels');
    addById('epg');
    addById('remoteAdmin');
    addById('settings');
    addById('cast');

    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _btn(_KbAction a, {bool big = false}) {
    final selected = a.id == _kbId;
    final color = a.id == 'record'
        ? (a.tooltip.contains('停止') ? Colors.redAccent : Colors.white)
        : (a.id == 'cast'
            ? Colors.redAccent
            : (a.id == 'rotate'
                ? null
                : Colors.white));
    final iconColor = a.id == 'rotate'
        ? null // ValueListenableBuilder 内部按旋转角度决定颜色
        : (a.onPressed == null ? Colors.white24 : color);
    final iconSize = big ? 30.0 : 24.0;

    // 旋转按钮的颜色随旋转状态变化，单独保留 ValueListenableBuilder
    if (a.id == 'rotate') {
      return _wrapSelected(
        selected,
        ValueListenableBuilder<int>(
          valueListenable: context.read<PlayerController>().videoRotation,
          builder: (context, rot, _) => IconButton(
            icon: Icon(Icons.screen_rotation,
                color: a.onPressed == null
                    ? Colors.white24
                    : (rot == 0 ? Colors.white54 : Colors.amber),
                size: iconSize),
            onPressed: a.onPressed,
            tooltip: a.tooltip,
          ),
        ),
      );
    }

    return _wrapSelected(
      selected,
      IconButton(
        icon: Icon(a.icon,
            color: a.onPressed == null ? Colors.white24 : iconColor,
            size: iconSize),
        onPressed: a.onPressed,
        tooltip: a.tooltip,
      ),
    );
  }

  /// 遥控器高亮：蓝底圆角方框
  Widget _wrapSelected(bool selected, Widget child) {
    if (!selected) return child;
    return Container(
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueAccent, width: 1.6),
      ),
      child: child,
    );
  }

  static final _hm = DateFormat('HH:mm');

  String _range(EpgProgram p) =>
      '${_hm.format(p.startTime)} - ${_hm.format(p.endTime)}';
  String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// 点播进度条。
///
/// 拖动过程中只更新本地预览位置，【松手时】(onChangeEnd) 才真正 seek：
/// Slider.onChanged 在一次拖动中会连续回调几十次，若每次都 seekTo，
/// 会反复打断播放内核对长视频远距位置的缓冲（投屏长视频拖动时表现为
/// 画面卡死、随后被看门狗判定缓冲超时而销毁重建）。
class _SeekBar extends StatefulWidget {
  final PlayerController controller;
  final String Function(Duration) clock;

  const _SeekBar({required this.controller, required this.clock});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// 拖动中的预览位置（毫秒）；未拖动时为 null，跟随实际播放位置
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final total = c.duration;
    final max = total.inMilliseconds.toDouble();
    final safeMax = max <= 0 ? 1.0 : max;
    final pos = _dragMs ??
        c.position.inMilliseconds.clamp(0, safeMax.round()).toDouble();
    final value = pos.clamp(0, safeMax).toDouble();
    return Row(
      children: [
        Text(widget.clock(Duration(milliseconds: value.round())),
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
            ),
            child: Slider(
              value: value,
              max: safeMax,
              onChangeStart: (v) => setState(() => _dragMs = v),
              onChanged: (v) => setState(() => _dragMs = v),
              onChangeEnd: (v) {
                c.seekTo(Duration(milliseconds: v.round()));
                setState(() => _dragMs = null);
              },
            ),
          ),
        ),
        Text(widget.clock(total),
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }
}
