import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Top app bar showing the VŌICE logo and a clip counter.
class RecorderHeader extends StatelessWidget {
  final int clipCount;

  const RecorderHeader({super.key, required this.clipCount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: AppTheme.accentGlow,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: AppTheme.accent.withOpacity(0.4), width: 1),
          ),
          child: const Icon(Icons.graphic_eq_rounded, color: AppTheme.accent, size: 20),
        ),
        const SizedBox(width: 12),
        const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Ōmnimini', style: TextStyle(color: AppTheme.textPrimary, fontSize: 17,
              fontWeight: FontWeight.w800, letterSpacing: 5)),
          Text('live detector', style: TextStyle(color: AppTheme.textSecondary,
              fontSize: 9, letterSpacing: 3.5)),
        ]),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.border),
          ),
          child: Text('$clipCount clips',
              style: const TextStyle(color: AppTheme.textSecondary,
                  fontSize: 12, letterSpacing: 0.5)),
        ),
      ]),
    );
  }
}
