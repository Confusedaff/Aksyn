import 'package:flutter/material.dart';
import 'app_theme.dart';
import '../screens/audio_recorder_screen.dart' show RecordingStatus;

/// Animated pill that reflects the current [RecordingStatus].
class StatusChip extends StatelessWidget {
  final RecordingStatus status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      RecordingStatus.recording => ('● LIVE  ·  ANALYSING', AppTheme.accent),
      RecordingStatus.uploading => ('↑  SAVING…',           AppTheme.gold),
      RecordingStatus.uploaded  => ('✓  SAVED',             AppTheme.green),
      _                         => ('○  READY',             AppTheme.textSecondary),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: Container(
        key: ValueKey(status),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withOpacity(0.22), width: 1),
        ),
        child: Text(label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.5,
            )),
      ),
    );
  }
}
