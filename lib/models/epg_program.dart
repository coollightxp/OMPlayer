import 'package:intl/intl.dart';

/// EPG 节目条目 - 电子节目指南中的单个节目
class EpgProgram {
  final String id;
  final String channelId;
  final String title;
  final String description;
  final DateTime startTime;
  final DateTime endTime;
  final String? posterUrl;

  const EpgProgram({
    required this.id,
    required this.channelId,
    required this.title,
    this.description = '',
    required this.startTime,
    required this.endTime,
    this.posterUrl,
  });

  /// 节目时长（分钟）
  int get durationInMinutes =>
      endTime.difference(startTime).inMinutes;

  /// 是否正在播放
  bool get isNowPlaying {
    final now = DateTime.now();
    return now.isAfter(startTime) && now.isBefore(endTime);
  }

  /// 是否已经播放过
  bool get isPast => DateTime.now().isAfter(endTime);

  /// 是否尚未开始
  bool get isUpcoming => DateTime.now().isBefore(startTime);

  /// 格式化的开始时间
  String get startTimeFormatted =>
      DateFormat('HH:mm').format(startTime);

  /// 格式化的结束时间
  String get endTimeFormatted =>
      DateFormat('HH:mm').format(endTime);

  /// 节目时间段显示
  String get timeRange => '$startTimeFormatted - $endTimeFormatted';

  /// 计算当前播放进度 (0.0 - 1.0)
  double get progress {
    if (!isNowPlaying) return isPast ? 1.0 : 0.0;
    final total = endTime.difference(startTime).inMilliseconds;
    if (total <= 0) return 0.0;
    final elapsed =
        DateTime.now().difference(startTime).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  EpgProgram copyWith({
    String? id,
    String? channelId,
    String? title,
    String? description,
    DateTime? startTime,
    DateTime? endTime,
    String? posterUrl,
  }) {
    return EpgProgram(
      id: id ?? this.id,
      channelId: channelId ?? this.channelId,
      title: title ?? this.title,
      description: description ?? this.description,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      posterUrl: posterUrl ?? this.posterUrl,
    );
  }
}

/// 当前正在播放的节目信息（用于底部面板显示）
class NowPlayingInfo {
  final String channelName;
  final String programTitle;
  final String? nextProgramTitle;
  final DateTime? programStartTime;
  final DateTime? programEndTime;

  const NowPlayingInfo({
    required this.channelName,
    required this.programTitle,
    this.nextProgramTitle,
    this.programStartTime,
    this.programEndTime,
  });

  static const empty = NowPlayingInfo(
    channelName: '',
    programTitle: '',
  );

  bool get isEmpty => channelName.isEmpty && programTitle.isEmpty;

  /// 节目时间段显示，如 "19:00 - 19:30"
  String? get timeRange {
    if (programStartTime == null || programEndTime == null) return null;
    final fmt = DateFormat('HH:mm');
    return '${fmt.format(programStartTime!)} - ${fmt.format(programEndTime!)}';
  }
}
