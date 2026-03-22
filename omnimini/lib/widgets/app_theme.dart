import 'package:flutter/material.dart';

/// Central place for all app colours and shared theme constants.
/// Import this wherever you need colours instead of redefining them.
abstract final class AppTheme {
  static const bg            = Color(0xFF0A0A0F);
  static const surface       = Color(0xFF13131A);
  static const card          = Color(0xFF1C1C27);
  static const accent        = Color(0xFFE8375A);
  static const accentGlow    = Color(0x44E8375A);
  static const gold          = Color(0xFFF5C842);
  static const green         = Color(0xFF4ADE80);
  static const textPrimary   = Color(0xFFF0F0F5);
  static const textSecondary = Color(0xFF6B6B80);
  static const border        = Color(0xFF2A2A38);
}
