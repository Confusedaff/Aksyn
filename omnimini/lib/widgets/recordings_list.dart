import 'package:flutter/material.dart';
import 'app_theme.dart';
import '../services/supabase_service.dart';

// ─────────────────────────────────────────────────────────────────
// RECORDINGS LIST
// ─────────────────────────────────────────────────────────────────

/// Renders the section header and one tile per entry in [recordings].
/// Entries are either [RecordingMeta] or [PendingRecording].
class RecordingsList extends StatelessWidget {
  final List<dynamic> recordings;
  final int? playingIndex;
  final double playbackProgress;
  final Duration playbackPosition;
  final Duration playbackTotal;
  final void Function(RecordingMeta meta, int index) onPlay;
  final void Function(RecordingMeta meta) onTap;

  const RecordingsList({
    super.key,
    required this.recordings,
    required this.playingIndex,
    required this.playbackProgress,
    required this.playbackPosition,
    required this.playbackTotal,
    required this.onPlay,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final realCount = recordings.whereType<RecordingMeta>().length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Text('RECORDINGS',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
            )),
        SizedBox(width: 14),
        Expanded(child: Divider(color: AppTheme.border, height: 1)),
      ]),
      const SizedBox(height: 14),
      ...List.generate(recordings.length, (i) {
        final rec = recordings[i];
        if (rec is PendingRecording) return const PendingTile(key: ValueKey('pending'));

        final meta = rec as RecordingMeta;
        final recNumber = realCount -
            recordings.whereType<RecordingMeta>().toList().indexOf(meta);

        return RecordingTile(
          key: ValueKey(meta.fileName),
          meta: meta,
          index: i,
          recNumber: recNumber,
          isPlaying: playingIndex == i,
          playbackProgress: playingIndex == i ? playbackProgress : 0.0,
          playbackPosition: playingIndex == i ? playbackPosition : Duration.zero,
          playbackTotal: playingIndex == i && playbackTotal > Duration.zero
              ? playbackTotal
              : meta.duration,
          onPlay: () => onPlay(meta, i),
          onTap: () => onTap(meta),
        );
      }),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────
// PENDING TILE
// ─────────────────────────────────────────────────────────────────

/// Spinner row shown while a recording is still being processed/uploaded.
class PendingTile extends StatelessWidget {
  const PendingTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.gold.withOpacity(0.3), width: 1),
      ),
      child: const Row(children: [
        SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(color: AppTheme.gold, strokeWidth: 2),
        ),
        SizedBox(width: 14),
        Text('Processing & uploading…',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// RECORDING TILE
// ─────────────────────────────────────────────────────────────────

/// A single saved-recording card with play/stop button and progress bar.
class RecordingTile extends StatelessWidget {
  final RecordingMeta meta;
  final int index;
  final int recNumber;
  final bool isPlaying;
  final double playbackProgress;
  final Duration playbackPosition;
  final Duration playbackTotal;
  final VoidCallback onPlay;
  final VoidCallback onTap;

  const RecordingTile({
    super.key,
    required this.meta,
    required this.index,
    required this.recNumber,
    required this.isPlaying,
    required this.playbackProgress,
    required this.playbackPosition,
    required this.playbackTotal,
    required this.onPlay,
    required this.onTap,
  });

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isPlaying ? AppTheme.accent.withOpacity(0.07) : AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isPlaying
                  ? AppTheme.accent.withOpacity(0.35)
                  : AppTheme.border,
              width: 1),
        ),
        child: Column(children: [
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: _LeadingIcon(isPlaying: isPlaying),
            title: _TileTitle(
                recNumber: recNumber, alertCount: meta.alertCount),
            subtitle: _TileSubtitle(
              dateLabel: meta.dateLabel,
              isPlaying: isPlaying,
              position: playbackPosition,
              total: playbackTotal,
              formatFn: _fmt,
            ),
            trailing: _PlayButton(
              isPlaying: isPlaying,
              hasUrl: meta.publicUrl.isNotEmpty,
              onTap: onPlay,
            ),
          ),
          _PlaybackBar(
            isPlaying: isPlaying,
            progress: playbackProgress,
            position: playbackPosition,
            total: playbackTotal,
            formatFn: _fmt,
          ),
        ]),
      ),
    );
  }
}

// ── Private sub-widgets kept local to this file ───────────────────

class _LeadingIcon extends StatelessWidget {
  final bool isPlaying;
  const _LeadingIcon({required this.isPlaying});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        color: isPlaying ? AppTheme.accentGlow : AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isPlaying
                ? AppTheme.accent.withOpacity(0.4)
                : AppTheme.border,
            width: 1),
      ),
      child: Icon(Icons.audiotrack_rounded,
          color: isPlaying ? AppTheme.accent : AppTheme.textSecondary,
          size: 19),
    );
  }
}

class _TileTitle extends StatelessWidget {
  final int recNumber;
  final int alertCount;
  const _TileTitle({required this.recNumber, required this.alertCount});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text('Recording $recNumber',
          style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14)),
      if (alertCount > 0) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$alertCount alert${alertCount > 1 ? 's' : ''}',
            style: const TextStyle(
                color: AppTheme.accent,
                fontSize: 10,
                fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ]);
  }
}

class _TileSubtitle extends StatelessWidget {
  final String dateLabel;
  final bool isPlaying;
  final Duration position;
  final Duration total;
  final String Function(Duration) formatFn;

  const _TileSubtitle({
    required this.dateLabel,
    required this.isPlaying,
    required this.position,
    required this.total,
    required this.formatFn,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Text(dateLabel,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 11)),
        const SizedBox(width: 6),
        Text(
          isPlaying
              ? '${formatFn(position)} / ${formatFn(total)}'
              : formatFn(total),
          style: TextStyle(
            color: isPlaying ? AppTheme.accent : AppTheme.textSecondary,
            fontSize: 11,
            fontWeight:
                isPlaying ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        const Spacer(),
        const Icon(Icons.chevron_right_rounded,
            color: AppTheme.textSecondary, size: 16),
      ]),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool isPlaying;
  final bool hasUrl;
  final VoidCallback onTap;

  const _PlayButton({
    required this.isPlaying,
    required this.hasUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: isPlaying ? AppTheme.accent : AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: isPlaying ? AppTheme.accent : AppTheme.border,
              width: 1),
        ),
        child: Icon(
          isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
          color: isPlaying ? Colors.white : AppTheme.textSecondary,
          size: 20,
        ),
      ),
    );
  }
}

class _PlaybackBar extends StatelessWidget {
  final bool isPlaying;
  final double progress;
  final Duration position;
  final Duration total;
  final String Function(Duration) formatFn;

  const _PlaybackBar({
    required this.isPlaying,
    required this.progress,
    required this.position,
    required this.total,
    required this.formatFn,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      child: isPlaying
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: AppTheme.border,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(formatFn(position),
                          style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                      Text(formatFn(total),
                          style: const TextStyle(
                              color: AppTheme.textSecondary, fontSize: 10)),
                    ]),
              ]),
            )
          : const SizedBox.shrink(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// PLACEHOLDER MODEL (kept with its UI peer)
// ─────────────────────────────────────────────────────────────────

/// Placeholder inserted into the recordings list while a new clip is
/// still being processed and uploaded.
class PendingRecording {}
