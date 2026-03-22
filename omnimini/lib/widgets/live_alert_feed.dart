import 'package:flutter/material.dart';
import 'app_theme.dart';
import '../services/live_detection_service.dart';

/// Shows up to 5 of the most recent [DetectionAlert]s during a live recording.
class LiveAlertFeed extends StatelessWidget {
  final List<DetectionAlert> alerts;

  const LiveAlertFeed({super.key, required this.alerts});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Text('LIVE DETECTIONS',
            style: TextStyle(
              color: AppTheme.accent,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
            )),
        SizedBox(width: 14),
        Expanded(child: Divider(color: AppTheme.border)),
      ]),
      const SizedBox(height: 10),
      ...alerts.take(5).map(_AlertTile.new),
      const SizedBox(height: 16),
    ]);
  }
}

/// A single compact alert row used inside [LiveAlertFeed].
class _AlertTile extends StatelessWidget {
  final DetectionAlert alert;

  const _AlertTile(this.alert);

  @override
  Widget build(BuildContext context) {
    final color = alert.isKeyword ? AppTheme.accent : AppTheme.gold;
    final icon  = alert.isKeyword
        ? Icons.record_voice_over_rounded
        : Icons.volume_up_rounded;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25), width: 1),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(alert.label.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                )),
            if (alert.transcript != null)
              Text('"${alert.transcript}"',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (alert.confidence != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(alert.confidenceLabel,
                style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ),
      ]),
    );
  }
}
