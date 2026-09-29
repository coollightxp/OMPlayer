import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/epg_program.dart';
import '../services/player_controller.dart';

/// 底部信息/控制面板
/// 布局（参考电视播放器）：台标 | 当前节目(大字)+时段/频道/分辨率/线路 | 控制按钮
/// 点播文件时顶部显示可拖动进度条，直播流不显示
class BottomProgramPanel extends StatelessWidget {
  final bool isVisible;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onOpenChannels;
  final VoidCallback onOpenEpg;
  final VoidCallback onOpenSettings;
  final VoidCallback onScreenshot;
  final VoidCallback onToggleRecord;

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
    this.onHoverEnter,
    this.onHoverExit,
    this.onHoverMove,
  });

  static final _hm = DateFormat('HH:mm');

  String _range(EpgProgram p) => '${_hm.format(p.startTime)} - ${_hm.format(p.endTime)}';
  String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // 宽屏（电视/桌面）：面板做成居中悬浮卡片，两侧留白、底边抬升；
    // 手机窄屏仍贴近两侧，避免内容被挤
    final screenW = MediaQuery.of(context).size.width;
    final hPad = screenW > 1200 ? 72.0 : (screenW > 900 ? 40.0 : 10.0);
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      left: hPad,
      right: hPad,
      bottom: isVisible ? (screenW > 900 ? 16 : 8) : -300,
      child: MouseRegion(
        onEnter: (_) => onHoverEnter?.call(),
        onExit: (_) => onHoverExit?.call(),
        onHover: (_) => onHoverMove?.call(),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: isVisible ? 1.0 : 0.0,
          child: Container(
          decoration: BoxDecoration(
            // 悬浮卡片：深色半透明 + 圆角 + 细边框 + 上方渐隐遮罩衔接视频
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
              padding: const EdgeInsets.fromLTRB(22, 16, 18, 10),
              child: Consumer<PlayerController>(
                builder: (context, c, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (c.isSeekable) _buildSeekBar(c),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildLogo(c),
                        const SizedBox(width: 28),
                        Expanded(child: _buildInfo(c)),
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
    );
  }

  // ==================== 台标 ====================

  Widget _buildLogo(PlayerController c) {
    const double size = 128;
    final logo = c.currentLogo;
    Widget placeholder() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.live_tv, color: Colors.white54, size: 64),
        );
    if (logo.isEmpty) return placeholder();
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
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

  Widget _buildInfo(PlayerController c) {
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
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 5),
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
            '点击左侧边缘或 ≡ 按钮打开频道列表',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
      ],
    );
  }

  Widget _metaText(String text, Color color) {
    return Text(text,
        style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500));
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
    final total = c.duration;
    final pos = c.position;
    final max = total.inMilliseconds.toDouble();
    final value = pos.inMilliseconds.clamp(0, max <= 0 ? 1 : max).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(_clock(pos),
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.blueAccent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.blueAccent,
              ),
              child: Slider(
                value: value,
                max: max <= 0 ? 1 : max,
                onChanged: (v) =>
                    c.seekTo(Duration(milliseconds: v.round())),
              ),
            ),
          ),
          Text(_clock(total),
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }

  // ==================== 控制按钮 ====================

  Widget _buildButtons(PlayerController c) {
    final hasVideo = c.currentChannel != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(Icons.skip_previous, '上一个源',
            c.hasPrevSource ? c.prevSource : null),
        Text('源${c.sourceIndex + 1}/${c.sourceCount}',
            style: const TextStyle(color: Colors.white54, fontSize: 11)),
        _btn(Icons.skip_next, '下一个源',
            c.hasNextSource ? c.nextSource : null),
        IconButton(
          icon: Icon(c.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white, size: 30),
          onPressed: hasVideo ? onTogglePlayPause : null,
        ),
        const SizedBox(width: 4),
        if (c.isDesktop) ...[
          _btn(Icons.camera_alt, '截图', hasVideo ? onScreenshot : null),
          // 录制：开始=红色圆点，录制中=红色方块（带呼吸感）
          IconButton(
            icon: Icon(
              c.isRecording ? Icons.stop_rounded : Icons.fiber_manual_record,
              color: c.isRecording ? Colors.redAccent : Colors.white,
              size: c.isRecording ? 30 : 26,
            ),
            onPressed: hasVideo ? onToggleRecord : null,
            tooltip: c.isRecording ? '停止录制' : '开始录制',
          ),
          const SizedBox(width: 4),
        ],
        _btn(Icons.list, '频道列表', onOpenChannels),
        _btn(Icons.menu_book, '节目单', onOpenEpg),
        _btn(Icons.settings, '设置', onOpenSettings),
      ],
    );
  }

  Widget _btn(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 24),
      onPressed: onPressed,
      tooltip: tooltip,
    );
  }
}
