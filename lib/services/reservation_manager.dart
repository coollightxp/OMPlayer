import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reservation.dart';

/// 节目预约管理服务
/// 负责：预约的增删改查、持久化、定时触发（自动切换/录制）
class ReservationManager {
  static const String _reservationsKey = 'omplayer_reservations';

  List<ProgramReservation> _reservations = [];
  Timer? _checkTimer;
  final Set<String> _triggeredIds = {};
  void Function(ProgramReservation)? onReservationTriggered;

  List<ProgramReservation> get reservations =>
      List.unmodifiable(_reservations);

  /// 加载预约并启动定时检查
  Future<void> init(
      void Function(ProgramReservation) onTriggered) async {
    onReservationTriggered = onTriggered;
    await loadFromPrefs();
    _startCheckTimer();
  }

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_reservationsKey);
    if (str != null && str.isNotEmpty) {
      _reservations = ProgramReservation.decodeList(str);
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _reservationsKey, ProgramReservation.encodeList(_reservations));
  }

  /// 添加预约
  Future<void> addReservation(ProgramReservation r) async {
    _reservations.add(r);
    await _save();
  }

  /// 删除预约
  Future<void> removeReservation(String id) async {
    _reservations.removeWhere((r) => r.id == id);
    _triggeredIds.remove(id);
    await _save();
  }

  /// 切换某个节目的预约状态（存在则删除，不存在则添加）
  Future<bool> toggleReservation(ProgramReservation r) async {
    final existing = _reservations.any((x) =>
        x.channelId == r.channelId &&
        x.startTime.isAtSameMomentAs(r.startTime));
    if (existing) {
      await removeReservation(_reservations
          .firstWhere((x) =>
              x.channelId == r.channelId &&
              x.startTime.isAtSameMomentAs(r.startTime))
          .id);
      return false;
    } else {
      await addReservation(r);
      return true;
    }
  }

  /// 检查某节目是否已预约
  bool isReserved(String channelId, DateTime startTime) {
    return _reservations.any((r) =>
        r.channelId == channelId &&
        r.startTime.isAtSameMomentAs(startTime));
  }

  /// 启动定时检查，每分钟检查一次是否有预约需要触发
  void _startCheckTimer() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkReservations();
    });
  }

  void _checkReservations() {
    final now = DateTime.now();
    for (final r in _reservations) {
      if (_triggeredIds.contains(r.id)) continue;
      // 到达开始时间（允许 1 分钟误差）
      if (now.isAfter(r.startTime.subtract(const Duration(seconds: 30))) &&
          now.isBefore(r.endTime)) {
        _triggeredIds.add(r.id);
        onReservationTriggered?.call(r);
      }
    }
  }

  /// 清理已过期的预约
  Future<void> cleanExpired() async {
    final now = DateTime.now();
    _reservations.removeWhere((r) => r.endTime.isBefore(now));
    await _save();
  }

  void dispose() {
    _checkTimer?.cancel();
  }
}
