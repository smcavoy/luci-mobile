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
        : previous.copyWith(status: report.status, lastError: report.error);
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
      ),
    };
  }

  /// Probes every router in [routers] at once.
  Future<void> probeAll(Iterable<model.Router> routers) =>
      Future.wait(routers.map(probe));
}
