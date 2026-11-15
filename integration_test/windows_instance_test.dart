import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'second native Windows process exits before opening another application',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      expect(Platform.environment['APRIFINANCE_NATIVE_TEST'], '1');
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Тест одного экземпляра'))),
      );
      await tester.pumpAndSettle();
      final child = await Process.start(Platform.resolvedExecutable, const []);
      try {
        final code = await child.exitCode.timeout(const Duration(seconds: 10));
        expect(code, 0);
      } finally {
        child.kill();
      }
    },
  );
}
