import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Cosmiq Broadband brand colours — sampled from Logo - Black PDF
class CosmiqColors {
  CosmiqColors._();

  // Primary brand teal (#00CEB3) — buttons, links, accents, call button
  static const Color teal = Color(0xFF00CEB3);

  // Darker teal for pressed states and text on white (#00B89E)
  static const Color tealDark = Color(0xFF00B89E);

  // Surface colours
  static const Color white = Color(0xFFFFFFFF);
  static const Color backgroundSecondary = Color(0xFFF2F2F7);

  // Text colours
  static const Color textPrimary = Color(0xFF000000);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textTertiary = Color(0xFF3C3C43);

  // Semantic colours
  static const Color callGreen = Color(0xFF00CEB3); // brand teal as call btn
  static const Color hangupRed = Color(0xFFFF3B30);
  static const Color missedRed = Color(0xFFFF3B30);
  static const Color registeredGreen = Color(0xFF00CEB3);

  // Separator
  static const Color separator = Color(0x14000000); // rgba(0,0,0,0.08)
  static const Color separatorOpaque = Color(0xFFE5E5EA);

  // In-call screen
  static const Color inCallBg = Color(0xFF1C1C1E);
  static const Color inCallBgEnd = Color(0xFF2C2C2E);
  static const Color inCallButton = Color(0x26FFFFFF); // rgba(255,255,255,0.15)
}

/// App-wide theme built from Cosmiq brand
class CosmiqTheme {
  CosmiqTheme._();

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: CosmiqColors.white,
      colorScheme: const ColorScheme.light(
        primary: CosmiqColors.teal,
        onPrimary: CosmiqColors.textPrimary,
        secondary: CosmiqColors.tealDark,
        surface: CosmiqColors.white,
        onSurface: CosmiqColors.textPrimary,
        error: CosmiqColors.hangupRed,
      ),
      fontFamily: '.SF Pro Text', // falls back to platform default
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: CosmiqColors.white,
        foregroundColor: CosmiqColors.textPrimary,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CosmiqColors.teal,
          foregroundColor: CosmiqColors.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: CosmiqColors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        labelStyle: const TextStyle(
          fontSize: 11,
          color: CosmiqColors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xF0F9F9F9), // rgba(249,249,249,0.94)
        selectedItemColor: CosmiqColors.tealDark,
        unselectedItemColor: CosmiqColors.textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}
