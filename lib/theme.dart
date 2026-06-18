import 'package:flutter/material.dart';

ThemeData buildTheme() {
  const bg = Color(0xFF0D0F12);
  const surface = Color(0xFF161A1F);
  const surfaceVariant = Color(0xFF1E2329);
  const border = Color(0xFF2A3040);
  const accent = Color(0xFF4FC3F7);
  const accentDim = Color(0xFF1A3A4A);
  const textPrimary = Color(0xFFE8EDF2);
  const textSecondary = Color(0xFF7A8899);
  const errorColor = Color(0xFFEF5350);

  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bg,
    colorScheme: const ColorScheme.dark(
      background: bg,
      surface: surface,
      surfaceVariant: surfaceVariant,
      primary: accent,
      primaryContainer: accentDim,
      onPrimary: bg,
      onSurface: textPrimary,
      outline: border,
      error: errorColor,
    ),
    fontFamily: 'monospace',
    appBarTheme: const AppBarTheme(
      backgroundColor: bg,
      foregroundColor: textPrimary,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: textPrimary,
      ),
      iconTheme: IconThemeData(color: textSecondary),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: border, width: 1),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceVariant,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: accent, width: 1.5),
      ),
      labelStyle: const TextStyle(color: textSecondary, fontSize: 13),
      hintStyle: const TextStyle(color: Color(0xFF4A5568), fontSize: 13),
    ),
    dividerTheme: const DividerThemeData(
      color: border,
      thickness: 1,
      space: 0,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: textPrimary, fontSize: 14),
      bodyMedium: TextStyle(color: textPrimary, fontSize: 13),
      bodySmall: TextStyle(color: textSecondary, fontSize: 12),
      labelLarge: TextStyle(
        color: textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
      titleMedium: TextStyle(
        color: textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surfaceVariant,
      contentTextStyle: const TextStyle(color: textPrimary, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: border),
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}