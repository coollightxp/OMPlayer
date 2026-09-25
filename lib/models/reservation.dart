import 'dart:convert';

/// 节目预约 - 到时间自动切换播放，可选录制
class ProgramReservation {
  final String id;
  final String channelId;
  final String channelName;
  final String programTitle;
  final DateTime startTime;
  final DateTime endTime;
  final bool autoSwitch;   // 到时间自动切换播放
  final bool autoRecord;   // 到时间自动录制
  final DateTime createdAt;

  const ProgramReservation({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.programTitle,
    required this.startTime,
    required this.endTime,
    this.autoSwitch = true,
    this.autoRecord = false,
    required this.createdAt,
  });

  ProgramReservation copyWith({
    String? id,
    String? channelId,
    String? channelName,
    String? programTitle,
    DateTime? startTime,
    DateTime? endTime,
    bool? autoSwitch,
    bool? autoRecord,
    DateTime? createdAt,
  }) {
    return ProgramReservation(
      id: id ?? this.id,
      channelId: channelId ?? this.channelId,
      channelName: channelName ?? this.channelName,
      programTitle: programTitle ?? this.programTitle,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      autoSwitch: autoSwitch ?? this.autoSwitch,
      autoRecord: autoRecord ?? this.autoRecord,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 是否已触发（开始时间已过）
  bool get isTriggered => DateTime.now().isAfter(startTime);

  /// 是否即将开始（5 分钟内）
  bool get isUpcoming {
    final diff = startTime.difference(DateTime.now());
    return !diff.isNegative && diff.inMinutes <= 5;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'channelId': channelId,
        'channelName': channelName,
        'programTitle': programTitle,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'autoSwitch': autoSwitch,
        'autoRecord': autoRecord,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ProgramReservation.fromJson(Map<String, dynamic> json) {
    return ProgramReservation(
      id: json['id'] as String,
      channelId: json['channelId'] as String,
      channelName: json['channelName'] as String,
      programTitle: json['programTitle'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      autoSwitch: json['autoSwitch'] as bool? ?? true,
      autoRecord: json['autoRecord'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  static String encodeList(List<ProgramReservation> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<ProgramReservation> decodeList(String str) {
    final List<dynamic> decoded = jsonDecode(str) as List<dynamic>;
    return decoded
        .map((e) => ProgramReservation.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
