import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/app_failure.dart';
import 'package:luci_mobile/models/router.dart' as model;
import 'package:luci_mobile/models/router_health.dart';
import 'package:luci_mobile/services/interfaces/auth_service_interface.dart';
import 'package:luci_mobile/services/api_service.dart';
import 'package:luci_mobile/services/auth_service.dart';
import 'package:luci_mobile/services/mock_api_service.dart';
import 'package:luci_mobile/services/mock_auth_service.dart';
import 'package:luci_mobile/services/router_liveness_probe.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/state/app_state_provider.dart';
import 'package:luci_mobile/state/router_health_notifier.dart';

model.Router _router({String id = 'r1', String? alternate}) => model.Router(
  id: id,
  ipAddress: '192.168.1.1',
  username: 'root',
  password: 'pw',
  useHttps: false,
  alternateAddress: alternate,
  alternateUseHttps: alternate == null ? null : false,
);

DioException _dio(DioExceptionType type) => DioException(
  requestOptions: RequestOptions(path: '/cgi-bin/luci/'),
  type: type,
);

/// Answers per address; an address it does not know is down.
class _FakeProbe implements IRouterLivenessProbe {
  _FakeProbe(this.up, {this.gate});

  final Set<String> up;
  final Completer<void>? gate;
  final asked = <String>[];

  @override
  Future<bool> isReachable(String hostWithPort, bool useHttps) async {
    asked.add(hostWithPort);
    await gate?.future;
    return up.contains(hostWithPort);
  }
}

/// Fails every login the way the test says.
class _ThrowingApi extends MockApiService {
  _ThrowingApi(this.errors);

  final List<Object?> errors;
  var _n = 0;

  @override
  Future<String> login(
    String ipAddress,
    String username,
    String password,
    bool useHttps, {
    context,
  }) async {
    throw errors[_n++ % errors.length]!;
  }
}

class _FailingAuth extends MockAuthService {
  _FailingAuth(this.cause);

  final Object? cause;

  @override
  Future<FallbackLoginResult> loginWithFallback({
    required String activeAddress,
    required bool activeHttps,
    required int activeIndex,
    String? fallbackAddress,
    bool? fallbackHttps,
    required String username,
    required String password,
    context,
  }) async => FallbackLoginResult(
    success: false,
    usedAddressIndex: activeIndex,
    cause: cause,
  );
}

class _SelectedAppState extends AppState {
  _SelectedAppState(IAuthService auth, this.router)
    : super.forTesting(apiService: MockApiService(), authService: auth);

  final model.Router router;

  @override
  model.Router? get selectedRouter => router;
}

void main() {
  group('RealAuthService reports why a login failed', () {
    Future<FallbackLoginResult> login(
      List<Object?> errors, {
      bool withFallback = false,
    }) => RealAuthService(_ThrowingApi(errors)).loginWithFallback(
      activeAddress: '192.168.1.1',
      activeHttps: false,
      activeIndex: 0,
      fallbackAddress: withFallback ? '10.0.0.1' : null,
      fallbackHttps: withFallback ? false : null,
      username: 'root',
      password: 'pw',
    );

    test('a single address that does not answer is unreachable', () async {
      final result = await login([_dio(DioExceptionType.connectionTimeout)]);
      expect(result.success, isFalse);
      expect(isRouterUnreachable(result.cause!), isTrue);
    });

    test('both addresses not answering is unreachable', () async {
      final result = await login([
        _dio(DioExceptionType.connectionError),
        const SocketException('refused'),
      ], withFallback: true);
      expect(isRouterUnreachable(result.cause!), isTrue);
    });

    test('an address that answered makes the router up', () async {
      final result = await login([
        _dio(DioExceptionType.connectionError),
        _dio(DioExceptionType.badResponse),
      ], withFallback: true);
      expect(result.cause, isA<DioException>());
      expect(
        (result.cause! as DioException).type,
        DioExceptionType.badResponse,
      );
    });
  });

  group('AppState classifies a failed login', () {
    for (final (name, cause, kind, status) in [
      (
        'not answering',
        const SocketException('refused'),
        AppFailureKind.unreachable,
        RouterHealthStatus.unreachable,
      ),
      (
        'answering and refusing',
        null,
        AppFailureKind.login,
        RouterHealthStatus.authFailed,
      ),
      (
        'answering with an error the app rejected',
        _dio(DioExceptionType.badResponse),
        AppFailureKind.login,
        RouterHealthStatus.authFailed,
      ),
    ]) {
      test(name, () async {
        final state = _SelectedAppState(_FailingAuth(cause), _router());
        addTearDown(state.dispose);
        final reports = <RouterHealthReport>[];
        state.routerHealthReports.listen(reports.add);

        final ok = await state.login(
          '192.168.1.1',
          'root',
          'pw',
          false,
          fromRouter: true,
        );
        await Future<void>.delayed(Duration.zero);

        expect(ok, isFalse);
        expect(state.loginFailure?.kind, kind);
        expect(reports.single.routerId, 'r1');
        expect(reports.single.status, status);
      });
    }

    test('a thrown network error is unreachable', () async {
      final state = _SelectedAppState(
        _ThrowingAuth(const SocketException('down')),
        _router(),
      );
      addTearDown(state.dispose);

      await state.login('192.168.1.1', 'root', 'pw', false, fromRouter: true);

      expect(state.loginFailure?.kind, AppFailureKind.unreachable);
    });
  });

  group('RouterHealthNotifier', () {
    late AppState appState;

    ProviderContainer container({_FakeProbe? probe, AppState? state}) {
      appState =
          state ??
          AppState.forTesting(
            apiService: MockApiService(),
            authService: MockAuthService(),
          );
      final c = ProviderContainer(
        overrides: [
          appStateProvider.overrideWith((ref) => appState),
          if (probe != null)
            routerLivenessProbeProvider.overrideWithValue(probe),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    RouterHealth? health(ProviderContainer c, [String id = 'r1']) =>
        c.read(routerHealthProvider)[id];

    test('a router nobody has checked has no entry', () {
      expect(health(container()), isNull);
    });

    test('an unreachable router keeps when it was last seen', () async {
      final c = container();
      final notifier = c.read(routerHealthProvider.notifier);

      notifier.debugReport(
        const RouterHealthReport('r1', RouterHealthStatus.online),
      );
      final seen = health(c)!.lastSeen;
      expect(seen, isNotNull);

      final error = const SocketException('down');
      notifier.debugReport(
        RouterHealthReport('r1', RouterHealthStatus.unreachable, error: error),
      );
      expect(health(c)!.status, RouterHealthStatus.unreachable);
      expect(health(c)!.lastSeen, seen);
      expect(health(c)!.lastError, error);

      notifier.debugReport(
        const RouterHealthReport('r1', RouterHealthStatus.online),
      );
      expect(health(c)!.lastError, isNull);
    });

    test('a refused sign-in does not inherit an earlier outage error', () {
      final c = container();
      final notifier = c.read(routerHealthProvider.notifier);
      notifier.debugReport(
        const RouterHealthReport(
          'r1',
          RouterHealthStatus.unreachable,
          error: SocketException('down'),
        ),
      );
      notifier.debugReport(
        const RouterHealthReport('r1', RouterHealthStatus.authFailed),
      );
      expect(health(c)!.status, RouterHealthStatus.authFailed);
      expect(health(c)!.lastError, isNull);
    });

    test('a probe that finds the router answering clears its error', () async {
      final c = container(probe: _FakeProbe({'192.168.1.1'}));
      final notifier = c.read(routerHealthProvider.notifier);
      notifier.debugReport(
        const RouterHealthReport(
          'r1',
          RouterHealthStatus.unreachable,
          error: SocketException('down'),
        ),
      );
      await notifier.probe(_router());
      expect(health(c)!.status, RouterHealthStatus.online);
      expect(health(c)!.lastError, isNull);
    });

    test('a second probe while one is running is ignored', () async {
      final gate = Completer<void>();
      final probe = _FakeProbe({'192.168.1.1'}, gate: gate);
      final c = container(probe: probe);
      final notifier = c.read(routerHealthProvider.notifier);
      notifier.debugReport(
        const RouterHealthReport('r1', RouterHealthStatus.authFailed),
      );

      final first = notifier.probe(_router());
      await notifier.probe(_router());
      gate.complete();
      await first;

      expect(probe.asked, ['192.168.1.1']);
      expect(health(c)!.status, RouterHealthStatus.authFailed);
    });

    test('probeAll forgets routers that are no longer saved', () async {
      final c = container(probe: _FakeProbe({'192.168.1.1'}));
      final notifier = c.read(routerHealthProvider.notifier);
      notifier.debugReport(
        const RouterHealthReport('gone', RouterHealthStatus.authFailed),
      );
      await notifier.probeAll([_router()]);
      expect(health(c, 'gone'), isNull);
      expect(health(c)!.status, RouterHealthStatus.online);
    });

    test('probing an answering router marks it online', () async {
      final c = container(probe: _FakeProbe({'192.168.1.1'}));
      await c.read(routerHealthProvider.notifier).probe(_router());
      expect(health(c)!.status, RouterHealthStatus.online);
      expect(health(c)!.lastSeen, isNotNull);
    });

    test('probing a silent router marks it unreachable', () async {
      final c = container(probe: _FakeProbe({}));
      await c.read(routerHealthProvider.notifier).probe(_router());
      expect(health(c)!.status, RouterHealthStatus.unreachable);
      expect(health(c)!.lastSeen, isNull);
    });

    test('the fallback address is tried when the primary is silent', () async {
      final probe = _FakeProbe({'10.0.0.1'});
      final c = container(probe: probe);
      await c
          .read(routerHealthProvider.notifier)
          .probe(_router(alternate: '10.0.0.1'));
      expect(probe.asked, ['192.168.1.1', '10.0.0.1']);
      expect(health(c)!.status, RouterHealthStatus.online);
    });

    test('a probe cannot clear a refused sign-in', () async {
      final c = container(probe: _FakeProbe({'192.168.1.1'}));
      final notifier = c.read(routerHealthProvider.notifier);
      notifier.debugReport(
        const RouterHealthReport('r1', RouterHealthStatus.authFailed),
      );
      await notifier.probe(_router());
      expect(health(c)!.status, RouterHealthStatus.authFailed);
    });

    test('a report made during a probe is newer and wins', () async {
      final gate = Completer<void>();
      final c = container(probe: _FakeProbe({}, gate: gate));
      final notifier = c.read(routerHealthProvider.notifier);

      final probing = notifier.probe(_router());
      expect(health(c)!.status, RouterHealthStatus.checking);
      notifier.debugReport(
        const RouterHealthReport('r1', RouterHealthStatus.online),
      );
      gate.complete();
      await probing;

      expect(health(c)!.status, RouterHealthStatus.online);
    });

    test('AppState reports reach the provider', () async {
      final c = container(
        state: _SelectedAppState(
          _FailingAuth(const SocketException('down')),
          _router(),
        ),
      );
      c.read(routerHealthProvider);

      await appState.login(
        '192.168.1.1',
        'root',
        'pw',
        false,
        fromRouter: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(health(c)!.status, RouterHealthStatus.unreachable);
    });
  });
}

class _ThrowingAuth extends MockAuthService {
  _ThrowingAuth(this.error);

  final Object error;

  @override
  Future<FallbackLoginResult> loginWithFallback({
    required String activeAddress,
    required bool activeHttps,
    required int activeIndex,
    String? fallbackAddress,
    bool? fallbackHttps,
    required String username,
    required String password,
    context,
  }) async => throw error;
}
