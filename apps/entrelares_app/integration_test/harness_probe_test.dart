// TEMPORÁRIO (spike T-56 PR 5): prova que o arnês web sabe REPROVAR.
// Um `flutter drive` que imprime "All tests passed" sem ter executado nada é
// indistinguível de um verde legítimo — este arquivo torna a diferença visível.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sonda: este teste PASSA', (tester) async {
    expect(1 + 1, 2);
  });

  testWidgets('sonda: este teste FALHA de propósito', (tester) async {
    expect(1, 2, reason: 'se o run ficar verde, o arnês não executa nada');
  });
}
