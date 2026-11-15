import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/budget_dialog.dart';
import 'package:personal_finance/ui/dialogs.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/payment_dialogs.dart';
import 'package:personal_finance/ui/purchase_dialog.dart';
import 'package:personal_finance/ui/theme.dart';

import 'design_audit_test.dart' show capture;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final (name, size, scale, inset) in [
    ('keyboard', const Size(320, 568), 1.5, 200.0),
    ('landscape', const Size(844, 390), 1.5, 0.0),
    ('android_large_keyboard', const Size(320, 568), 2.0, 240.0),
  ]) {
    for (final form in [
      'account',
      'entry',
      'budget',
      'payment',
      'purchase',
      'settlement',
    ]) {
      testWidgets('$form form remains scrollable with $name and validation', (
        tester,
      ) async {
        final db = LedgerDatabase(NativeDatabase.memory());
        final repo = FinanceRepository(db);
        await repo.setCurrency('USD');
        await repo.saveAccount(
          name: 'Карта для повседневных покупок и накоплений',
          kind: 'Карта',
          openingMinor: 10000,
        );
        await repo.saveObligation(
          Obligation(
            id: 'form-plan',
            name: 'Подписка',
            kind: EntryKind.expense,
            amountMinor: 100,
            category: 'Подписки',
            anchor: DateTime(2026, 11, 14),
            repeat: RepeatRule.monthly,
          ),
        );
        final vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
        await vm.refresh();
        try {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('audit-preview'),
              child: MaterialApp(
                theme: ledgerTheme(),
                debugShowCheckedModeBanner: false,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: const [Locale('ru')],
                locale: const Locale('ru'),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                    viewInsets: EdgeInsets.only(bottom: inset),
                  ),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => switch (form) {
                          'account' => AccountDialog(vm: vm),
                          'entry' => EntryDialog(vm: vm),
                          'budget' => BudgetDialog(vm: vm),
                          'payment' => ObligationDialog(vm: vm),
                          'settlement' => SettleDialog(
                            vm: vm,
                            obligation: vm.snapshot!.obligations.single,
                          ),
                          _ => PurchaseDialog(vm: vm),
                        },
                      ),
                      child: const Text('Открыть'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Открыть'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture(tester, '${name}_${form}_form');
          if (form == 'settlement') {
            await tester.enterText(find.byKey(const Key('settle-amount')), '');
          }
          final save = find.byType(FilledButton).last;
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(AlertDialog), findsOneWidget);
          final formScrollable = find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Scrollable),
              )
              .first;
          expect(
            tester
                .state<ScrollableState>(formScrollable)
                .position
                .viewportDimension,
            greaterThan(40),
          );
          await tester.drag(formScrollable, const Offset(0, -300));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Отмена'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          vm.dispose();
          await db.close();
        }
      });
    }
  }
}
