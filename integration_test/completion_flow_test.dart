import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/data/backup_codec.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/insights/analysis_setup_screen.dart';
import 'package:personal_finance/ui/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native debt UI, encrypted backup, restore and database reopen preserve local profile',
    (t) async {
      final directory = await Directory.systemTemp.createTemp(
        'apri-completion-native-',
      );
      final file = File('${directory.path}/ledger.sqlite');
      var db = LedgerDatabase(NativeDatabase.createInBackground(file));
      var repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
      var vm = FinanceViewModel(
        repo,
        insightsPreferences: DatabaseInsightsPreferences(repo),
      );
      Future<void> reopen() async {
        await t.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        db = LedgerDatabase(NativeDatabase.createInBackground(file));
        repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
        vm = FinanceViewModel(
          repo,
          insightsPreferences: DatabaseInsightsPreferences(repo),
        );
        await vm.refresh();
      }

      try {
        await repo.setCurrency('AZN');
        await repo.saveAccount(
          name: 'Тестовая карта',
          kind: 'Карта',
          openingMinor: 100000,
        );
        final old = await repo.exportData();
        await vm.refresh();
        await t.pumpWidget(
          MaterialApp(
            theme: ledgerTheme(),
            locale: const Locale('ru'),
            supportedLocales: const [Locale('ru')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: AnalysisSetupScreen(vm: vm, initialSection: 'debts'),
          ),
        );
        await t.pumpAndSettle();
        final add = find.byKey(const Key('add-analysis-debts'));
        await t.ensureVisible(add);
        await t.pumpAndSettle();
        await t.tap(add);
        await t.pumpAndSettle();
        for (final field in {
          'name': 'Тестовый долг',
          'principalMinor': '1000',
          'annualRateBp': '12',
          'monthlyPaymentMinor': '100',
        }.entries) {
          final finder = find.byKey(Key('analysis-field-${field.key}'));
          await t.ensureVisible(finder);
          await t.pumpAndSettle();
          await t.enterText(finder, field.value);
        }
        final save = find.byKey(const Key('save-analysis-data'));
        await t.ensureVisible(save);
        await t.pumpAndSettle();
        await t.tap(save);
        await t.pump();
        await t.runAsync(() async {
          for (var n = 0; n < 200 && vm.insights.saving; n++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await t.pumpAndSettle();
        expect(vm.insights.policy.profile.debts.single.annualRateBp, 1200);
        final data = await repo.exportData();
        final encrypted = await BackupCodec.encrypt(
          data,
          'fictional-native-password',
        );
        final restored = await BackupCodec.decrypt(
          encrypted,
          'fictional-native-password',
        );
        await repo.replaceData(old, beforeReplace: (_) async {});
        await vm.refresh();
        expect(vm.insights.policy.profile.debts, isEmpty);
        await repo.replaceData(restored, beforeReplace: (_) async {});
        await reopen();
        expect(vm.insights.policy.profile.debts.single.principalMinor, 100000);
        expect(vm.snapshot!.entries, isEmpty);
        expect(vm.snapshot!.accounts.single.openingMinor, 100000);
        expect(vm.insights.results.any((r) => r.rule == 'K6'), isTrue);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        vm.dispose();
        await db.close();
        for (final entity in await directory.list().toList()) {
          await entity.delete();
        }
        await directory.delete();
      }
    },
  );
}
