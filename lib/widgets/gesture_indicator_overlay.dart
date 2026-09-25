import 'package:flutter/material.dart';

/// 亮度/音量调节指示覆盖层
/// 显示在屏幕中央，包含图标和进度条
class GestureIndicatorOverlay extends StatelessWidget {
  final bool isVisible;
  final IconData icon;
  final Color iconColor;
  final double value; // 0.0 - 1.0
  final String label;

  const GestureIndicatorOverlay({
    super.key,
    required this.isVisible,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: isVisible ? 1.0 : 0.0,
        child: Center(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: iconColor, size: 44),
                const SizedBox(height: 12),
                // 进度条
                SizedBox(
                  width: 160,
                  height: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: value.clamp(0.0, 1.0),
                      backgroundColor: Colors.white24,
                      valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
