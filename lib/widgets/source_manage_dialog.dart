import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/epg_source.dart';
import '../models/playlist_source.dart';
import '../services/local_file_picker.dart';
import '../services/player_controller.dart';

/// 节目源 / EPG 源管理窗口
/// 上：手机扫码管理二维码（未开启扫码时提示去偏好设置开启）
/// 中：源列表（勾选当前源 / 复制 URL / 删除）
/// 下：名称（选填）+ URL + 确定
class SourceManageDialog extends StatefulWidget {
  /// true=节目源(playlist)，false=EPG 源
  final bool isPlaylist;

  const SourceManageDialog({super.key, required this.isPlaylist});

  /// 打开窗口并返回对话框内组件的状态（供 player_screen 转发遥控器按键）
  static Future<void> present(
    BuildContext context, {
    required bool isPlaylist,
    required GlobalKey<SourceManageDialogState> key,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.72),
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF16181D),
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        child: SourceManageDialog(key: key, isPlaylist: isPlaylist),
      ),
    );
  }

  @override
  State<SourceManageDialog> createState() => SourceManageDialogState();
}

class SourceManageDialogState extends State<SourceManageDialog> {
  final _nameCtl = TextEditingController();
  final _urlCtl = TextEditingController();
  bool _saving = false;

  /// 节目源添加方式：网络地址 / 本地文件（EPG 源仅支持网络地址）
  PlaylistSourceType _srcType = PlaylistSourceType.url;
  bool _picking = false;

  /// 遥控器二维焦点：上/下在源列表行间移动（默认就在列表行上，
  /// 最后一行为「确定」行）；左/右在一行内的按钮间切换
  /// （-1=行本体，0=选择，1=复制，2=删除）。
  /// 行本体上按 OK 直接把该源设为当前源。输入框用鼠标/软键盘操作。
  int _kbRow = 0;
  int _kbCol = -1;

  /// 删除二段确认：首次 OK/点击只装填（红色高亮提示"再按一次确认删除"），
  /// 再按一次才真正删除。防止上下移动焦点时路过删除位、一按 OK 就误删源。
  /// 存装填行号（删除按钮固定在该行 col 2）
  int? _deleteArmedRow;

  @override
  void dispose() {
    _nameCtl.dispose();
    _urlCtl.dispose();
    super.dispose();
  }

  /// 遥控器/键盘按键入口（player_screen 在 modal 状态下转发）
  void handleRemoteKey(String action, {required bool isDown}) {
    if (!isDown || !mounted) return;
    final c = context.read<PlayerController>();
    final sources = widget.isPlaylist
        ? c.sourceManager.playlists
        : c.sourceManager.epgs;
    final lastRow = sources.length; // 最后一行=确定行
    switch (action) {
      case 'up':
        setState(() {
          _kbRow = (_kbRow - 1).clamp(0, lastRow);
          _deleteArmedRow = null; // 移动焦点即解除删除装填
        });
        _ensureVisible();
        break;
      case 'down':
        setState(() {
          _kbRow = (_kbRow + 1).clamp(0, lastRow);
          _deleteArmedRow = null;
        });
        _ensureVisible();
        break;
      case 'left':
        if (_kbRow == lastRow) break; // 确定行没有按钮列
        setState(() => _kbCol = (_kbCol - 1).clamp(-1, 2));
        break;
      case 'right':
        if (_kbRow == lastRow) break;
        setState(() => _kbCol = (_kbCol + 1).clamp(-1, 2));
        break;
      case 'ok':
        if (_kbRow == lastRow) {
          _save();
        } else {
          final src = sources[_kbRow];
          if (_kbCol == -1 || _kbCol == 0) {
            _select(src); // 列表行 OK / 选择按钮 → 直接设为当前源
          } else if (_kbCol == 1) {
            _copy(src is PlaylistSource ? src.url : (src as EpgSource).url);
          } else {
            _deletePress(_kbRow, src);
          }
        }
        break;
      case 'back':
        Navigator.of(context).maybePop();
        break;
    }
  }

  final _slotKey = GlobalKey();
  final Map<int, GlobalKey> _slotKeys = {}; // 按钮槽位 key：row*3+col
  final Map<int, GlobalKey> _rowKeys = {}; // 列表行本体 key：row
  final ScrollController _listScroll = ScrollController();

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = context.read<PlayerController>();
      final sources = widget.isPlaylist
          ? c.sourceManager.playlists
          : c.sourceManager.epgs;
      final GlobalKey? key;
      if (_kbRow >= sources.length) {
        key = _slotKeys[sources.length * 3]; // 确定按钮
      } else if (_kbCol == -1) {
        key = _rowKeys[_kbRow];
      } else {
        key = _slotKeys[_kbRow * 3 + _kbCol];
      }
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: 0.5);
      }
    });
  }

  Future<void> _select(Object src) async {
    final c = context.read<PlayerController>();
    if (src is PlaylistSource) {
      await c.selectPlaylist(src.id);
    } else {
      await c.selectEpg((src as EpgSource).id);
    }
  }

  /// 删除入口（遥控器 OK 与鼠标点击共用）：第一次只装填确认态并红框提示，
  /// 第二次才真正删除
  void _deletePress(int row, Object src) {
    if (_deleteArmedRow == row) {
      _delete(src);
      return;
    }
    setState(() => _deleteArmedRow = row);
  }

  Future<void> _delete(Object src) async {
    final c = context.read<PlayerController>();
    final name =
        src is PlaylistSource ? src.name : (src as EpgSource).name;
    if (src is PlaylistSource) {
      await c.removePlaylist(src.id);
    } else {
      await c.removeEpg((src as EpgSource).id);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除：$name'), duration: const Duration(seconds: 2)),
      );
      final remaining = widget.isPlaylist
          ? c.sourceManager.playlists.length
          : c.sourceManager.epgs.length;
      // 清理已删除槽位的 GlobalKey，避免无主 key 残留
      _slotKeys.removeWhere((k, _) => k >= remaining * 3);
      _rowKeys.removeWhere((k, _) => k >= remaining);
      setState(() {
        _kbRow = _kbRow.clamp(0, remaining);
        _kbCol = -1; // 删除后回到行焦点
        _deleteArmedRow = null;
      });
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('地址已复制'), duration: Duration(seconds: 2)),
    );
  }

  /// 调用系统文件选择器选本地直播源（任意格式，与 Windows 一致）。
  /// Android 走 ACTION_GET_CONTENT 通道；桌面走 file_picker。
  Future<void> _pickLocalFile() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final path = await pickLocalPlaylistFile();
      if (path != null && path.isNotEmpty && mounted) {
        setState(() {
          _urlCtl.text = path;
          _srcType = PlaylistSourceType.local;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('打开文件选择器失败：$e'),
              duration: const Duration(seconds: 3)),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    final url = _urlCtl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_srcType == PlaylistSourceType.local
                ? '请选择本地文件'
                : '请填写源地址')),
      );
      return;
    }
    final name = _nameCtl.text.trim().isEmpty
        ? _fallbackName(url)
        : _nameCtl.text.trim();
    final c = context.read<PlayerController>();
    setState(() => _saving = true);
    try {
      if (widget.isPlaylist) {
        await c.addPlaylist(PlaylistSource(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          url: url,
          type: _srcType,
          format: PlaylistFormat.unknown,
          addedAt: DateTime.now(),
        ));
      } else {
        await c.addEpg(EpgSource(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          url: url,
          addedAt: DateTime.now(),
        ));
      }
      if (!mounted) return;
      _nameCtl.clear();
      _urlCtl.clear();
      setState(() => _srcType = PlaylistSourceType.url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加：$name'), duration: const Duration(seconds: 2)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fallbackName(String url) {
    if (widget.isPlaylist && _srcType == PlaylistSourceType.local) {
      final parts = url.split(RegExp(r'[/\\]'));
      final base = parts.isNotEmpty ? parts.last : '';
      if (base.isNotEmpty) {
        final dot = base.lastIndexOf('.');
        return dot > 0 ? base.substring(0, dot) : base;
      }
      return '本地节目源';
    }
    final u = Uri.tryParse(url);
    final host = u?.host ?? '';
    if (host.isNotEmpty) return host;
    return widget.isPlaylist ? '节目源' : 'EPG 源';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isPlaylist ? '节目源设置' : 'EPG 源设置';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Row(
              children: [
                Image.asset('branding/icon_1024.png',
                    width: 21, height: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const Divider(height: 12, color: Colors.white12),
            _buildQrArea(),
            const SizedBox(height: 8),
            Flexible(child: _buildSourceList()),
            const Divider(height: 16, color: Colors.white12),
            _buildAddArea(),
          ],
        ),
      ),
    );
  }

  Widget _buildQrArea() {
    final c = context.watch<PlayerController>();
    final enabled = c.settings.remoteAdminEnabled;
    final url = c.remoteAdminUrl;
    if (!enabled || url.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.amber, size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text('请先在偏好设置开启手机扫码管理',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 96,
              backgroundColor: Colors.white,
              padding: EdgeInsets.zero,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF141821),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF141821),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('手机扫码添加源',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                const SizedBox(height: 4),
                Text(url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => _copy(url),
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制地址'),
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.lightBlueAccent,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceList() {
    final c = context.watch<PlayerController>();
    final sources =
        widget.isPlaylist ? c.sourceManager.playlists : c.sourceManager.epgs;
    final currentId = widget.isPlaylist
        ? c.sourceManager.currentPlaylistId
        : c.sourceManager.currentEpgId;
    if (sources.isEmpty) {
      return const Center(
        child: Text('暂无源，请在下方添加',
            style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }
    return ListView.builder(
      key: _slotKey,
      controller: _listScroll,
      shrinkWrap: true,
      itemCount: sources.length,
      itemBuilder: (context, index) {
        final src = sources[index];
        final name = src is PlaylistSource ? src.name : (src as EpgSource).name;
        final url = src is PlaylistSource ? src.url : (src as EpgSource).url;
        final isCurrent =
            (src is PlaylistSource ? src.id : (src as EpgSource).id) ==
                currentId;
        final rowFocused = _kbRow == index && _kbCol == -1;
        return Container(
          key: _rowKeys[index] ??= GlobalKey(),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(8),
            // 遥控器焦点在行本体上时整行高亮，此时按 OK 直接设为当前源
            border: Border.all(
              color: rowFocused ? Colors.white70 : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _select(src), // 鼠标点行任意处 = 切换为当前源
            child: Row(
              children: [
                _slotButton(
                  row: index,
                  col: 0,
                  icon: isCurrent
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: isCurrent ? Colors.blueAccent : Colors.white38,
                  tooltip: isCurrent ? '当前源' : '切换为当前源',
                  onPressed: () => _select(src),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      Text(url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                ),
                _slotButton(
                  row: index,
                  col: 1,
                  icon: Icons.copy,
                  color: Colors.white60,
                  tooltip: '复制地址',
                  onPressed: () => _copy(url),
                ),
                _slotButton(
                  row: index,
                  col: 2,
                  icon: _deleteArmedRow == index
                      ? Icons.delete_forever
                      : Icons.delete,
                  color: Colors.redAccent,
                  tooltip:
                      _deleteArmedRow == index ? '再按一次确认删除' : '删除',
                  armed: _deleteArmedRow == index,
                  onPressed: () => _deletePress(index, src),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 遥控器槽位按钮：键盘焦点框 + 鼠标点击二合一；
  /// [armed] 为删除二段确认装填态（红框红底醒目提示）
  Widget _slotButton({
    required int row,
    required int col,
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
    bool armed = false,
  }) {
    final focused = row == _kbRow && col == _kbCol;
    final slot = row * 3 + col;
    final key = _slotKeys[slot] ??= GlobalKey();
    return IconButton(
      key: key,
      icon: Icon(icon, size: 19),
      color: color,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        side: focused
            ? const BorderSide(color: Colors.white70, width: 1.4)
            : armed
                ? const BorderSide(color: Colors.redAccent, width: 1.6)
                : null,
        backgroundColor: armed ? Colors.redAccent.withOpacity(0.15) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onPressed: onPressed,
    );
  }

  Widget _buildAddArea() {
    final confirmSlot =
        (widget.isPlaylist
                ? context.watch<PlayerController>().sourceManager.playlists
                : context.watch<PlayerController>().sourceManager.epgs)
            .length *
            3;
    final isLocal =
        widget.isPlaylist && _srcType == PlaylistSourceType.local;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.isPlaylist) ...[
          SegmentedButton<PlaylistSourceType>(
            segments: const [
              ButtonSegment(
                value: PlaylistSourceType.url,
                label: Text('网络地址'),
              ),
              ButtonSegment(
                value: PlaylistSourceType.local,
                label: Text('本地文件'),
              ),
            ],
            selected: {_srcType},
            onSelectionChanged: (s) =>
                setState(() => _srcType = s.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -2, vertical: -2),
              foregroundColor: WidgetStatePropertyAll(Colors.white),
            ),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameCtl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '名称（选填）',
                  labelStyle: TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.blueAccent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _urlCtl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                keyboardType: TextInputType.url,
                readOnly: isLocal,
                onTap: isLocal && !kIsWeb ? _pickLocalFile : null,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: isLocal
                      ? '本地文件路径（任意类型，自动识别）'
                      : '源地址（http://...）',
                  labelStyle: const TextStyle(color: Colors.white38),
                  enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.blueAccent),
                  ),
                  suffixIcon: isLocal && !kIsWeb
                      ? IconButton(
                          tooltip: '选择文件',
                          icon: _picking
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.folder_open,
                                  color: Colors.lightBlueAccent),
                          onPressed: _picking ? null : _pickLocalFile,
                        )
                      : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Builder(builder: (context) {
            // 确定按钮所在行号 = 源数量（列表最后一行的下一行）
            final focused = _kbRow == confirmSlot ~/ 3;
            return Container(
              key: _slotKeys[confirmSlot] ??= GlobalKey(),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: focused
                    ? Border.all(color: Colors.white70, width: 1.4)
                    : null,
              ),
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check, size: 18),
                label: const Text('确定'),
              ),
            );
          }),
        ),
      ],
    );
  }
}
