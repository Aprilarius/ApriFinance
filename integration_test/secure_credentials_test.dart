import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/native_cloud_credentials.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native protected store survives reopen, updates and deletes only its fixture',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Проверка защищённого хранилища')),
        ),
      );
      final key =
          'aprifinance.test.credentials.${DateTime.now().microsecondsSinceEpoch}';
      final store = NativeCloudCredentialStore(key: key);
      final initial = jsonEncode({
        'version': 1,
        'session': 'fictional-access-token',
        'refresh': 'fictional-refresh-token',
        'copyPassword': 'fictional-copy-password',
        'padding': 'a' * 12000,
      });
      try {
        expect(await store.read(), isNull);
        await store.write(initial);
        final reopened = NativeCloudCredentialStore(key: key);
        expect(await reopened.read(), initial);
        final rotated = initial.replaceAll(
          'fictional-refresh-token',
          'fictional-rotated-refresh',
        );
        await reopened.write(rotated);
        expect(await NativeCloudCredentialStore(key: key).read(), rotated);
        await reopened.delete();
        expect(await NativeCloudCredentialStore(key: key).read(), isNull);
      } finally {
        await store.delete();
      }
    },
  );
}
