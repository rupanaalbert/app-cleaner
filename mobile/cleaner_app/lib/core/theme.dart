import 'package:flutter/material.dart';

/// Design tokens for the cleaner app.
///
/// This app is used one-handed, outdoors, in a parked car, often in sunlight.
/// So: deep marine ground for contrast, one warm accent reserved exclusively
/// for money, and type large enough to read at a glance. Amber appears nowhere
/// except payouts — when a cleaner scans the screen, the gold number is always
/// the number they care about.
class Sparkle {
  // Palette
  static const marine = Color(0xFF0E3A45); // primary ground, headers
  static const marineDeep = Color(0xFF082630); // pressed states, scrims
  static const mist = Color(0xFFEDF4F2); // app background
  static const surface = Color(0xFFFFFFFF);
  static const payout = Color(0xFFE9A020); // money, and only money
  static const seafoam = Color(0xFF1FA98F); // positive/confirm
  static const clay = Color(0xFFC4553D); // expiring, destructive
  static const inkStrong = Color(0xFF0B1F26);
  static const ink = Color(0xFF33484F);
  static const inkSoft = Color(0xFF6B8087);
  static const hairline = Color(0xFFD7E3E0);
  static const seafoamSoft = Color(0xFFE2F2EE); // selected/success states

  // Spacing scale — 4pt base, no arbitrary values in widgets.
  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 24.0, s6 = 32.0;
  static const radius = 18.0;

  // Depth for surfaces that should read as tappable/liftable rather than flat
  // — a card, not a form row. Same low-alpha marine tint used across all
  // three surfaces (job_discovery's expiry card, the customer app, admin).
  static const cardShadow = [
    BoxShadow(color: Color(0x0F0E3A45), blurRadius: 14, offset: Offset(0, 3)),
  ];
  static const heroShadow = [
    BoxShadow(color: Color(0x1F0E3A45), blurRadius: 28, offset: Offset(0, 10)),
  ];
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFEF6E8), surface],
  );

  static ThemeData theme() {
    const display = 'Archivo';
    const body = 'Inter';

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: mist,
      colorScheme: ColorScheme.fromSeed(
        seedColor: marine,
        primary: marine,
        secondary: seafoam,
        error: clay,
        surface: surface,
      ),
      fontFamily: body,
      textTheme: const TextTheme(
        // Money and headline numbers: tabular figures so digits don't jitter
        // as a countdown ticks or a list re-sorts.
        displaySmall: TextStyle(
          fontFamily: display, fontSize: 34, fontWeight: FontWeight.w800,
          letterSpacing: -0.8, height: 1.0, fontFeatures: [FontFeature.tabularFigures()],
        ),
        titleLarge: TextStyle(
          fontFamily: display, fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: inkStrong),
        bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: ink),
        labelSmall: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: inkSoft,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: marine,
          minimumSize: const Size.fromHeight(52), // thumb-sized, always
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
