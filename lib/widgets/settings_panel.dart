import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/epg_source.dart';
import '../models/player_settings.dart';
import '../models/playlist_source.dart';
import '../services/player_controller.dart';

/// 设置面板 - 从底部弹出的设置菜单
/// 包含三个标签页：播放列表、EPG、播放器设置
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

class _SettingsPanelState extends State<SettingsPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

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
        child: Material(
          color: Colors.black87,
          elevation: 24,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: SafeArea(
            top: false,
            child: Builder(builder: (context) {
              // 横屏手机等矮屏（高度<500）时面板几乎占满全高，避免太短无法操作
              final screenH = MediaQuery.of(context).size.height;
              return SizedBox(
                height: screenH * (screenH < 500 ? 0.95 : 0.7),
                child: Column(
                children: [
                  // 顶部拖拽条 + 标题
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
                              icon:
                                  const Icon(Icons.close, color: Colors.white70),
                              onPressed: widget.onClose,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Tab 栏
                  TabBar(
                    controller: _tabController,
                    indicatorColor: Colors.blueAccent,
                    labelColor: Colors.blueAccent,
                    unselectedLabelColor: Colors.white54,
                    tabs: const [
                      Tab(text: '播放列表'),
                      Tab(text: 'EPG'),
                      Tab(text: '播放器'),
                      Tab(text: '系统'),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  // Tab 内容
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _PlaylistTab(),
                        _EpgTab(),
                        _PlayerSettingsTab(),
                        _SystemSettingsTab(),
                      ],
                    ),
                  ),
                ],
              ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ==================== 播放列表管理标签页 ====================

class _PlaylistTab extends StatefulWidget {
  @override
  State<_PlaylistTab> createState() => _PlaylistTabState();
}

class _PlaylistTabState extends State<_PlaylistTab> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  PlaylistSourceType _type = PlaylistSourceType.url;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickLocalFile() async {
    // file_picker 12+ 新 API：FilePicker.pickFile 直接返回 PlatformFile?
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'txt'],
    );
    if (file?.path != null) {
      setState(() {
        _urlController.text = file!.path!;
        _type = PlaylistSourceType.local;
      });
    }
  }

  Future<void> _addPlaylist() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写名称和地址')),
      );
      return;
    }
    setState(() => _isLoading = true);
    final format = url.toLowerCase().endsWith('.txt')
        ? PlaylistFormat.txt
        : PlaylistFormat.m3u;
    final source = PlaylistSource(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      type: _type,
      format: format,
      addedAt: DateTime.now(),
    );
    await context.read<PlayerController>().addPlaylist(source);
    _nameController.clear();
    _urlController.clear();
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final playlists = controller.sourceManager.playlists;
        // 整页 ListView：表单+列表一起滚动，横屏矮屏也不会溢出
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            // 添加表单
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<PlaylistSourceType>(
                          segments: const [
                            ButtonSegment(
                                value: PlaylistSourceType.url,
                                label: Text('网络地址')),
                            ButtonSegment(
                                value: PlaylistSourceType.local,
                                label: Text('本地文件')),
                          ],
                          selected: {_type},
                          onSelectionChanged: (s) =>
                              setState(() => _type = s.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('列表名称（如：我的电视）'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _urlController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration(
                              _type == PlaylistSourceType.url
                                  ? 'M3U/TXT 地址 URL'
                                  : '本地文件路径'),
                        ),
                      ),
                      if (_type == PlaylistSourceType.local)
                        IconButton(
                          icon: const Icon(Icons.folder_open,
                              color: Colors.blueAccent),
                          onPressed: _pickLocalFile,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addPlaylist,
                      icon: const Icon(Icons.add),
                      label: Text(_isLoading ? '添加中...' : '添加播放列表'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            // 播放列表
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无播放列表，请添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(playlists.length, (index) {
                final p = playlists[index];
                final isCurrent =
                    controller.sourceManager.currentPlaylistId == p.id;
                return ListTile(
                  // 点击整行即切换为当前播放列表
                  onTap: isCurrent
                      ? null
                      : () => controller.selectPlaylist(p.id),
                  leading: Icon(
                    p.type == PlaylistSourceType.url
                        ? Icons.cloud
                        : Icons.folder,
                    color: isCurrent
                        ? Colors.blueAccent
                        : Colors.white54,
                  ),
                  title: Text(
                    p.name,
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.blueAccent
                          : Colors.white,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    p.url,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 当前正在使用：蓝色对号（仅状态标识）
                      if (isCurrent)
                        const Icon(Icons.check_circle,
                            color: Colors.blueAccent, size: 22),
                      IconButton(
                        icon: const Icon(Icons.refresh,
                            color: Colors.amber),
                        onPressed: () =>
                            controller.refreshChannels(),
                        tooltip: '刷新',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete,
                            color: Colors.redAccent),
                        onPressed: () =>
                            controller.removePlaylist(p.id),
                        tooltip: '删除',
                      ),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}

// ==================== EPG 管理标签页 ====================

class _EpgTab extends StatefulWidget {
  @override
  State<_EpgTab> createState() => _EpgTabState();
}

class _EpgTabState extends State<_EpgTab> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addEpg() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写名称和地址')),
      );
      return;
    }
    setState(() => _isLoading = true);
    final source = EpgSource(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      addedAt: DateTime.now(),
    );
    await context.read<PlayerController>().addEpg(source);
    _nameController.clear();
    _urlController.clear();
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final epgs = controller.sourceManager.epgs;
        // 整页 ListView：表单+列表一起滚动，横屏矮屏也不会溢出
        return ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('EPG 名称（如：央视节目单）'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    style: const TextStyle(color: Colors.white),
                    decoration:
                        _inputDecoration('XMLTV EPG 地址 URL'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addEpg,
                      icon: const Icon(Icons.add),
                      label: Text(_isLoading ? '添加中...' : '添加 EPG'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            if (epgs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无 EPG 源，请添加',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              ...List.generate(epgs.length, (index) {
                final e = epgs[index];
                final isCurrent =
                    controller.sourceManager.currentEpgId == e.id;
                return ListTile(
                  // 点击整行即切换为当前 EPG
                  onTap: isCurrent
                      ? null
                      : () => controller.selectEpg(e.id),
                  leading: Icon(Icons.menu_book,
                      color: isCurrent
                          ? Colors.blueAccent
                          : Colors.white54),
                  title: Text(
                    e.name,
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.blueAccent
                          : Colors.white,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    e.url,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 当前正在使用：蓝色对号（仅状态标识）
                      if (isCurrent)
                        const Icon(Icons.check_circle,
                            color: Colors.blueAccent, size: 22),
                      IconButton(
                        icon: const Icon(Icons.refresh,
                            color: Colors.amber),
                        onPressed: () => controller.refreshEpg(),
                        tooltip: '刷新',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete,
                            color: Colors.redAccent),
                        onPressed: () => controller.removeEpg(e.id),
                        tooltip: '删除',
                      ),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}

// ==================== 播放器设置标签页 ====================

class _PlayerSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final s = controller.settings;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _buildQualitySelector(controller),
            SwitchListTile(
              secondary: const Icon(Icons.skip_next, color: Colors.white70),
              title: const Text('自动播放下一频道',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('当前节目结束后自动切换',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.autoPlayNext,
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(autoPlayNext: v)),
              activeColor: Colors.blueAccent,
            ),
            SwitchListTile(
              secondary:
                  const Icon(Icons.picture_in_picture, color: Colors.white70),
              title: const Text('画中画模式',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('使用小窗继续观看',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.pipEnabled,
              onChanged: (v) =>
                  controller.updateSettings(s.copyWith(pipEnabled: v)),
              activeColor: Colors.blueAccent,
            ),
            _buildSlider(
              icon: Icons.touch_app,
              title: '手势灵敏度',
              value: s.gestureSensitivity,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${s.gestureSensitivity.toStringAsFixed(1)}x',
              onChanged: (v) => controller
                  .updateSettings(s.copyWith(gestureSensitivity: v)),
            ),
            _buildSlider(
              icon: Icons.timer,
              title: '面板自动隐藏',
              value: s.autoHideDelay / 1000,
              min: 1.0,
              max: 10.0,
              divisions: 9,
              label: '${(s.autoHideDelay / 1000).toStringAsFixed(1)} 秒',
              onChanged: (v) => controller.updateSettings(
                  s.copyWith(autoHideDelay: (v * 1000).round())),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildQualitySelector(PlayerController controller) {
    return ExpansionTile(
      leading: const Icon(Icons.hd, color: Colors.white70),
      title: const Text('视频画质',
          style: TextStyle(color: Colors.white, fontSize: 15)),
      subtitle: Text(controller.settings.preferredQuality.label,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
      iconColor: Colors.white70,
      collapsedIconColor: Colors.white70,
      children: VideoQuality.values.map((q) {
        return RadioListTile<VideoQuality>(
          value: q,
          groupValue: controller.settings.preferredQuality,
          onChanged: (v) {
            if (v != null) {
              controller.updateSettings(
                  controller.settings.copyWith(preferredQuality: v));
            }
          },
          title: Text(q.label,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 14)),
          activeColor: Colors.blueAccent,
        );
      }).toList(),
    );
  }

  Widget _buildSlider({
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
      leading: Icon(icon, color: Colors.white70),
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
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ==================== 系统设置标签页 ====================

class _SystemSettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerController>(
      builder: (context, controller, _) {
        final s = controller.settings;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (controller.isDesktop) ...[
              SwitchListTile(
                secondary: const Icon(Icons.power_settings_new,
                    color: Colors.white70),
                title: const Text('开机启动',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                subtitle: const Text('开机后自动启动 OMPlayer',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: s.launchAtStartup,
                onChanged: (v) => controller
                    .updateSettings(s.copyWith(launchAtStartup: v)),
                activeColor: Colors.blueAccent,
              ),
            ],
            SwitchListTile(
              secondary: const Icon(Icons.access_time, color: Colors.white70),
              title: const Text('显示时间',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: const Text('右上角一直显示实时系统时间',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: s.showClock,
              onChanged: (v) =>
                  controller.updateSettings(s.copyWith(showClock: v)),
              activeColor: Colors.blueAccent,
            ),
            // DLNA 投屏接收状态（只读展示，启动即自动开启）
            ListTile(
              leading: Icon(Icons.cast,
                  color: controller.dlnaRunning
                      ? Colors.greenAccent
                      : Colors.redAccent),
              title: const Text('DLNA 投屏接收',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                controller.dlnaRunning
                    ? '已开启：${controller.dlnaName}\n${controller.dlnaEndpoint}\n手机需与本机同一局域网，防火墙需放行本程序'
                    : '未开启：端口可能被占用或被防火墙拦截',
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

// ==================== 公共工具 ====================

InputDecoration _inputDecoration(String hint) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: Colors.white10,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide.none,
    ),
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );
}
