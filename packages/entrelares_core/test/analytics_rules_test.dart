/// The T-37 no-PII contract. Ported case by case from
/// `entrelares-app/Entrelares.Tests/AnalyticsServiceTests.cs`, plus the one
/// case this stack adds: the app routes to a profile by NUMERIC id where the
/// web uses a GUID, and an id that identifies a person must not reach the
/// collector in either shape.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeAnalyticsPath', () {
    test('an empty or blank input is the root', () {
      expect(sanitizeAnalyticsPath(''), '/');
      expect(sanitizeAnalyticsPath('   '), '/');
    });

    test('the invite token NEVER survives', () {
      expect(
        sanitizeAnalyticsPath(
            'https://app.entrelares.app/register?invite=8f14e45f-ceea-467a-9a3e-1e1d1f6f9b1f'),
        '/register',
      );
      expect(sanitizeAnalyticsPath('/register?invite=abc'), '/register');
    });

    test('the recovery fragment NEVER survives', () {
      expect(
        sanitizeAnalyticsPath(
            'https://app.entrelares.app/update-password#access_token=xyz'),
        '/update-password',
      );
    });

    test('a GUID segment is masked', () {
      expect(
        sanitizeAnalyticsPath(
            '/family/profile/8f14e45f-ceea-467a-9a3e-1e1d1f6f9b1f'),
        '/family/profile/:id',
      );
    });

    test('a NUMERIC profile id is masked too — the app routes by id', () {
      expect(sanitizeAnalyticsPath('/family/profile/42'), '/family/profile/:id');
      expect(sanitizeAnalyticsPath('/family/profile/42/'), '/family/profile/:id/');
    });

    test('an absolute URL keeps only its path', () {
      expect(sanitizeAnalyticsPath('https://app.entrelares.app/family'),
          '/family');
      expect(sanitizeAnalyticsPath('https://app.entrelares.app'), '/');
    });

    test('a relative path gains its leading slash', () {
      expect(sanitizeAnalyticsPath('family'), '/family');
    });

    test('an ordinary path passes through untouched', () {
      expect(sanitizeAnalyticsPath('/notifications'), '/notifications');
      expect(sanitizeAnalyticsPath('/'), '/');
    });
  });

  group('analyticsChannel', () {
    test('the app IS the store channel; the web target is the web one', () {
      expect(analyticsChannel(isWeb: false), 'store');
      expect(analyticsChannel(isWeb: true), 'web');
    });
  });

  group('analyticsFunnelProps', () {
    test('channel is always there; the rest only when known', () {
      expect(analyticsFunnelProps(channel: 'store'), {'channel': 'store'});
      expect(
        analyticsFunnelProps(channel: 'web', cycle: 'annual', outcome: 'paid'),
        {'channel': 'web', 'cycle': 'annual', 'outcome': 'paid'},
      );
      expect(analyticsFunnelProps(channel: 'web', mode: 'avulso'),
          {'channel': 'web', 'mode': 'avulso'});
    });
  });
}
