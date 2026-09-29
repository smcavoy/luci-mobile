import 'package:flutter/material.dart';

/// Result of a login attempt with fallback.
class FallbackLoginResult {
  final bool success;
  final int usedAddressIndex; // 0 = primary, 1 = alternate

  /// The error a failed login ended with, when there was one. Null when the
  /// router answered without a session - a refused sign-in. It is not
  /// necessarily unreachability: classify it with `isRouterUnreachable`.
  final Object? cause;

  FallbackLoginResult({
    required this.success,
    required this.usedAddressIndex,
    this.cause,
  });
}

abstract class IAuthService {
  Future<void> login(
    String ipAddress,
    String username,
    String password,
    bool useHttps, {
    BuildContext? context,
  });

  /// Try active address first, then fallback to the other.
  Future<FallbackLoginResult> loginWithFallback({
    required String activeAddress,
    required bool activeHttps,
    required int activeIndex,
    String? fallbackAddress,
    bool? fallbackHttps,
    required String username,
    required String password,
    BuildContext? context,
  });

  Future<bool> tryAutoLogin(
    String? ipAddress,
    String? username,
    String? password,
    bool? useHttps, {
    BuildContext? context,
  });
  Future<void> logout();
  Future<bool> checkRouterAvailability(
    String ipAddress,
    bool useHttps, {
    BuildContext? context,
  });

  String? get sysauth;
  String? get ipAddress;
  bool get useHttps;
  bool get isAuthenticated;
}
