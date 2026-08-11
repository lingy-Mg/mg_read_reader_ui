import 'package:flutter/material.dart';

import '../api/models.dart';

@immutable
class ReaderPalette {
  const ReaderPalette({
    required this.background,
    required this.text,
    required this.secondaryText,
    required this.panel,
    required this.divider,
    required this.accent,
    required this.systemBrightness,
  });

  final Color background;
  final Color text;
  final Color secondaryText;
  final Color panel;
  final Color divider;
  final Color accent;
  final Brightness systemBrightness;

  static ReaderPalette fromPreset(ReaderThemePreset preset) {
    return switch (preset) {
      ReaderThemePreset.day => const ReaderPalette(
        background: Color(0xFFF7F4EE),
        text: Color(0xFF292824),
        secondaryText: Color(0xFF817D73),
        panel: Color(0xFFFFFCF6),
        divider: Color(0x1F2F2C26),
        accent: Color(0xFFE7683F),
        systemBrightness: Brightness.light,
      ),
      ReaderThemePreset.eyeCare => const ReaderPalette(
        background: Color(0xFFDDE8D5),
        text: Color(0xFF253025),
        secondaryText: Color(0xFF6B7869),
        panel: Color(0xFFE8F0E3),
        divider: Color(0x1F263526),
        accent: Color(0xFF4F7857),
        systemBrightness: Brightness.light,
      ),
      ReaderThemePreset.parchment => const ReaderPalette(
        background: Color(0xFFF1E1BF),
        text: Color(0xFF3B3022),
        secondaryText: Color(0xFF88755B),
        panel: Color(0xFFF7E9CB),
        divider: Color(0x263A2F21),
        accent: Color(0xFF9D5F32),
        systemBrightness: Brightness.light,
      ),
      ReaderThemePreset.night => const ReaderPalette(
        background: Color(0xFF171918),
        text: Color(0xFFB8BCB6),
        secondaryText: Color(0xFF777C77),
        panel: Color(0xFF222523),
        divider: Color(0x267A817B),
        accent: Color(0xFFBF765E),
        systemBrightness: Brightness.dark,
      ),
    };
  }
}

String? readerFontFamily(ReaderFontPreset preset) {
  return switch (preset) {
    ReaderFontPreset.system => null,
    ReaderFontPreset.sansSerif => 'sans-serif',
    ReaderFontPreset.serif => 'serif',
  };
}

List<String> readerFontFallback(ReaderFontPreset preset) {
  return switch (preset) {
    ReaderFontPreset.system => const <String>[
      'Noto Sans CJK SC',
      'Microsoft YaHei',
      'PingFang SC',
    ],
    ReaderFontPreset.sansSerif => const <String>[
      'Noto Sans CJK SC',
      'Microsoft YaHei',
      'PingFang SC',
    ],
    ReaderFontPreset.serif => const <String>[
      'Noto Serif CJK SC',
      'SimSun',
      'Songti SC',
    ],
  };
}
