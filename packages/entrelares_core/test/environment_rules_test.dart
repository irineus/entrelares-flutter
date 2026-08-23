import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('environmentTitlePrefix', () {
    test('non-production builds carry the [Dev] tag', () {
      expect(environmentTitlePrefix(isProduction: false), '[Dev] ');
    });

    test('production carries no tag', () {
      expect(environmentTitlePrefix(isProduction: true), '');
    });
  });

  group('isProductionTarget', () {
    test('the Android flavor says prod', () {
      expect(isProductionTarget(flavor: 'prod'), isTrue);
    });

    test('the web define says prod — there is no --flavor on web', () {
      // The whole reason this rule exists: `flutter build web` accepts no
      // flavor, so without the define the production hostname would build
      // against the QA project.
      expect(isProductionTarget(appEnv: 'prod'), isTrue);
    });

    test('a flavor-less, define-less target is dev', () {
      // `flutter test` and any tooling target land here — production is never
      // an accidental target.
      expect(isProductionTarget(), isFalse);
      expect(isProductionTarget(flavor: 'dev'), isFalse);
      expect(isProductionTarget(flavor: null, appEnv: ''), isFalse);
    });

    test('only the exact word counts', () {
      expect(isProductionTarget(flavor: 'production'), isFalse);
      expect(isProductionTarget(appEnv: 'PROD'), isFalse);
    });
  });
}
