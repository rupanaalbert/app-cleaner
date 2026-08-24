import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'data/booking_repository.dart';
import 'features/booking/booking_flow_screen.dart';

void main() => runApp(const SparkleCustomerApp());

class SparkleCustomerApp extends StatelessWidget {
  const SparkleCustomerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Swap for HttpBookingRepository(baseUrl: ..., tokenProvider: ...) once
    // auth is wired. The fake mirrors the real pricing rules so the flow can
    // be demoed and widget-tested without a backend.
    return MaterialApp(
      title: 'Sparkle',
      theme: Sparkle.theme(),
      debugShowCheckedModeBanner: false,
      home: BookingFlowScreen(
        repository: FakeBookingRepository(),
        propertyId: '018f0000-0000-7000-8000-000000000001',
        addressLine: '14 Pleasant St, Methuen',
      ),
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
