import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/insights/series_reviews_screen.dart';
import 'package:personal_finance/ui/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native series decision persists across database reopen and UI undo',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'apri-series-native-',
      );
      final databaseFile = File('${directory.path}/ledger.sqlite'),
          preferencesFile = File('${directory.path}/insights.json');
      var db = LedgerDatabase(NativeDatabase.createInBackground(databaseFile));
      var repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
      var vm = FinanceViewModel(
        repo,
        insightsPreferences: FileInsightsPreferences(preferencesFile),
      )..month = DateTime(2026, 11);
      Future<void> reopen() async {
        await tester.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        db = LedgerDatabase(NativeDatabase.createInBackground(databaseFile));
        repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
        vm = FinanceViewModel(
          repo,
          insightsPreferences: FileInsightsPreferences(preferencesFile),
        )..month = DateTime(2026, 11);
        await vm.refresh();
      }

      try {
        await repo.setCurrency('AZN');
        await repo.saveAccount(
          name: 'Тестовая карта',
          kind: 'Карта',
          openingMinor: 500000,
        );
        final account = (await repo.load()).accounts.single.id;
        for (var month = 9; month <= 11; month++) {
          await repo.saveEntry(
            kind: EntryKind.expense,
            amountMinor: 10000,
            date: DateTime(2026, month, 12),
            accountId: account,
            category: 'Сервис',
            note: 'Интернет',
          );
        }
        await repo.saveObligation(
          Obligation(
            id: 'internet-plan',
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
        final before = (await repo.exportData()).toJson();
        final proposal = vm.insights.results
            .singleWhere((i) => i.rule == 'G1')
            .seriesProposal!;
        expect(
          await vm.insights.reviewSeries(proposal, SeriesDecision.accepted),
          isTrue,
        );
        await reopen();
        expect(vm.insights.policy.seriesReviews, hasLength(1));
        expect(
          await vm.insights.linkSeries(
            proposal.key,
            vm.snapshot!.obligations.single,
          ),
          isTrue,
        );
        await reopen();
        expect(
          vm.insights.policy.seriesReviews.values.single.planLink?.planId,
          'internet-plan',
        );
        expect(vm.insights.results.where((i) => i.rule == 'G1'), isEmpty);
        await tester.pumpWidget(
          MaterialApp(
            theme: ledgerTheme(),
            home: SeriesReviewsScreen(vm: vm),
          ),
        );
        await tester.pumpAndSettle();
        final unlink = find.text('Убрать связь');
        await tester.scrollUntilVisible(
          unlink,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(unlink);
        await tester.pumpAndSettle();
        await tester.tap(unlink);
        await tester.pumpAndSettle();
        expect(
          (await FileInsightsPreferences(
            preferencesFile,
          ).read()).seriesReviews.values.single.planLink,
          isNull,
        );
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
        await reopen();
        expect(vm.insights.policy.seriesReviews, isEmpty);
        expect(vm.insights.results.where((i) => i.rule == 'G1'), hasLength(1));
        expect((await repo.exportData()).toJson(), before);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        for (final item in directory.listSync()) {
          if (item is File) await item.delete();
        }
        await directory.delete();
      }
    },
  );
}
