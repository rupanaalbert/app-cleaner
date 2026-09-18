import 'dart:convert';
import 'package:http/http.dart' as http;

/// A customer's saved home — one address plus the property details tied to
/// it. The booking flow only ever needs [id] and [shortAddress]; the rest is
/// carried for a future "manage my addresses" screen.
class Property {
  final String id;
  final String line1;
  final String? line2;
  final String city;
  final String region;
  final String postalCode;
  final String? accessNotes;

  const Property({
    required this.id,
    required this.line1,
    this.line2,
    required this.city,
    required this.region,
    required this.postalCode,
    this.accessNotes,
  });

  /// Matches the format `main.dart` used for its old hardcoded literal —
  /// what's shown in the booking flow's AppBar.
  String get shortAddress => '$line1, $city';

  factory Property.fromJson(Map<String, dynamic> json) => Property(
        id: json['id'] as String,
        line1: json['line1'] as String,
        line2: json['line2'] as String?,
        city: json['city'] as String,
        region: json['region'] as String,
        postalCode: json['postal_code'] as String,
        accessNotes: json['access_notes'] as String?,
      );
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

abstract class PropertyRepository {
  Future<List<Property>> list();
  Future<Property> create({
    required String line1,
    String? line2,
    required String city,
    required String region,
    required String postalCode,
    String? accessNotes,
  });
}

class HttpPropertyRepository implements PropertyRepository {
  HttpPropertyRepository({required this.baseUrl, required this.tokenProvider, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Future<String> Function() tokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await tokenProvider()}',
        'content-type': 'application/json',
      };

  @override
  Future<List<Property>> list() async {
    final res = await _client
        .get(Uri.parse('$baseUrl/v1/properties'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw ApiFailure(_detail(res));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final p in body['properties'] as List) Property.fromJson(p as Map<String, dynamic>),
    ];
  }

  @override
  Future<Property> create({
    required String line1,
    String? line2,
    required String city,
    required String region,
    required String postalCode,
    String? accessNotes,
  }) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/properties'),
          headers: await _headers(),
          body: jsonEncode({
            'line1': line1,
            if (line2 != null) 'line2': line2,
            'city': city,
            'region': region,
            'postal_code': postalCode,
            if (accessNotes != null) 'access_notes': accessNotes,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 201) throw ApiFailure(_detail(res));
    return Property.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  String _detail(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return 'Something went wrong. Try again in a moment.';
    }
  }
}
