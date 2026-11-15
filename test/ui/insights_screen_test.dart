import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/insights/insights_screen.dart';
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
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 500000);
    final id = (await repo.load()).accounts.single.id;
    await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 4000,
      date: DateTime(2026, 11, 2),
      accountId: id,
      category: 'Еда',
    );
    vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
    await vm.refresh();
  });
  tearDown(() async {
    vm.dispose();
    await db.close();
  });
  Future<void> mount(WidgetTester tester, Size size, double scale) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('audit-preview'),
        child: MaterialApp(
          theme: ledgerTheme(),
          debugShowCheckedModeBanner: false,
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              textScaler: TextScaler.linear(scale),
              padding: const EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: child!,
          ),
          home: InsightsScreen(vm: vm),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (name, size, scale) in [
    ('phone', const Size(390, 844), 1.0),
    ('large', const Size(320, 568), 2.0),
  ]) {
    testWidgets(
      'series plan link $name can be selected and removed without ledger changes',
      (tester) async {
        final account = vm.snapshot!.accounts.single.id;
        for (var month = 9; month <= 11; month++) {
          await vm.repository.saveEntry(
            kind: EntryKind.expense,
            amountMinor: 10000,
            date: DateTime(2026, month, 12),
            accountId: account,
            category: 'Сервис',
            note: 'Интернет',
          );
        }
        await vm.repository.saveObligation(
          Obligation(
            id: 'link-plan',
            name: 'Интернет',
            kind: EntryKind.expense,
            amountMinor: 10000,
            category: 'Сервис',
            anchor: DateTime(2026, 12, 12),
            repeat: RepeatRule.monthly,
            accountId: account,
          ),
        );
        await vm.refresh();
        final proposal = vm.insights.results
            .singleWhere((i) => i.rule == 'G1')
            .seriesProposal!;
        await vm.insights.reviewSeries(proposal, SeriesDecision.accepted);
        final before = (await vm.repository.exportData()).toJson();
        await mount(tester, size, scale);
        final manager = find.byKey(const Key('series-reviews'));
        await tester.scrollUntilVisible(
          manager,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(manager);
        await tester.pumpAndSettle();
        await tester.tap(manager);
        await tester.pumpAndSettle();
        final link = find.text('Связать с планом');
        await tester.scrollUntilVisible(
          link,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        await tester.tap(link);
        await tester.pumpAndSettle();
        final plan = find.text('Интернет');
        await tester.scrollUntilVisible(
          plan,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(plan);
        await tester.pumpAndSettle();
        await capture(tester, 'series_plan_${name}_picker');
        await tester.tap(plan);
        await tester.pumpAndSettle();
        expect(
          vm.insights.policy.seriesReviews.values.single.planLink?.planId,
          'link-plan',
        );
        final label = find.text('План: Интернет');
        await tester.scrollUntilVisible(
          label,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        await capture(tester, 'series_plan_${name}_linked');
        final unlink = find.text('Убрать связь');
        await tester.ensureVisible(unlink);
        await tester.pumpAndSettle();
        await tester.tap(unlink);
        await tester.pumpAndSettle();
        expect(vm.insights.policy.seriesReviews.values.single.planLink, isNull);
        expect(
          vm.insights.policy.seriesReviews.values.single.decision,
          SeriesDecision.accepted,
        );
        expect((await vm.repository.exportData()).toJson(), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('calendar scenario opens daily end balances through horizon', (
    tester,
  ) async {
    await vm.repository.saveObligation(
      Obligation(
        id: 'debit',
        name: 'Крупный платёж',
        kind: EntryKind.expense,
        amountMinor: 1000000,
        category: 'Планы',
        anchor: DateTime(2026, 11, 16),
        repeat: RepeatRule.once,
        accountId: vm.snapshot!.accounts.single.id,
      ),
    );
    await vm.refresh();
    await mount(tester, const Size(390, 844), 1);
    final title = find.text('В сценарии возможен отрицательный остаток');
    await tester.scrollUntilVisible(
      title,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    final card = find.ancestor(of: title, matching: find.byType(Card));
    final details = find.descendant(
      of: card,
      matching: find.text('Объяснение и исходные записи'),
    );
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    final timeline = find.text('Остаток на конец дня');
    await tester.scrollUntilVisible(
      timeline,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(timeline);
    await tester.pumpAndSettle();
    await tester.tap(timeline);
    await tester.pumpAndSettle();
    final first = find.text('2026-11-14');
    await tester.ensureVisible(first);
    await tester.pumpAndSettle();
    await capture(tester, 'calendar_timeline_phone');
    final last = find.text('2027-02-12');
    await tester.scrollUntilVisible(
      last,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('income delay input validates range and persists chosen days', (
    tester,
  ) async {
    await mount(tester, const Size(390, 844), 1);
    await tester.tap(find.byKey(const Key('insights-settings')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('insights-income-delay'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, '0');
    await tester.tap(find.byKey(const Key('save-insights-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Укажите от 1 до 90 дней'), findsOneWidget);
    await tester.enterText(field, '14');
    await tester.tap(find.byKey(const Key('save-insights-settings')));
    await tester.pumpAndSettle();
    expect(vm.insights.policy.incomeDelayDays, 14);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final (name, size, scale, accept) in [
    ('accepted', const Size(390, 844), 1.0, true),
    ('rejected', const Size(390, 844), 1.0, false),
    ('large', const Size(320, 568), 2.0, true),
  ]) {
    testWidgets(
      'series $name can be reviewed and decision undone without editing ledger',
      (tester) async {
        for (var month = 9; month <= 11; month++) {
          await vm.repository.saveEntry(
            kind: EntryKind.expense,
            amountMinor: 10000,
            date: DateTime(2026, month, 12),
            accountId: vm.snapshot!.accounts.single.id,
            category: 'Сервис',
            note: 'Интернет',
          );
        }
        await vm.refresh();
        await mount(tester, size, scale);
        final filter = find.widgetWithText(
          ChoiceChip,
          'Повторения и необычное',
        );
        await tester.scrollUntilVisible(
          filter,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(filter);
        await tester.pumpAndSettle();
        await tester.tap(filter);
        await tester.pumpAndSettle();
        final details = find.text('Объяснение и исходные записи');
        await tester.scrollUntilVisible(
          details,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(details);
        await tester.pumpAndSettle();
        await tester.tap(details);
        await tester.pumpAndSettle();
        final action = find.text(
          accept ? 'Подтвердить повторение' : 'Это не повторение',
        );
        await tester.scrollUntilVisible(
          action,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await capture(tester, 'series_${name}_decision');
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(vm.insights.policy.seriesReviews, hasLength(1));
        expect(vm.insights.results.where((i) => i.rule == 'G1'), isEmpty);
        final manager = find.byKey(const Key('series-reviews'));
        await tester.scrollUntilVisible(
          manager,
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(manager);
        await tester.pumpAndSettle();
        await tester.tap(manager);
        await tester.pumpAndSettle();
        final status = find.textContaining(
          accept ? 'Подтверждено ·' : 'Отклонено ·',
        );
        await tester.scrollUntilVisible(
          status,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(status);
        await tester.pumpAndSettle();
        await capture(tester, 'series_${name}_manager');
        final undo = find.text('Отменить решение');
        await tester.scrollUntilVisible(
          undo,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(undo);
        await tester.pumpAndSettle();
        await tester.tap(undo);
        await tester.pumpAndSettle();
        expect(vm.insights.policy.seriesReviews, isEmpty);
        expect(vm.insights.results.where((i) => i.rule == 'G1'), hasLength(1));
        expect((await vm.repository.load()).entries, hasLength(4));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final (name, size, scale) in [
    ('phone', const Size(390, 844), 1.0),
    ('large', const Size(320, 568), 2.0),
    ('desktop', const Size(1280, 900), 1.0),
  ]) {
    testWidgets('analysis $name filters details and settings remain usable', (
      tester,
    ) async {
      await mount(tester, size, scale);
      expect(tester.takeException(), isNull);
      await capture(tester, 'insights_$name');
      final filter = find.widgetWithText(ChoiceChip, 'Сценарии');
      if (filter.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          filter,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(filter);
      await tester.pumpAndSettle();
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(find.textContaining('Сценарий: сократить'), findsOneWidget);
      final details = find.text('Объяснение и исходные записи');
      if (details.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          details,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      await capture(tester, 'insights_${name}_details');
      expect(
        find.textContaining('Возможное сокращение: 4,00 AZN'),
        findsOneWidget,
      );
      final hide = find.text('Скрыть на этот период');
      await tester.ensureVisible(hide);
      await tester.pumpAndSettle();
      await tester.tap(hide);
      await tester.pumpAndSettle();
      expect(vm.insights.policy.hidden, isNotEmpty);
      expect(find.textContaining('Сценарий: сократить'), findsNothing);
      final settings = find.byKey(const Key('insights-settings'));
      if (settings.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          settings,
          -200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(settings);
      await tester.pumpAndSettle();
      await tester.tap(settings);
      await tester.pumpAndSettle();
      await capture(tester, 'insights_${name}_settings');
      if (name == 'large') {
        tester.view.viewInsets = const FakeViewPadding(bottom: 200);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byKey(const Key('insights-minimum')), '0');
      await tester.tap(find.byKey(const Key('save-insights-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Укажите сумму больше нуля'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
    'pattern filter explains duplicate candidates without changing records',
    (tester) async {
      await vm.repository.saveEntry(
        kind: EntryKind.expense,
        amountMinor: 4000,
        date: DateTime(2026, 11, 2),
        accountId: vm.snapshot!.accounts.single.id,
        category: 'Еда',
      );
      await vm.refresh();
      await mount(tester, const Size(390, 844), 1);
      final filter = find.widgetWithText(ChoiceChip, 'Повторения и необычное');
      await tester.scrollUntilVisible(
        filter,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(filter);
      await tester.pumpAndSettle();
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(find.text('Проверьте похожие операции'), findsOneWidget);
      await capture(tester, 'insights_patterns');
      final details = find.text('Объяснение и исходные записи');
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Это могут быть разные реальные покупки.'),
        findsWidgets,
      );
      expect(vm.snapshot!.entries, hasLength(2));
      expect((await vm.repository.load()).entries, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('source entry opens a real edit form and recomputes analysis', (
    tester,
  ) async {
    await mount(tester, const Size(390, 844), 1);
    final details = find.text('Объяснение и исходные записи').first;
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    final source = find.textContaining('Расход · Еда');
    await tester.scrollUntilVisible(
      source,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(source);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('entry-amount')), '45');
    await tester.tap(find.byKey(const Key('save-entry')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(vm.snapshot!.entries.single.amountMinor, 4500);
    expect(
      vm.insights.results
          .singleWhere((i) => i.rule == 'A1')
          .amounts['Расходы до возвратов'],
      4500,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'settings persist coverage signatures, thresholds and disabled rules',
    (tester) async {
      await mount(tester, const Size(390, 844), 1);
      await tester.tap(find.byKey(const Key('insights-settings')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('insights-minimum')), '15');
      final checks = find.byType(CheckboxListTile);
      for (var n = 0; n < 2; n++) {
        await tester.ensureVisible(checks.at(n));
        await tester.pumpAndSettle();
        await tester.tap(checks.at(n));
        await tester.pumpAndSettle();
      }
      final rule = find.widgetWithText(SwitchListTile, 'Денежный поток');
      await tester.ensureVisible(rule);
      await tester.pumpAndSettle();
      await tester.tap(rule);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-insights-settings')));
      await tester.pumpAndSettle();
      expect(vm.insights.policy.minimumChangeMinor, 1500);
      expect(vm.insights.policy.disabled, contains('A1'));
      expect(
        vm.insights.policy.covers(DateTime(2026, 11, 14), vm.snapshot!),
        isTrue,
      );
      expect(
        vm.insights.policy.covers(DateTime(2026, 10, 14), vm.snapshot!),
        isTrue,
      );
      expect(vm.insights.results.where((i) => i.rule == 'A1'), isEmpty);
      expect(vm.insights.results.where((i) => i.rule == 'B1'), isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('a 31-day closed month can be confirmed after a shorter month', (
    tester,
  ) async {
    vm.month = DateTime(2026, 10);
    await vm.refresh();
    await mount(tester, const Size(390, 844), 1);
    await tester.tap(find.byKey(const Key('insights-settings')));
    await tester.pumpAndSettle();
    final full = find.text('Все операции внесены: 2026-10-01 — 2026-10-31');
    expect(full, findsOneWidget);
    await tester.ensureVisible(full);
    await tester.pumpAndSettle();
    await tester.tap(full);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-insights-settings')));
    await tester.pumpAndSettle();
    expect(
      vm.insights.policy.covers(DateTime(2026, 10, 31), vm.snapshot!),
      isTrue,
    );
    expect(vm.insights.results.where((i) => i.rule == 'O2'), isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('summary filter opens a weekly report with real source entries', (
    tester,
  ) async {
    await vm.repository.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 200,
      date: DateTime(2026, 11, 10),
      accountId: vm.snapshot!.accounts.single.id,
      category: 'Еда',
    );
    await vm.refresh();
    await mount(tester, const Size(390, 844), 1);
    final filter = find.widgetWithText(ChoiceChip, 'Сводки');
    await tester.ensureVisible(filter);
    await tester.pumpAndSettle();
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text('Сводка за последние 7 дней периода'), findsOneWidget);
    await capture(tester, 'insights_summaries');
    final details = find.text('Объяснение и исходные записи');
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('Расходы до возвратов: 2,00 AZN'), findsOneWidget);
    expect(
      vm.insights.results.singleWhere((i) => i.rule == 'O1').evidence.length,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
