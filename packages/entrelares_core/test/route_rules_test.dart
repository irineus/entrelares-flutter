/// The router's S-02 allow-list and the deep-link destination it has to
/// remember across the session gate.
///
/// The invitation case is the one worth the file: an App Link arriving cold is
/// interrupted by the splash, and without the pending destination the visitor
/// ends on the login screen holding a link that appears to do nothing.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  const inviteLink = '/register?invite=11111111-2222-3333-4444-555555555555';

  group('gate phase — nothing renders before we know who you are', () {
    test('the splash stays', () {
      expect(
          RouteRules.redirect(phase: AuthPhase.gate, location: '/splash'),
          isNull);
    });

    test('everything else waits at the splash', () {
      for (final location in ['/', '/register', '/family', '/login']) {
        expect(
            RouteRules.redirect(phase: AuthPhase.gate, location: location),
            '/splash');
      }
    });
  });

  group('anonymous phase', () {
    test('the four public screens are reachable', () {
      for (final location in RouteRules.publicRoutes) {
        expect(
            RouteRules.redirect(phase: AuthPhase.anon, location: location),
            isNull);
      }
    });

    test('anything guarded goes to login', () {
      for (final location in ['/', '/family', '/notifications', '/reports']) {
        expect(
            RouteRules.redirect(phase: AuthPhase.anon, location: location),
            '/login');
      }
    });

    test('a remembered invitation link is restored, query and all', () {
      expect(
        RouteRules.redirect(
            phase: AuthPhase.anon,
            location: '/splash',
            pendingLocation: inviteLink),
        inviteLink,
      );
    });

    test('a remembered GUARDED destination is NOT restored — it still has to '
        'pass through login', () {
      expect(
        RouteRules.redirect(
            phase: AuthPhase.anon,
            location: '/splash',
            pendingLocation: '/family'),
        '/login',
      );
    });

    test('an unparseable pending location falls back to login', () {
      expect(
        RouteRules.redirect(
            phase: AuthPhase.anon,
            location: '/splash',
            pendingLocation: '::not a uri::'),
        '/login',
      );
    });
  });

  group('authenticated phase', () {
    test('the anonymous-only screens hand back to the calendar', () {
      for (final location in RouteRules.anonymousOnlyRoutes) {
        expect(
            RouteRules.redirect(phase: AuthPhase.authed, location: location),
            '/');
      }
    });

    test('a signed-in visitor opening an invitation link lands on the calendar',
        () {
      expect(
          RouteRules.redirect(
              phase: AuthPhase.authed, location: '/register'),
          '/');
    });

    test('/update-password stays reachable — the recovery visitor is signed in',
        () {
      expect(
          RouteRules.redirect(
              phase: AuthPhase.authed, location: '/update-password'),
          isNull);
    });

    test('the app proper stays put', () {
      for (final location in ['/', '/family', '/notifications']) {
        expect(
            RouteRules.redirect(phase: AuthPhase.authed, location: location),
            isNull);
      }
    });
  });

  group('isRestorable', () {
    test('accepts a public path with a query', () {
      expect(RouteRules.isRestorable(inviteLink), isTrue);
    });

    test('refuses a guarded path', () {
      expect(RouteRules.isRestorable('/family'), isFalse);
    });
  });
}
