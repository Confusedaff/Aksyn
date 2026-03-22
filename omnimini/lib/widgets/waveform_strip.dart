import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Scrolling bar-graph waveform shown while recording.
/// Fades out when [visible] is false.
///
/// [barHeights] — list of normalised bar heights [0.0 – 1.0], length
///               determines the number of bars rendered.
class WaveformStrip extends StatelessWidget {
  final bool visible;
  final List<double> barHeights;

  const WaveformStrip({
    super.key,
    required this.visible,
    required this.barHeights,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 400),
      opacity: visible ? 1.0 : 0.0,
      child: SizedBox(
        height: 52,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(barHeights.length, (i) {
            final h = barHeights[i];
            final brightness = 0.3 + (i / barHeights.length) * 0.7;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              curve: Curves.easeOut,
              width: 5,
              height: 6 + h * 46,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: AppTheme.accent.withOpacity(brightness),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ),
    );
  }
}
