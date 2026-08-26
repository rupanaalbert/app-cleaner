import 'package:flutter/material.dart';

/// Customer-side tokens.
///
/// Same brand marine as the cleaner app, different job. The cleaner app sells
/// urgency (take this job now); this one sells calm and honesty about price.
/// So: quieter surfaces, seafoam for the single forward action, and the price
/// ledger rendered in ink rather than an accent colour — a booking total that
/// glows at you reads like a sales pitch, not a receipt.
class Sparkle {
  static const marine = Color(0xFF0E3A45);
  static const marineDeep = Color(0xFF082630);
  static const linen = Color(0xFFF4F7F6); // page background
  static const surface = Color(0xFFFFFFFF);
  static const seafoam = Color(0xFF12A088); // the one forward action
  static const seafoamSoft = Color(0xFFE2F2EE); // selected states
  static const clay = Color(0xFFC4553D); // errors, destructive
  static const inkStrong = Color(0xFF0B1F26);
  static const ink = Color(0xFF33484F);
  static const inkSoft = Color(0xFF6B8087);
  static const hairline = Color(0xFFDCE7E4);

  static const s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 24.0, s6 = 32.0;
  static const radius = 16.0;

  // Depth for surfaces that should read as tappable/liftable rather than flat
  // — a card, not a form row. Same low-alpha marine tint as PriceLedger's
  // existing shadow, just softer, so the whole app shares one shadow color.
  static const cardShadow = [
    BoxShadow(color: Color(0x0F0E3A45), blurRadius: 14, offset: Offset(0, 3)),
  ];
  static const selectedShadow = [
    BoxShadow(color: Color(0x2612A088), blurRadius: 18, offset: Offset(0, 5)),
  ];
  static const heroShadow = [
    BoxShadow(color: Color(0x1F0E3A45), blurRadius: 28, offset: Offset(0, 10)),
  ];
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [seafoamSoft, surface],
  );

  static ThemeData theme() => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: linen,
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: marine,
          primary: marine,
          secondary: seafoam,
          error: clay,
          surface: surface,
        ),
        textTheme: const TextTheme(
          displaySmall: TextStyle(
            fontFamily: 'Archivo', fontSize: 30, fontWeight: FontWeight.w800,
            letterSpacing: -0.6, height: 1.05, color: inkStrong,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          titleLarge: TextStyle(
            fontFamily: 'Archivo', fontSize: 22, fontWeight: FontWeight.w600,
            letterSpacing: -0.4, color: inkStrong, height: 1.2,
          ),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: inkStrong),
          bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: ink),
          labelSmall: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.9, color: inkSoft,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: seafoam,
            foregroundColor: Colors.white,
            disabledBackgroundColor: hairline,
            disabledForegroundColor: inkSoft,
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      );
}
