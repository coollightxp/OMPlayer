import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/player_controller.dart';

/// 安卓面板缩放因子：按屏幕【最短边】判断设备形态
/// （手机横屏时宽度是长边，不能按宽度判）。
/// - 手机（最短边 < 600）：0.72
/// - 小平板（600 ~ 700）：0.9
/// - 大平板 / 安卓 TV / 桌面：1.0
double panelScaleOf(BuildContext context) {
  final shortest = MediaQuery.of(context).size.shortestSide;
  if (shortest < 600) return 0.72;
  if (shortest < 700) return 0.9;
  return 1.0;
}

/// 面板【整体】等比缩放。
///
/// 与只改 textScaler（字小框大）不同：child 先以设计宽度 [designWidth]
/// 布局，再用 Transform.scale 把外框/内边距/图标/文字一起等比缩小，
/// 命中区域同步缩放。
///
/// 面板内文字只受用户在设置里的「界面缩放」(uiScale) 控制，
/// 形态缩放全部交给 Transform，避免与 app.dart 的全局缩放叠加。
class ScaledPanel extends StatelessWidget {
  /// 设计稿宽度（child 按此宽度布局）
  final double designWidth;

  /// 缩放对齐方向：左抽屉 centerLeft、右抽屉 centerRight、
  /// 底部面板 bottomCenter
  final Alignment alignment;

  /// 缩放因子（用 [panelScaleOf] 获取）
  final double scale;

  final Widget child;

  const ScaledPanel({
    super.key,
    required this.designWidth,
    required this.alignment,
    required this.scale,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final settings = context.watch<PlayerController>().settings;
    // 面板内只保留用户自己的界面缩放设置
    final userScale =
        settings.uiScaleAuto ? 1.0 : settings.uiScale.clamp(0.8, 3.0);
    Widget content = MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(userScale)),
      child: child,
    );
    if (scale == 1.0) return content;
    // OverflowBox：让 child 以设计宽度布局（忽略被缩小的实际宽度），
    // 高度约束沿用父级；再整体 Transform 缩放
    return OverflowBox(
      minWidth: designWidth,
      maxWidth: designWidth,
      alignment: alignment,
      child: Transform.scale(
        scale: scale,
        alignment: alignment,
        child: content,
      ),
    );
  }
}
