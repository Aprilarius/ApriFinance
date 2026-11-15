import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LedgerDatabase db;
  late FinanceRepository repo;
  late FinanceViewModel vm;

  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
    await repo.setCurrency('USD');
    await repo.saveAccount(
      name: 'Основная карта',
      kind: 'Карта',
      openingMinor: 240000,
    );
    await repo.saveAccount(
      name: 'Наличные',
      kind: 'Наличные',
      openingMinor: 10000,
    );
    vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
    await vm.refresh();
  });

  tearDown(() async {
    vm.dispose();
    await db.close();
  });

  testWidgets('form rejects zero, saves expense and updates balance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FinanceApp(viewModel: vm));
    await tester.pumpAndSettle();
    expect(find.text('2\u00a0500,00 USD'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('entry-amount')), '0');
    await tester.ensureVisible(find.byKey(const Key('save-entry')));
    await tester.tap(find.byKey(const Key('save-entry')));
    await tester.pumpAndSettle();
    expect(find.text('Сумма должна быть больше нуля'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('entry-amount')), '12,50');
    await tester.tap(find.byKey(const Key('save-entry')));
    await tester.runAsync(() async {
      for (var i = 0; i < 30 && vm.snapshot!.entries.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(vm.snapshot!.entries.single.amountMinor, 1250);
    expect(find.text('2\u00a0487,50 USD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new account form persists entered opening balance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FinanceApp(viewModel: vm));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Счета').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-account')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account-name')), 'Резерв');
    await tester.enterText(find.byKey(const Key('account-opening')), '500,25');
    await tester.tap(find.byKey(const Key('save-account')));
    await tester.runAsync(() async {
      for (var i = 0; i < 30 && vm.snapshot!.accounts.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Резерв'), findsOneWidget);
    expect(find.text('500,25 USD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> populate() async {
    await repo.saveBudget(
      month: DateTime(2026, 11),
      category: 'Продукты',
      limitMinor: 7000,
    );
    final account = vm.snapshot!.accounts.first.id;
    for (final (kind, amount, category, note, day) in [
      (EntryKind.income, 180000, 'Зарплата', 'Ноябрь', 10),
      (EntryKind.expense, 6250, 'Продукты', 'Покупки на неделю', 12),
      (EntryKind.expense, 1800, 'Транспорт', 'Поездки по городу', 13),
      (EntryKind.expense, 2490, 'Подписки', 'Онлайн-сервисы', 14),
    ]) {
      await repo.saveEntry(
        kind: kind,
        amountMinor: amount,
        date: DateTime(2026, 11, day),
        accountId: account,
        category: category,
        note: note,
      );
    }
    await vm.refresh();
  }

  for (final (label, size, scale) in [
    ('desktop', const Size(1280, 1000), 1.0),
    ('phone', const Size(390, 844), 1.0),
    ('large_text', const Size(390, 844), 1.5),
  ]) {
    testWidgets('$label layout and visual preview', (tester) async {
      await populate();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('preview'),
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: FinanceApp(viewModel: vm),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('preview')),
        matchesGoldenFile('../goldens/$label.png'),
      );
      if (label != 'desktop') {
        await tester.tap(find.text('Счета').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('new-account')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-payment')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const Key('preview')),
          matchesGoldenFile('../goldens/payment_form_$label.png'),
        );
      }
    });
  }

  testWidgets(
    'payment creation, confirmation and undo update balance through real forms',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(FinanceApp(viewModel: vm));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-payment')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('payment-name')), 'Интернет');
      await tester.enterText(find.byKey(const Key('payment-amount')), '20');
      await tester.tap(find.byKey(const Key('save-payment')));
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && vm.snapshot!.obligations.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(vm.totalBalance, 250000);
      expect(vm.snapshot!.entries, isEmpty);
      final o = vm.snapshot!.obligations.single;
      await tester.tap(find.byKey(ValueKey('pay-${o.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-settlement')));
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && vm.snapshot!.settlements.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(vm.totalBalance, 248000);
      expect(vm.snapshot!.entries.length, 1);
      await tester.scrollUntilVisible(
        find.text('Отменить подтверждение / пропуск'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Отменить подтверждение / пропуск'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подтвердить').last);
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && vm.snapshot!.settlements.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(vm.totalBalance, 250000);
      expect(vm.snapshot!.entries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop payments preview', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await repo.saveObligation(
      Obligation(
        id: 'internet',
        name: 'Домашний интернет',
        kind: EntryKind.expense,
        amountMinor: 2500,
        category: 'Дом',
        anchor: DateTime(2026, 11, 20),
        repeat: RepeatRule.monthly,
      ),
    );
    await repo.saveObligation(
      Obligation(
        id: 'salary',
        name: 'Зарплата',
        kind: EntryKind.income,
        amountMinor: 180000,
        category: 'Зарплата',
        anchor: DateTime(2026, 11, 30),
        repeat: RepeatRule.monthly,
      ),
    );
    await vm.refresh();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('preview'),
        child: FinanceApp(viewModel: vm),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('preview')),
      matchesGoldenFile('../goldens/payments_desktop.png'),
    );
  });
}
