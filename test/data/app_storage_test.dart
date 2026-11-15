import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/app_storage.dart';

void main() {
  test('public Windows rename preserves old database directory', () {
    const root = r'C:\Users\QA\AppData\Roaming\com.bahadur';
    expect(
      ledgerStoragePath('$root\\ApriFinance', windows: true),
      '$root\\personal_finance',
    );
    expect(
      ledgerStoragePath('$root\\personal_finance', windows: true),
      '$root\\personal_finance',
    );
  });
  test('other platforms retain their original support path', () {
    expect(
      ledgerStoragePath(
        '/QA/Library/Application Support/com.bahadur.personalFinance',
        windows: false,
      ),
      '/QA/Library/Application Support/com.bahadur.personalFinance',
    );
  });
}
