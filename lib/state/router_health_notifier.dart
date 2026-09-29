import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/models/router.dart' as model;
import 'package:luci_mobile/models/router_health.dart';
import 'package:luci_mobile/services/router_liveness_probe.dart';
import 'package:luci_mobile/state/app_state_provider.dart';

/// The probe used to check saved routers. Overridable in tests.
final routerLivenessProbeProvider = Provider<IRouterLivenessProbe>(
  (ref) => const RouterLivenessProbe(),
);

/// Health of every saved router, by router id.
///
/// Two things feed it: what `AppState` learns from real logins and fetches,
/// and [RouterHealthNotifier.probeAll], which asks each router whether it is
/// answering without signing in. Routers with no entry are simply unknown.
final routerHealthProvider =
    NotifierProvider<RouterHealthNotifier, Map<String, RouterHealth>>(
      RouterHealthNotifier.new,
    );

class RouterHealthNotifier extends Notifier<Map<String, RouterHealth>> {
  @override
  Map<String, RouterHealth> build() {
    // Read, not watched: `AppState` notifies on nearly every change, and
    // rebuilding here would throw the collected health away each time.
    final sub = ref.read(appStateProvider).routerHealthReports.listen(_apply);
    ref.onDispose(sub.cancel);
    return const {};
  }

  @visibleForTesting
  void debugReport(RouterHealthReport report) => _apply(report);

  void _apply(RouterHealthReport report) {
    final previous = state[report.routerId] ?? const RouterHealth();
    final next = report.status == RouterHealthStatus.online
        ? previous.copyWith(
            status: RouterHealthStatus.online,
            lastSeen: DateTime.now(),
            clearError: true,
          )
        // Overwrites the error, null included: a refused sign-in must not
        // inherit the connection error of an earlier outage.
        : RouterHealth(
            status: report.status,
            lastSeen: previous.lastSeen,
            lastError: report.error,
          );
    state = {...state, report.routerId: next};
  }

  /// Checks whether [router] answers, on either of its addresses.
  ///
  /// A probe sends no credentials, so it can show a router is up but not that
  /// signing in works: a router already known to refuse the sign-in stays
  /// that way. A real login or fetch that reports while the probe is in
  /// flight is newer and wins.
  Future<void> probe(model.Router router) async {
    final id = router.id;
    final before = state[id] ?? const RouterHealth();
    // One probe per router at a time; a second would read `checking` as the
    // prior status and lose what the first knew.
    if (before.status == RouterHealthStatus.checking) return;
    state = {
      ...state,
      id: before.copyWith(status: RouterHealthStatus.checking),
    };

    final probe = ref.read(routerLivenessProbeProvider);
    var reachable = await probe.isReachable(
      router.activeAddress,
      router.activeUseHttps,
    );
    if (!reachable && router.hasFallback) {
      reachable = await probe.isReachable(
        router.inactiveAddress!,
        router.inactiveUseHttps!,
      );
    }

    if (!ref.mounted) return;
    final current = state[id];
    if (current == null || current.status != RouterHealthStatus.checking) {
      return;
    }
    final status = !reachable
        ? RouterHealthStatus.unreachable
        : before.status == RouterHealthStatus.authFailed
        ? RouterHealthStatus.authFailed
        : RouterHealthStatus.online;
    state = {
      ...state,
      id: current.copyWith(
        status: status,
        lastSeen: reachable ? DateTime.now() : null,
        clearError: status == RouterHealthStatus.online,
      ),
    };
  }

  /// Probes every saved router in [routers] at once, and forgets any router
  /// that is no longer among them, so a deleted router's status is not
  /// inherited by one later added under the same id.
  Future<void> probeAll(Iterable<model.Router> routers) {
    final ids = {for (final r in routers) r.id};
    state = {
      for (final e in state.entries)
        if (ids.contains(e.key)) e.key: e.value,
    };
    return Future.wait(routers.map(probe));
  }
}
