import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/ui/insights/analysis_setup_screen.dart';
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
  late LedgerDatabase db;
  late FinanceViewModel vm;
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
    await repo.setCurrency('AZN');
    await repo.saveAccount(
      name: 'Тестовая карта',
      kind: 'Карта',
      openingMinor: 100000,
    );
    vm = FinanceViewModel(
      repo,
      insightsPreferences: DatabaseInsightsPreferences(repo),
    )..month = DateTime(2026, 11);
    await vm.refresh();
  });
  tearDown(() async {
    vm.dispose();
    await db.close();
  });
  Future<void> mount(
    WidgetTester t,
    String section,
    Size size,
    double scale,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetDevicePixelRatio);
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      RepaintBoundary(
        key: const Key('audit-preview'),
        child: MaterialApp(
          theme: ledgerTheme(),
          debugShowCheckedModeBanner: false,
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: AnalysisSetupScreen(vm: vm, initialSection: section),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    await t.tap(finder);
    await t.pumpAndSettle();
  }

  Finder field(String id) => find.byKey(Key('analysis-field-$id'));
  Future<void> text(WidgetTester t, String id, String value) async {
    await t.ensureVisible(field(id));
    await t.enterText(field(id), value);
  }

  Future<void> save(WidgetTester t) async {
    final button = find.byKey(const Key('save-analysis-data'));
    await t.ensureVisible(button);
    await t.pumpAndSettle();
    await t.tap(button);
    await t.pump();
    await t.runAsync(() async {
      for (var n = 0; n < 100 && vm.insights.saving; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await t.pumpAndSettle();
  }

  testWidgets(
    'goal form allocates existing funds without creating an expense',
    (t) async {
      await mount(t, 'goals', const Size(390, 844), 1);
      await tap(t, find.byKey(const Key('add-analysis-goals')));
      await text(t, 'name', 'Новый компьютер');
      await tap(t, field('accountId'));
      await tap(t, find.text('Тестовая карта').last);
      await text(t, 'targetMinor', '2000');
      await text(t, 'allocatedMinor', '500');
      await text(t, 'monthlyMinor', '100');
      await save(t);
      expect(vm.insights.policy.profile.goals.single.allocatedMinor, 50000);
      expect(vm.snapshot!.entries, isEmpty);
      expect(vm.insights.results.any((r) => r.rule == 'K3'), isTrue);
      expect(vm.insights.results.any((r) => r.rule == 'K4'), isTrue);
    },
  );
  testWidgets(
    'explicit expense annotation survives store reopen without altering entry',
    (t) async {
      final account = vm.snapshot!.accounts.single.id;
      await vm.repository.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 1000,
        date: DateTime(2026, 11, 2),
        accountId: account,
        category: 'Кафе',
      );
      await vm.refresh();
      final entry = vm.snapshot!.entries.single;
      await mount(t, 'annotations', const Size(390, 844), 1);
      await tap(t, find.text('Открыть операции для разметки'));
      await tap(t, find.text('2026-11-02 · Расход · Кафе'));
      await tap(t, field('role'));
      await tap(t, find.text('Гибкий').last);
      await text(t, 'counterparty', 'Тестовое кафе');
      await tap(t, field('oneOff'));
      await save(t);
      final saved = (await t.runAsync(
        () => vm.repository.readAnalysisPolicy(),
      ))!.profile.annotation(entry)!;
      expect(saved.role, ExpenseRole.flexible);
      expect(saved.oneOff, isTrue);
      expect(saved.counterparty, 'Тестовое кафе');
      expect(vm.snapshot!.entries.single.toJson(), entry.toJson());
    },
  );
  for (final (name, size, scale) in [
    ('phone', const Size(390, 844), 1.0),
    ('large', const Size(320, 568), 2.0),
    ('desktop', const Size(1280, 900), 1.0),
  ]) {
    testWidgets(
      'debt form $name validates and saves exact values into production store',
      (t) async {
        await mount(t, 'debts', size, scale);
        await capture(t, 'setup-$name');
        await tap(t, find.byKey(const Key('add-analysis-debts')));
        await text(t, 'name', 'Тестовый долг');
        await text(t, 'principalMinor', '1000');
        await text(t, 'annualRateBp', '12,5');
        await text(t, 'monthlyPaymentMinor', '0');
        await save(t);
        expect(vm.insights.policy.profile.debts, isEmpty);
        await text(t, 'monthlyPaymentMinor', '100');
        await capture(t, 'debt-form-$name');
        await save(t);
        final debt = (await t.runAsync(
          () => vm.repository.readAnalysisPolicy(),
        ))!.profile.debts.single;
        expect(debt.principalMinor, 100000);
        expect(debt.annualRateBp, 1250);
        expect(debt.monthlyPaymentMinor, 10000);
        expect(vm.snapshot!.entries, isEmpty);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'reserve cannot allocate more than available balance and can be corrected',
    (t) async {
      await mount(t, 'reserves', const Size(390, 844), 1);
      await tap(t, find.byKey(const Key('add-analysis-reserves')));
      await tap(t, field('key'));
      await tap(t, find.text('Тестовая карта').last);
      await text(t, 'value', '1001');
      await save(t);
      expect(vm.insights.policy.profile.reserves, isEmpty);
      expect(find.byKey(const Key('save-analysis-data')), findsOneWidget);
      await text(t, 'value', '900');
      await save(t);
      expect(vm.insights.policy.profile.reserves.values.single, 90000);
      expect(vm.snapshot!.accounts.single.openingMinor, 100000);
    },
  );
  testWidgets(
    'alias form saves explicit name without editing ledger and rejects cycle',
    (t) async {
      await mount(t, 'categoryAliases', const Size(390, 844), 1);
      await tap(t, find.byKey(const Key('add-analysis-categoryAliases')));
      await text(t, 'key', 'Кафе');
      await text(t, 'value', 'Еда');
      await save(t);
      expect(vm.insights.policy.profile.category('кафе'), 'еда');
      await tap(t, find.byKey(const Key('add-analysis-categoryAliases')));
      await text(t, 'key', 'Еда');
      await text(t, 'value', 'Кафе');
      await save(t);
      expect(vm.insights.policy.profile.categoryAliases, hasLength(1));
      expect(find.byKey(const Key('save-analysis-data')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
