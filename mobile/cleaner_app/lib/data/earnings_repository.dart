import 'dart:convert';
import 'package:http/http.dart' as http;

/// A cleaner's earnings for a window. All money in integer cents.
///
/// `net` is the cleaner's share of the subtotal (commission already removed);
/// tips transfer in full on top. Take-home is the number the cleaner cares
/// about, so the screen leads with it, in amber.
class Earnings {
  final int grossCents; // subtotal booked
  final int commissionCents; // platform's share
  final int netCents; // cleaner's share of the subtotal
  final int tipsCents;
  final int jobs;
  final int? nextPayoutCents;
  final DateTime? nextPayoutArrival;

  const Earnings({
    required this.grossCents,
    required this.commissionCents,
    required this.netCents,
    required this.tipsCents,
    required this.jobs,
    required this.nextPayoutCents,
    required this.nextPayoutArrival,
  });

  int get takeHomeCents => netCents + tipsCents;

  factory Earnings.fromJson(Map<String, dynamic> json) {
    final next = json['next_payout'] as Map<String, dynamic>?;
    final arrival = next?['arrival_date'] as String?;
    return Earnings(
      grossCents: json['gross_cents'] as int? ?? 0,
      commissionCents: json['commission_cents'] as int? ?? 0,
      netCents: json['net_cents'] as int? ?? 0,
      tipsCents: json['tips_cents'] as int? ?? 0,
      jobs: json['jobs'] as int? ?? 0,
      nextPayoutCents: next?['amount_cents'] as int?,
      nextPayoutArrival: arrival != null ? DateTime.parse(arrival) : null,
    );
  }
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

abstract class EarningsRepository {
  Future<Earnings> fetch({DateTime? from, DateTime? to});
}

class HttpEarningsRepository implements EarningsRepository {
  HttpEarningsRepository({required this.baseUrl, required this.tokenProvider, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final http.Client _client;

  @override
  Future<Earnings> fetch({DateTime? from, DateTime? to}) async {
    final query = <String, String>{
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
    };
    final uri = Uri.parse('$baseUrl/v1/cleaner/earnings').replace(queryParameters: query.isEmpty ? null : query);
    final res = await _client.get(uri, headers: {
      'authorization': 'Bearer ${await tokenProvider()}',
      'content-type': 'application/json',
    }).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    return Earnings.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  String _detail(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return 'Could not load earnings. Pull down to retry.';
    }
  }
}
