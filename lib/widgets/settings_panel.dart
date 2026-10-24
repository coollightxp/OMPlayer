import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/player_settings.dart';
import '../services/player_controller.dart';
import 'scaled_panel.dart';

/// 设置面板：从底部滑出的单页滚动设置。
/// 仅保留少量参数设置、快捷键介绍与手势说明；
/// 节目源/EPG 来源内置在程序中，不再提供编辑入口。
class SettingsPanel extends StatefulWidget {
  final bool isOpen;
  final VoidCallback onClose;

  const SettingsPanel({
    super.key,
    required this.isOpen,
    required this.onClose,
  });

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      bottom: widget.isOpen ? 0 : -MediaQuery.of(context).size.height,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: widget.isOpen ? 1.0 : 0.0,
        child: ScaledPanel(
          alignment: Alignment.bottomCenter,
          scale: panelScaleOf(context),
          child: Material(
            color: Colors.black87,
            elevation: 24,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            child: SafeArea(
              top: false,
              child: Builder(builder: (context) {
                // 横屏手机等矮屏（高度<500）时面板几乎占满全高
                final screenH = MediaQuery.of(context).size.height;
                return SizedBox(
                  height: screenH * (screenH < 500 ? 0.95 : 0.72),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.only(top: 10, bottom: 8),
                        child: Column(
                          children: [
                            Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white30,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const SizedBox(width: 16),
                                const Text(
                                  '设置',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(Icons.close,
                                      color: Colors.white70),
                                  onPressed: widget.onClose,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: Colors.white12, height: 1),
                      Expanded(
                        child: Consumer<PlayerController>(
                          builder: (context, controller, _) {
                            final s = controller.settings;
                            return ListView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              children: [
                                _section('播放'),
                                _switchTile(
                                  icon: Icons.skip_next,
                                  title: '自动播放下一频道',
                                  subtitle: '当前节目结束后自动切换',
                                  value: s.autoPlayNext,
                                  onChanged: (v) => controller.updateSettings(
                                      s.copyWith(autoPlayNext: v)),
                                ),
                                _segmentTile<int>(
                                  icon: Icons.slow_motion_video,
                                  title: '播放缓冲',
                                  subtitle: '弱网或直播卡顿可调大，换台后生效',
                                  segments: const [5, 10, 20, 30],
                                  selected: s.bufferSeconds,
                                  labelOf: (v) => '$v 秒',
                                  onSelected: (v) =>
                                      controller.updateSettings(
                                          s.copyWith(bufferSeconds: v)),
                                ),
                                _segmentTile<String>(
                                  icon: Icons.hd,
                                  title: '画面清晰度',
                                  subtitle: '当前：${controller.resolution}'
                                      '${controller.actualResolutionLabel.isEmpty ? '' : '（实际 ${controller.actualResolutionLabel}）'}',
                                  segments: const ['1080P', '720P', '540P'],
                                  selected: controller.resolution,
                                  labelOf: (v) => v,
                                  onSelected: controller.setResolution,
                                ),

                                _section('听电视'),
                                _switchTile(
                                  icon: Icons.visibility_off,
                                  title: '听电视时隐藏窗口',
                                  subtitle: controller.isDesktop
                                      ? 'Windows 摸鱼模式：只保留声音，窗口最小化（点任务栏恢复）'
                                      : '仅桌面端生效',
                                  value: s.listenModeHideWindow,
                                  onChanged: controller.isDesktop
                                      ? (v) => controller.updateSettings(s
                                          .copyWith(listenModeHideWindow: v))
                                      : null,
                                ),
                                _switchTile(
                                  icon: Icons.music_note,
                                  title: '听电视时显示信息卡片',
                                  subtitle: '手机/平板显示上一台、下一台与暂停/继续',
                                  value: s.listenModeShowCard,
                                  onChanged: (v) => controller.updateSettings(
                                      s.copyWith(listenModeShowCard: v)),
                                ),

                                _section('界面'),
                                _switchTile(
                                  icon: Icons.schedule,
                                  title: '显示系统时间',
                                  subtitle: '右上角常驻显示当前时间',
                                  value: s.showClock,
                                  onChanged: controller.setShowClock,
                                ),
                                _sliderTile(
                                  icon: Icons.touch_app,
                                  title: '手势灵敏度',
                                  value: s.gestureSensitivity,
                                  min: 0.5,
                                  max: 2.0,
                                  divisions: 15,
                                  label:
                                      '${s.gestureSensitivity.toStringAsFixed(1)}x',
                                  onChanged: (v) => controller.updateSettings(
                                      s.copyWith(gestureSensitivity: v)),
                                ),
                                _sliderTile(
                                  icon: Icons.timer,
                                  title: '面板自动隐藏',
                                  value: s.autoHideDelay / 1000,
                                  min: 1.0,
                                  max: 10.0,
                                  divisions: 9,
                                  label:
                                      '${(s.autoHideDelay / 1000).toStringAsFixed(1)} 秒',
                                  onChanged: (v) => controller.updateSettings(
                                      s.copyWith(
                                          autoHideDelay: (v * 1000).round())),
                                ),
                                _uiScaleTiles(context, controller, s),

                                if (controller.isDesktop) ...[
                                  _section('系统'),
                                  _switchTile(
                                    icon: Icons.push_pin,
                                    title: '窗口置顶',
                                    subtitle: '窗口始终保持在最前，确保快捷键响应',
                                    value: s.alwaysOnTop,
                                    onChanged: (v) => controller.updateSettings(
                                        s.copyWith(alwaysOnTop: v)),
                                  ),
                                  _switchTile(
                                    icon: Icons.power_settings_new,
                                    title: '开机启动',
                                    subtitle: '开机后自动启动 OMTV',
                                    value: s.launchAtStartup,
                                    onChanged: (v) => controller.updateSettings(
                                        s.copyWith(launchAtStartup: v)),
                                  ),
                                  _switchTile(
                                    icon: Icons.fullscreen,
                                    title: '启动全屏',
                                    subtitle: '仅在程序启动时生效一次',
                                    value: s.startFullscreen,
                                    onChanged: (v) => controller.updateSettings(
                                        s.copyWith(startFullscreen: v)),
                                  ),
                                  _switchTile(
                                    icon: Icons.cast,
                                    title: '接收投屏（DLNA）',
                                    subtitle: '允许手机、电脑把视频投到本机播放',
                                    value: s.dlnaEnabled,
                                    onChanged: (v) => controller.updateSettings(
                                        s.copyWith(dlnaEnabled: v)),
                                  ),
                                ],

                                _section('快捷键'),
                                _shortcuts(controller.isDesktop),

                                _section('手势与遥控器'),
                                _gestures(controller.isDesktop),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== 通用组件 ====================

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.blueAccent,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon, color: Colors.white70, size: 22),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(title,
          style: TextStyle(
              color: onChanged == null ? Colors.white38 : Colors.white,
              fontSize: 15)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      value: value,
      onChanged: onChanged,
      activeColor: Colors.blueAccent,
    );
  }

  Widget _segmentTile<T>({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<T> segments,
    required T selected,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
  }) {
    // 选中值不在分段列表里时（如 4K 频道）回退到第一项显示
    final value = segments.contains(selected) ? selected : segments.first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SegmentedButton<T>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: segments
                .map((v) => ButtonSegment<T>(
                    value: v, label: Text(labelOf(v))))
                .toList(),
            selected: {value},
            onSelectionChanged: (sel) => onSelected(sel.first),
          ),
        ],
      ),
    );
  }

  Widget _sliderTile({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: Colors.white70, size: 22),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: SliderTheme(
        data: SliderThemeData(
          activeTrackColor: Colors.blueAccent,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.blueAccent,
          overlayColor: Colors.blueAccent.withOpacity(0.2),
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// 字体缩放：自动按分辨率适配 + 手动滑块
  Widget _uiScaleTiles(
      BuildContext context, PlayerController controller, PlayerSettings s) {
    final mq = MediaQuery.of(context);
    final physicalW = mq.size.width * mq.devicePixelRatio;
    final autoScale = (physicalW / 1920.0).clamp(1.0, 3.0);
    final scale = s.uiScaleAuto ? autoScale : s.uiScale;
    return Column(
      children: [
        _switchTile(
          icon: Icons.screen_rotation,
          title: '字体大小自动适配',
          subtitle:
              '按屏幕分辨率自动缩放（当前 ${physicalW.round()} 像素，自动 ${autoScale.toStringAsFixed(2)}x）',
          value: s.uiScaleAuto,
          onChanged: (v) =>
              controller.updateSettings(s.copyWith(uiScaleAuto: v)),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(Icons.format_size,
              color: s.uiScaleAuto ? Colors.white24 : Colors.white70,
              size: 22),
          title: Text('手动字体缩放',
              style: TextStyle(
                  color: s.uiScaleAuto ? Colors.white38 : Colors.white,
                  fontSize: 15)),
          enabled: !s.uiScaleAuto,
          subtitle: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withOpacity(0.2),
              disabledActiveTrackColor: Colors.white24,
              disabledThumbColor: Colors.white38,
            ),
            child: Slider(
              value: scale.clamp(0.8, 3.0),
              min: 0.8,
              max: 3.0,
              divisions: 22,
              label: '${scale.toStringAsFixed(1)}x',
              onChanged: s.uiScaleAuto
                  ? null
                  : (v) =>
                      controller.updateSettings(s.copyWith(uiScale: v)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _shortcuts(bool desktop) {
    final rows = <List<String>>[
      ['空格', '播放 / 暂停'],
      ['F / F11', '全屏切换'],
      ['M', '静音 / 恢复'],
      ['T', '听电视'],
      ['L', '锁定 / 解锁'],
      ['C', '频道列表'],
      ['E', '节目单'],
      ['S', '设置'],
      ['R', '录制'],
      ['↑ / ↓', '切换频道'],
      ['← / →', '拖动进度（点播）'],
      ['数字键', '直接输入频道号'],
      ['返回 / Esc', '逐层关闭面板'],
      if (desktop) ['右键', '相当于返回键'],
    ];
    return _infoCard(rows
        .map((r) => _infoRow(r[0], r[1]))
        .toList());
  }

  Widget _gestures(bool desktop) {
    final rows = <List<String>>[
      ['左侧上下滑', '调节亮度'],
      ['右侧上下滑', '调节音量'],
      if (desktop) ['双击画面', '全屏 / 还原'],
      if (!desktop) ['单击左侧', '打开频道列表'],
      if (!desktop) ['单击中间', '显示控制面板'],
      if (!desktop) ['单击右侧', '打开节目单'],
      ['遥控器 ← / →', '面板内移动高亮'],
      ['遥控器 OK', '短按确认 / 长按呼出控制面板'],
      ['遥控器返回', '逐层关闭 / 锁定状态下解锁'],
    ];
    return _infoCard(rows
        .map((r) => _infoRow(r[0], r[1]))
        .toList());
  }

  Widget _infoCard(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(children: children),
    );
  }

  Widget _infoRow(String key, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 118,
            child: Text(
              key,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(desc,
                style:
                    const TextStyle(color: Colors.white60, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
