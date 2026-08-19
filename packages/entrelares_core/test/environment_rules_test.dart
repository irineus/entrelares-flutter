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
}
