import 'dart:convert';
import 'package:http/http.dart' as http;

class AuthUser {
  final String id;
  final String role;
  const AuthUser({required this.id, required this.role});

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      AuthUser(id: json['id'] as String, role: json['role'] as String);
}

/// A login/register/refresh response. `expiresAt` is computed once, here,
/// from the server's relative `expires_in` (seconds) — everything
/// downstream compares against a fixed instant instead of re-deriving
/// "relative to when this was issued."
class Session {
  final AuthUser user;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  const Session({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresAt: DateTime.now().add(Duration(seconds: json['expires_in'] as int)),
      );
}

/// One field-level error from a 400 VALIDATION_FAILED response. `path`
/// matches a form field name (`email`, `password`, `full_name`, `phone`).
class FieldError {
  final String path;
  final String message;
  const FieldError(this.path, this.message);
}

/// Unlike [ApiFailure] elsewhere in this app, login/signup forms need to
/// branch on *which* error occurred (wrong password vs. email taken vs.
/// weak password), not just display a message — so this carries the
/// backend's machine-readable `code` and any per-field validation errors
/// alongside the human message.
class AuthFailure implements Exception {
  final String code;
  final String message;
  final List<FieldError> fields;
  const AuthFailure(this.code, this.message, {this.fields = const []});
  @override
  String toString() => message;
}

abstract class AuthRepository {
  Future<Session> register({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  });
  Future<Session> login({required String email, required String password});
  Future<Session> refresh(String refreshToken);
  Future<void> logout({required String accessToken, String? refreshToken, bool allDevices = false});
  Future<void> forgotPassword(String email);
}

class HttpAuthRepository implements AuthRepository {
  HttpAuthRepository({required this.baseUrl, required this.role, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  /// Fixed per app instance — 'customer' here, never user-supplied.
  final String role;
  final http.Client _client;

  static const _headers = {'content-type': 'application/json'};

  @override
  Future<Session> register({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/auth/register'),
          headers: _headers,
          body: jsonEncode({
            'email': email,
            'password': password,
            'full_name': fullName,
            'role': role,
            // Omitted entirely when null — the backend's zod schema treats an
            // absent key differently from an explicit null.
            if (phone != null) 'phone': phone,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 201) throw _problem(res);
    return Session.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<Session> login({required String email, required String password}) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/auth/login'),
          headers: _headers,
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw _problem(res);
    return Session.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<Session> refresh(String refreshToken) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/v1/auth/refresh'),
          headers: _headers,
          body: jsonEncode({'refresh_token': refreshToken}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw _problem(res);
    return Session.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<void> logout({required String accessToken, String? refreshToken, bool allDevices = false}) async {
    // Best-effort — the caller clears local state regardless of the outcome
    // here, so a network failure on logout is never surfaced to the user.
    try {
      await _client
          .post(
            Uri.parse('$baseUrl/v1/auth/logout'),
            headers: {..._headers, 'authorization': 'Bearer $accessToken'},
            body: jsonEncode({
              if (refreshToken != null) 'refresh_token': refreshToken,
              'all_devices': allDevices,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Ignored, deliberately — see comment above.
    }
  }

  @override
  Future<void> forgotPassword(String email) async {
    // The backend always responds 200 {sent:true} regardless of whether the
    // email exists (no account enumeration), so there's nothing to branch on
    // here beyond a genuine network failure, which the caller treats the
    // same as success — the UI never signals whether the address was real.
    try {
      await _client
          .post(
            Uri.parse('$baseUrl/v1/auth/password/forgot'),
            headers: _headers,
            body: jsonEncode({'email': email}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Ignored, deliberately — see comment above.
    }
  }

  AuthFailure _problem(http.Response res) {
    // express-rate-limit's own handler answers 429s, not this app's RFC 9457
    // error middleware — branch on the status before trying to parse a body
    // shape that won't be there.
    if (res.statusCode == 429) {
      return const AuthFailure('RATE_LIMITED', 'Too many attempts. Try again in a few minutes.');
    }
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final meta = body['meta'] as Map<String, dynamic>?;
      final rawFields = meta?['fields'] as List<dynamic>?;
      return AuthFailure(
        body['code'] as String? ?? 'UNKNOWN',
        body['detail'] as String? ?? 'Something went wrong. Try again in a moment.',
        fields: [
          for (final f in rawFields ?? const [])
            FieldError((f as Map)['path'] as String, f['message'] as String),
        ],
      );
    } catch (_) {
      return const AuthFailure('UNKNOWN', 'Something went wrong. Try again in a moment.');
    }
  }
}
