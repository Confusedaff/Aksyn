import 'package:flutter/material.dart';
import 'app_theme.dart';
import '../services/supabase_service.dart';

// ─────────────────────────────────────────────────────────────────
// ERROR BANNER
// ─────────────────────────────────────────────────────────────────

/// Inline warning strip shown when service initialisation fails.
class ErrorBanner extends StatelessWidget {
  final String message;

  const ErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.accent.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accent.withOpacity(0.25)),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded,
            color: AppTheme.accent, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// ALERTS BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────

/// Modal bottom sheet listing all [AlertMeta] rows for a recording.
class AlertsSheet extends StatelessWidget {
  final RecordingMeta recording;
  final Future<List<AlertMeta>> alertsFuture;

  const AlertsSheet({
    super.key,
    required this.recording,
    required this.alertsFuture,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          _Handle(),
          _SheetHeader(recording: recording),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Divider(color: AppTheme.border),
          ),
          Expanded(child: _AlertList(
            alertsFuture: alertsFuture,
            controller: controller,
          )),
        ]),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      width: 40, height: 4,
      decoration: BoxDecoration(
          color: AppTheme.border,
          borderRadius: BorderRadius.circular(2)),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  final RecordingMeta recording;
  const _SheetHeader({required this.recording});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accent.withOpacity(0.3)),
          ),
          child: const Icon(Icons.warning_amber_rounded,
              color: AppTheme.accent, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Alerts · ${recording.fileName.split('_').last.replaceAll('.wav', '')}',
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(recording.dateLabel,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
          ]),
        ),
        _AlertCountBadge(count: recording.alertCount),
      ]),
    );
  }
}

class _AlertCountBadge extends StatelessWidget {
  final int count;
  const _AlertCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final hasAlerts = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: hasAlerts
            ? AppTheme.accent.withOpacity(0.1)
            : AppTheme.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: hasAlerts
                ? AppTheme.accent.withOpacity(0.3)
                : AppTheme.border),
      ),
      child: Text(
        '$count alert${count != 1 ? 's' : ''}',
        style: TextStyle(
          color: hasAlerts ? AppTheme.accent : AppTheme.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AlertList extends StatelessWidget {
  final Future<List<AlertMeta>> alertsFuture;
  final ScrollController controller;

  const _AlertList({required this.alertsFuture, required this.controller});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AlertMeta>>(
      future: alertsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: AppTheme.accent));
        }
        final alerts = snap.data ?? [];
        if (alerts.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    color: AppTheme.green.withOpacity(0.5), size: 48),
                const SizedBox(height: 12),
                const Text('No alerts detected',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 14)),
              ],
            ),
          );
        }
        return ListView.builder(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          itemCount: alerts.length,
          itemBuilder: (_, i) => _AlertRow(alert: alerts[i]),
        );
      },
    );
  }
}

class _AlertRow extends StatelessWidget {
  final AlertMeta alert;
  const _AlertRow({required this.alert});

  @override
  Widget build(BuildContext context) {
    final color = alert.isKeyword ? AppTheme.accent : AppTheme.gold;
    final icon  = alert.isKeyword
        ? Icons.record_voice_over_rounded
        : Icons.volume_up_rounded;
    final t = alert.triggeredAt.toLocal();
    final timeStr =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2), width: 1),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(alert.label.toUpperCase(),
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5)),
              ),
              Text(timeStr,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 10)),
            ]),
            const SizedBox(height: 2),
            Text(alert.source,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
            if (alert.transcript != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Text('"${alert.transcript}"',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontStyle: FontStyle.italic)),
              ),
            ],
          ]),
        ),
        if (alert.confidence != null) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(alert.confidenceLabel,
                style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    );
  }
}
