import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_repository.dart';

const _kRefreshTokenKey = 'sparkle_refresh_token';

sealed class AuthState {
  const AuthState();
}

/// Cold start — still checking secure storage / attempting a silent refresh.
class AuthUnknown extends AuthState {
  const AuthUnknown();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

class AuthSignedIn extends AuthState {
  const AuthSignedIn(this.user);
  final AuthUser user;
}

/// Owns the session lifecycle and — this is the part every existing
/// repository actually depends on — hands out the `Future<String> Function()`
/// closure they all already take as `tokenProvider`. Every repository call
/// this app makes ultimately calls [tokenProvider], which transparently
/// refreshes the access token when it's stale rather than requiring any
/// repository to know about auth at all.
class AuthController {
  AuthController({required this.repository, FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final AuthRepository repository;
  final FlutterSecureStorage _storage;

  final ValueNotifier<AuthState> state = ValueNotifier(const AuthUnknown());

  Session? _session;
  Future<Session>? _inFlightRefresh;

  /// Drop-in replacement for the old `_devTokenProvider` — same signature,
  /// so no repository file needs to change, only what's passed as its
  /// `tokenProvider:` argument in main.dart.
  Future<String> tokenProvider() async {
    final s = _session;
    if (s != null && s.expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return s.accessToken;
    }
    return (await _refresh()).accessToken;
  }

  /// Dedupes concurrent refresh attempts into one in-flight call. This
  /// matters because the refresh token is single-use: if two repository
  /// calls both find a stale access token at the same moment, they must
  /// share one refresh rather than each presenting the stored refresh token
  /// separately — the second presentation of an already-used token revokes
  /// the whole token family server-side.
  Future<Session> _refresh() {
    return _inFlightRefresh ??= _doRefresh().whenComplete(() => _inFlightRefresh = null);
  }

  Future<Session> _doRefresh() async {
    final stored = await _storage.read(key: _kRefreshTokenKey);
    if (stored == null) {
      state.value = const AuthSignedOut();
      throw const AuthFailure('UNAUTHENTICATED', 'Not signed in.');
    }
    try {
      final next = await repository.refresh(stored);
      await _storage.write(key: _kRefreshTokenKey, value: next.refreshToken);
      _session = next;
      state.value = AuthSignedIn(next.user);
      return next;
    } on AuthFailure {
      // Expired, reused, or revoked — the whole family is dead server-side.
      await _storage.delete(key: _kRefreshTokenKey);
      _session = null;
      state.value = const AuthSignedOut();
      rethrow;
    }
  }

  /// Call once, at app start.
  Future<void> bootstrap() async {
    final stored = await _storage.read(key: _kRefreshTokenKey);
    if (stored == null) {
      state.value = const AuthSignedOut();
      return;
    }
    try {
      await _doRefresh();
    } catch (_) {
      // _doRefresh already set state to AuthSignedOut on failure.
    }
  }

  Future<void> login(String email, String password) async {
    final s = await repository.login(email: email, password: password);
    await _storage.write(key: _kRefreshTokenKey, value: s.refreshToken);
    _session = s;
    state.value = AuthSignedIn(s.user);
  }

  Future<void> register({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async {
    final s = await repository.register(
      email: email, password: password, fullName: fullName, phone: phone,
    );
    await _storage.write(key: _kRefreshTokenKey, value: s.refreshToken);
    _session = s;
    state.value = AuthSignedIn(s.user);
  }

  Future<void> logout({bool allDevices = false}) async {
    final s = _session;
    if (s != null) {
      await repository.logout(
        accessToken: s.accessToken, refreshToken: s.refreshToken, allDevices: allDevices,
      );
    }
    await _storage.delete(key: _kRefreshTokenKey);
    _session = null;
    state.value = const AuthSignedOut();
  }
}
