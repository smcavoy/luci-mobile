import 'package:flutter/foundation.dart';

/// What the app currently knows about whether a saved router is usable.
enum RouterHealthStatus {
  /// Nothing has been tried yet.
  unknown,

  /// A liveness probe is in flight.
  checking,

  /// The router answered.
  online,

  /// The router did not answer at all: down, out of range, or on a network
  /// the phone is not on.
  unreachable,

  /// The router answered and refused the sign-in.
  authFailed,
}

/// One router's health, with when it was last seen answering.
@immutable
class RouterHealth {
  const RouterHealth({
    this.status = RouterHealthStatus.unknown,
    this.lastSeen,
    this.lastError,
  });

  final RouterHealthStatus status;

  /// The last time the router answered. Survives a later failure, so an
  /// unreachable router can still say "last seen 5 min ago".
  final DateTime? lastSeen;

  /// The error behind the latest failure, cleared once the router answers.
  final Object? lastError;

  bool get isUsable => status == RouterHealthStatus.online;

  RouterHealth copyWith({
    RouterHealthStatus? status,
    DateTime? lastSeen,
    Object? lastError,
    bool clearError = false,
  }) => RouterHealth(
    status: status ?? this.status,
    lastSeen: lastSeen ?? this.lastSeen,
    lastError: clearError ? null : lastError ?? this.lastError,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RouterHealth &&
          other.status == status &&
          other.lastSeen == lastSeen &&
          other.lastError == lastError;

  @override
  int get hashCode => Object.hash(status, lastSeen, lastError);

  @override
  String toString() => 'RouterHealth($status, lastSeen: $lastSeen)';
}

/// A health observation made where there is no provider container:
/// `AppState` reports these as it logs in and fetches, and the health
/// notifier listens.
@immutable
class RouterHealthReport {
  const RouterHealthReport(this.routerId, this.status, {this.error});

  final String routerId;
  final RouterHealthStatus status;
  final Object? error;
}
