import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final (name, size, scale) in [
    ('purchase_calendar_desktop', const Size(1100, 1000), 1.0),
    ('purchase_calendar_phone', const Size(390, 844), 1.5),
  ]) {
    testWidgets(
      '$name shows deadlines and opens matching card without changing money',
      (tester) async {
        final db = LedgerDatabase(NativeDatabase.memory());
        final repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
        await repo.setCurrency('USD');
        await repo.saveAccount(
          name: 'Карта',
          kind: 'Карта',
          openingMinor: 10000,
        );
        await repo.savePurchase(
          Purchase(
            id: 'p',
            name: 'Наушники',
            amountMinor: 3000,
            date: DateTime(2026, 11, 14),
            returnBy: DateTime(2026, 11, 21),
            warrantyUntil: DateTime(2026, 12, 31),
          ),
        );
        final vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
        await vm.refresh();
        try {
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: FinanceApp(viewModel: vm),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('nav-3')));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Возврат и гарантия'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(
            MediaQuery.textScalerOf(
              tester.element(find.text('Возврат и гарантия')),
            ).scale(10),
            scale * 10,
          );
          expect(find.textContaining('21.11.2026 · Наушники'), findsOneWidget);
          expect(find.textContaining('Окончание гарантии'), findsNothing);
          await expectLater(
            find.byType(FinanceApp),
            matchesGoldenFile('../goldens/$name.png'),
          );
          await tester.scrollUntilVisible(
            find.text('Открыть карточку'),
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Открыть карточку'));
          await tester.pumpAndSettle();
          expect(find.text('Карточка покупки'), findsOneWidget);
          expect(
            tester
                .widget<TextFormField>(find.byKey(const Key('purchase-name')))
                .controller!
                .text,
            'Наушники',
          );
          expect(vm.totalBalance, 10000);
          expect(vm.snapshot!.entries, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          vm.dispose();
          await db.close();
        }
      },
    );
  }
}
