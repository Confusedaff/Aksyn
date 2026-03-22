import 'package:flutter/material.dart';
import 'app_theme.dart';

/// The large circular record / stop button with animated glow rings.
///
/// [isRecording]  — true while audio is being captured.
/// [isUploading]  — true while waiting for the server "done" message;
///                  tapping is disabled and a spinner is shown instead of an icon.
/// [amplitude]    — normalised microphone level [0.0 – 1.0], drives the glow.
/// [pulseAnim]    — outer pulse ring animation (scale tween 1.0 → 1.12).
/// [onTap]        — called when the button is pressed (start or stop).
class RecordButton extends StatelessWidget {
  final bool isRecording;
  final bool isUploading;
  final double amplitude;
  final Animation<double> pulseAnim;
  final VoidCallback onTap;

  const RecordButton({
    super.key,
    required this.isRecording,
    required this.isUploading,
    required this.amplitude,
    required this.pulseAnim,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 240, height: 240,
        child: Stack(alignment: Alignment.center, children: [
          if (isRecording) ...[
            // Amplitude-reactive outer ring
            AnimatedBuilder(
              animation: pulseAnim,
              builder: (_, __) => Transform.scale(
                scale: 1.0 + (amplitude * 0.25),
                child: Container(
                  width: 210, height: 210,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: AppTheme.accent.withOpacity(0.15 + amplitude * 0.4),
                        width: 1.5),
                  ),
                ),
              ),
            ),
            // Slow pulse ring
            AnimatedBuilder(
              animation: pulseAnim,
              builder: (_, __) => Transform.scale(
                scale: pulseAnim.value,
                child: Container(
                  width: 190, height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: AppTheme.accent.withOpacity(0.1), width: 1),
                  ),
                ),
              ),
            ),
          ],

          // Static outer ring (border tracks recording state)
          AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: 180, height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.surface,
              border: Border.all(
                  color: isRecording
                      ? AppTheme.accent.withOpacity(0.3 + amplitude * 0.5)
                      : AppTheme.border,
                  width: 1.5),
              boxShadow: isRecording
                  ? [BoxShadow(
                      color: AppTheme.accent.withOpacity(0.1 + amplitude * 0.35),
                      blurRadius: 20 + amplitude * 40,
                      spreadRadius: amplitude * 8,
                    )]
                  : [],
            ),
          ),

          // Tappable inner button
          GestureDetector(
            onTap: isUploading ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width:  isRecording ? (108 + amplitude * 12) : 118,
              height: isRecording ? (108 + amplitude * 12) : 118,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isRecording ? AppTheme.accent : AppTheme.card,
                border: Border.all(
                    color: isRecording
                        ? AppTheme.accent.withOpacity(0.7)
                        : AppTheme.border,
                    width: 2),
                boxShadow: isRecording
                    ? [BoxShadow(
                        color: AppTheme.accent.withOpacity(0.3 + amplitude * 0.4),
                        blurRadius: 20 + amplitude * 30,
                        spreadRadius: 2 + amplitude * 6,
                      )]
                    : [BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 20,
                      )],
              ),
              child: isUploading
                  ? const SizedBox(
                      width: 28, height: 28,
                      child: CircularProgressIndicator(
                          color: AppTheme.gold, strokeWidth: 2),
                    )
                  : Icon(
                      isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                      color: isRecording ? Colors.white : AppTheme.textSecondary,
                      size: 50,
                    ),
            ),
          ),
        ]),
      ),
    );
  }
}
