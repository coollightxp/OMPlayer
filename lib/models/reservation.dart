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

  /// 预约时记录的播放地址（可多个备用源），到点直接播放，
  /// 不依赖当时的播放列表是否还能匹配到该频道
  final List<String> streamUrls;

  /// 预约时记录的台标地址
  final String logoUrl;

  /// EPG 标识与节目单名称（到点后仍可显示对应节目信息）
  final String tvgId;
  final String tvgName;

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
    this.streamUrls = const [],
    this.logoUrl = '',
    this.tvgId = '',
    this.tvgName = '',
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
    List<String>? streamUrls,
    String? logoUrl,
    String? tvgId,
    String? tvgName,
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
      streamUrls: streamUrls ?? this.streamUrls,
      logoUrl: logoUrl ?? this.logoUrl,
      tvgId: tvgId ?? this.tvgId,
      tvgName: tvgName ?? this.tvgName,
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
        'streamUrls': streamUrls,
        'logoUrl': logoUrl,
        'tvgId': tvgId,
        'tvgName': tvgName,
      };

  factory ProgramReservation.fromJson(Map<String, dynamic> json) {
    // streamUrls 新字段；兼容旧版本只有单地址或没有地址
    final raw = json['streamUrls'];
    final urls = raw is List
        ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    return ProgramReservation(
      id: json['id'] as String,
      channelId: json['channelId'] as String,
      channelName: json['channelName'] as String? ?? '',
      programTitle: json['programTitle'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      autoSwitch: json['autoSwitch'] as bool? ?? true,
      autoRecord: json['autoRecord'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      streamUrls: urls,
      logoUrl: json['logoUrl'] as String? ?? '',
      tvgId: json['tvgId'] as String? ?? '',
      tvgName: json['tvgName'] as String? ?? '',
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
