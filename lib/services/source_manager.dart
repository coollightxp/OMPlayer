import 'dart:convert' show utf8;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/epg_source.dart';
import '../models/playlist_source.dart';
import 'playlist_parser.dart';
import 'xmltv_epg_parser.dart';

/// 播放列表与 EPG 源管理服务
/// 负责：源的增删改查、本地持久化、网络拉取与解析
class SourceManager {
  static const String _playlistKey = 'omplayer_playlists';
  static const String _currentPlaylistKey = 'omplayer_current_playlist';
  static const String _epgKey = 'omplayer_epgs';
  static const String _currentEpgKey = 'omplayer_current_epg';

  List<PlaylistSource> _playlists = [];
  List<EpgSource> _epgs = [];
  String? _currentPlaylistId;
  String? _currentEpgId;

  // 缓存解析后的数据
  List<ChannelCategory> _cachedChannels = [];
  Map<String, List<EpgProgram>> _cachedEpg = {};
  bool _channelsLoaded = false;
  bool _epgLoaded = false;

  List<PlaylistSource> get playlists => List.unmodifiable(_playlists);
  List<EpgSource> get epgs => List.unmodifiable(_epgs);
  String? get currentPlaylistId => _currentPlaylistId;
  String? get currentEpgId => _currentEpgId;
  List<ChannelCategory> get cachedChannels => _cachedChannels;
  Map<String, List<EpgProgram>> get cachedEpg => _cachedEpg;
  bool get channelsLoaded => _channelsLoaded;
  bool get epgLoaded => _epgLoaded;

  PlaylistSource? get currentPlaylist {
    if (_currentPlaylistId == null) return null;
    try {
      return _playlists.firstWhere((p) => p.id == _currentPlaylistId);
    } catch (_) {
      return null;
    }
  }

  EpgSource? get currentEpg {
    if (_currentEpgId == null) return null;
    try {
      return _epgs.firstWhere((e) => e.id == _currentEpgId);
    } catch (_) {
      return null;
    }
  }

  // ==================== 持久化 ====================

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistStr = prefs.getString(_playlistKey);
    if (playlistStr != null && playlistStr.isNotEmpty) {
      _playlists = PlaylistSource.decodeList(playlistStr);
    }
    _currentPlaylistId = prefs.getString(_currentPlaylistKey);

    final epgStr = prefs.getString(_epgKey);
    if (epgStr != null && epgStr.isNotEmpty) {
      _epgs = EpgSource.decodeList(epgStr);
    }
    _currentEpgId = prefs.getString(_currentEpgKey);
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playlistKey, PlaylistSource.encodeList(_playlists));
    if (_currentPlaylistId != null) {
      await prefs.setString(_currentPlaylistKey, _currentPlaylistId!);
    } else {
      await prefs.remove(_currentPlaylistKey);
    }
  }

  Future<void> _saveEpgs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_epgKey, EpgSource.encodeList(_epgs));
    if (_currentEpgId != null) {
      await prefs.setString(_currentEpgKey, _currentEpgId!);
    } else {
      await prefs.remove(_currentEpgKey);
    }
  }

  // ==================== 播放列表管理 ====================

  /// 添加播放列表源
  Future<void> addPlaylist(PlaylistSource source) async {
    _playlists.add(source);
    await _savePlaylists();
  }

  /// 删除播放列表源
  Future<void> removePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    if (_currentPlaylistId == id) {
      _currentPlaylistId = null;
      _cachedChannels = [];
      _channelsLoaded = false;
    }
    await _savePlaylists();
  }

  /// 选择当前使用的播放列表
  Future<void> selectPlaylist(String? id) async {
    _currentPlaylistId = id;
    await _savePlaylists();
  }

  /// 加载并解析当前播放列表的频道
  Future<List<ChannelCategory>> loadChannels() async {
    final source = currentPlaylist;
    if (source == null) {
      _cachedChannels = [];
      _channelsLoaded = true;
      return [];
    }

    try {
      String content;
      if (source.type == PlaylistSourceType.local) {
        content = await File(source.url).readAsString();
      } else {
        final resp = await http
            .get(Uri.parse(source.url))
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        content = utf8.decode(resp.bodyBytes);
      }

      final format = PlaylistParser.detectFormat(content, source.url);
      _cachedChannels = PlaylistParser.parse(content, format);
      _channelsLoaded = true;

      // 更新最后更新时间
      final idx = _playlists.indexWhere((p) => p.id == source.id);
      if (idx >= 0) {
        _playlists[idx] = source.copyWith(lastUpdated: DateTime.now());
        await _savePlaylists();
      }
    } catch (e) {
      _cachedChannels = [];
      _channelsLoaded = true;
      rethrow;
    }
    return _cachedChannels;
  }

  // ==================== EPG 管理 ====================

  /// 添加 EPG 源
  Future<void> addEpg(EpgSource source) async {
    _epgs.add(source);
    await _saveEpgs();
  }

  /// 删除 EPG 源
  Future<void> removeEpg(String id) async {
    _epgs.removeWhere((e) => e.id == id);
    if (_currentEpgId == id) {
      _currentEpgId = null;
      _cachedEpg = {};
      _epgLoaded = false;
    }
    await _saveEpgs();
  }

  /// 选择当前使用的 EPG
  Future<void> selectEpg(String? id) async {
    _currentEpgId = id;
    await _saveEpgs();
  }

  /// 加载并解析当前 EPG 数据
  Future<Map<String, List<EpgProgram>>> loadEpg() async {
    final source = currentEpg;
    if (source == null) {
      _cachedEpg = {};
      _epgLoaded = true;
      return {};
    }

    try {
      final resp = await http
          .get(Uri.parse(source.url))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }

      // 支持 .gz 压缩的 EPG（按 gzip 魔数 1f 8b 判断，不依赖扩展名）
      final bytes = resp.bodyBytes;
      final body =
          (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)
              ? utf8.decode(GZipDecoder().decodeBytes(bytes))
              : utf8.decode(bytes);
      _cachedEpg = XmltvEpgParser.parse(body);
      _epgLoaded = true;

      final idx = _epgs.indexWhere((e) => e.id == source.id);
      if (idx >= 0) {
        _epgs[idx] = source.copyWith(lastUpdated: DateTime.now());
        await _saveEpgs();
      }
    } catch (e) {
      _cachedEpg = {};
      _epgLoaded = true;
      rethrow;
    }
    return _cachedEpg;
  }

  /// 根据频道获取 EPG 节目列表
  List<EpgProgram> getProgramsForChannel(Channel channel) {
    return XmltvEpgParser.findProgramsForChannel(channel, _cachedEpg);
  }
}
