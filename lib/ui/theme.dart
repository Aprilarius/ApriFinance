import 'package:material_ui/material_ui.dart';

abstract final class LedgerColors {
  static const paper = Color(0xFFF6F7F4);
  static const ink = Color(0xFF202A24);
  static const green = Color(0xFF25634A);
  static const muted = Color(0xFF657169);
  static const expense = Color(0xFFAE463C);
  static const line = Color(0xFFE1E6E0);
}

ThemeData ledgerTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: LedgerColors.green,
    surface: LedgerColors.paper,
  );
  return ThemeData(
    fontFamily: 'NotoSans',
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: LedgerColors.paper,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        color: LedgerColors.ink,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: LedgerColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: LedgerColors.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: LedgerColors.ink),
      bodyMedium: TextStyle(fontSize: 14, color: LedgerColors.ink),
      bodySmall: TextStyle(fontSize: 12, color: LedgerColors.muted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      errorMaxLines: 3,
      filled: true,
      fillColor: const Color(0xFFF0F3EE),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: LedgerColors.line, space: 24),
  );
}
