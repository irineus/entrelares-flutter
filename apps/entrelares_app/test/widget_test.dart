// Foundation sanity: the shell builds and shows the environment. The widget
// tree is built directly (no Supabase.initialize — that needs a platform
// channel); PR 2's slice tests will fake the data layer instead.
import 'package:flutter_test/flutter_test.dart';

import 'package:entrelares_app/main.dart';

void main() {
  testWidgets('foundation screen names the environment', (tester) async {
    await tester.pumpWidget(const EntrelaresApp());
    expect(find.text('Ambiente: Dev/QA'), findsOneWidget);
  });
}
