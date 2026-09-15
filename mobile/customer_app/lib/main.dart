import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/theme.dart';
import 'data/auth_controller.dart';
import 'data/auth_repository.dart';
import 'data/booking_repository.dart';
import 'features/auth/login_screen.dart';
import 'features/booking/booking_flow_screen.dart';
import 'l10n/sparkle_strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Spanish (and every other non-English intl locale) throws at first use
  // unless its date-symbol data is loaded first — English is bundled and
  // needs no call, which is why this was never missed before.
  await initializeDateFormatting();
  runApp(const SparkleCustomerApp());
}

// 10.0.2.2 is the Android emulator's alias for the host machine's localhost —
// `npm run dev` in backend/ needs to already be running there.
const _devApiBaseUrl = 'http://10.0.2.2:8080';

class SparkleCustomerApp extends StatefulWidget {
  const SparkleCustomerApp({super.key});

  @override
  State<SparkleCustomerApp> createState() => _SparkleCustomerAppState();
}

class _SparkleCustomerAppState extends State<SparkleCustomerApp> {
  late final AuthController _auth;

  @override
  void initState() {
    super.initState();
    _auth = AuthController(
      repository: HttpAuthRepository(baseUrl: _devApiBaseUrl, role: 'customer'),
    );
    _auth.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale?>(
      valueListenable: localeOverride,
      builder: (context, locale, _) => ValueListenableBuilder<AuthState>(
        valueListenable: _auth.state,
        builder: (context, authState, __) => MaterialApp(
          title: 'Sparkle',
          theme: Sparkle.theme(),
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: const [
            SparkleStringsDelegate(),
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: SparkleStrings.supportedLocales,
          home: switch (authState) {
            AuthUnknown() => const _SplashScreen(),
            AuthSignedOut() => LoginScreen(auth: _auth),
            AuthSignedIn() => BookingFlowScreen(
                repository: HttpBookingRepository(baseUrl: _devApiBaseUrl, tokenProvider: _auth.tokenProvider),
                // Whichever machine's `npm run seed` produced this doesn't
                // match every database — a real property picker is still a
                // separate, pre-existing gap unrelated to auth.
                propertyId: '01a035ac-a36f-7425-aa64-ab3dc61924b8',
                addressLine: '10 Pleasant St, Methuen',
                auth: _auth,
              ),
          },
        ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Sparkle.marine,
      body: Center(child: CircularProgressIndicator(color: Sparkle.seafoam)),
    );
  }
}

/// Mirrors backend/src/services/pricing.service.js so the numbers on screen
/// match what the API would return.
class FakeBookingRepository implements BookingRepository {
  int _n = 0;

  @override
  Future<Quote> requestQuote(BookingDraft draft) async {
    await Future<void>.delayed(const Duration(milliseconds: 350));

    const base = 4900, perBed = 1200, perBath = 1500;
    final sizeTier = switch (draft.squareFeet) {
      null => 0,
      final s when s <= 1000 => 0,
      final s when s <= 1500 => 800,
      final s when s <= 2000 => 1500,
      final s when s <= 3000 => 2800,
      _ => 4500,
    };
    final addonCents = draft.addonCodes
        .map((c) => AddonOption.catalog.firstWhere((a) => a.code == c).priceCents)
        .fold(0, (a, b) => a + b);

    final pre = base + draft.bedrooms * perBed + draft.bathrooms * perBath + sizeTier + addonCents;
    final serviceBps = draft.serviceCode == 'deep' ? 16000 : 10000;
    final afterService = (pre * serviceBps / 10000).round();

    final when = draft.scheduledAt!;
    final multipliers = <Map<String, dynamic>>[];
    var demandBps = 10000;
    if (when.weekday == DateTime.saturday || when.weekday == DateTime.sunday) {
      multipliers.add({'code': 'weekend', 'factor_bps': 11500});
      demandBps = (demandBps * 11500 / 10000).round();
    }
    if (when.hour >= 17) {
      multipliers.add({'code': 'evening', 'factor_bps': 11000});
      demandBps = (demandBps * 11000 / 10000).round();
    }
    demandBps = math.min(demandBps, 15000);

    final subtotal = (afterService * demandBps / 10000).round();
    final tsFee = math.min(349 + (subtotal * 0.01).round(), 999);

    final baseMinutes = draft.serviceCode == 'deep' ? 180 : 90;
    final duration = ((baseMinutes + draft.bedrooms * 20 + draft.bathrooms * 25) / 15).ceil() * 15;

    return Quote.fromJson({
      'quote_id': 'q_${_n++}',
      'expires_at': DateTime.now().add(const Duration(minutes: 15)).toUtc().toIso8601String(),
      'duration_min': duration,
      'total_cents': subtotal + tsFee,
      'breakdown': {
        'base_cents': base,
        'bedrooms': {'count': draft.bedrooms, 'cents': draft.bedrooms * perBed},
        'bathrooms': {'count': draft.bathrooms, 'cents': draft.bathrooms * perBath},
        'size_tier_cents': sizeTier,
        'addons': [
          for (final code in draft.addonCodes)
            {'code': code, 'cents': AddonOption.catalog.firstWhere((a) => a.code == code).priceCents},
        ],
        'multipliers': multipliers,
        'subtotal_cents': subtotal,
        'trust_safety_fee_cents': tsFee,
      },
    });
  }

  @override
  Future<PaypalOrder> createPaypalOrder(String quoteId) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // No real PayPal to redirect through in the demo build — see
    // kDemoApprovedPaypalUrl's doc comment.
    return PaypalOrder(orderId: 'order_fake_$quoteId', approveUrl: kDemoApprovedPaypalUrl);
  }

  @override
  Future<ConfirmedBooking> confirm({
    required String quoteId,
    required String paypalOrderId,
    required BookingDraft draft,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return ConfirmedBooking(
      id: 'b_1',
      reference: 'SPK-8J4K2Q',
      status: 'pending_match',
      scheduledAt: draft.scheduledAt!,
      totalCents: 15449,
    );
  }
}
