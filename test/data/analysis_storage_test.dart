import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/data/backup_codec.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/analysis_profile.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db);
    await repo.setCurrency('AZN');
  });
  tearDown(() async => db.close());
  AnalysisPolicy policy() => AnalysisPolicy(
    disabled: {'A1'},
    profile: AnalysisProfile(
      touched: true,
      categoryAliases: {'еда': 'продукты'},
      debts: [
        DebtPlan(
          id: 'debt',
          name: 'Тестовый долг',
          principalMinor: 10000,
          annualRateBp: 1200,
          monthlyPaymentMinor: 1000,
          monthlyFeeMinor: 0,
          firstDue: DateTime(2026, 12),
        ),
      ],
    ),
  );
  test(
    'policy revision and compacted outbox are atomic on write failure',
    () async {
      final p = policy();
      await repo.writeAnalysisPolicy(p);
      final before = (await repo.exportData()).toJson();
      await db.customStatement(
        "CREATE TRIGGER reject_analysis BEFORE INSERT ON outbox WHEN NEW.entity_type='analysis' BEGIN SELECT RAISE(ABORT,'test failure'); END",
      );
      await expectLater(
        repo.writeAnalysisPolicy(p.copyWith(changePercent: 35)),
        throwsA(anything),
      );
      expect((await repo.exportData()).toJson(), before);
      await db.customStatement('DROP TRIGGER reject_analysis');
      await repo.writeAnalysisPolicy(p.copyWith(changePercent: 35));
      final saved = await repo.exportData();
      expect(
        saved.tables['outbox']!.where((r) => r['entity_type'] == 'analysis'),
        hasLength(1),
      );
      expect(
        saved.tables['settings']!.singleWhere(
          (r) => r['key'] == 'analysis_revision',
        )['value'],
        '2',
      );
      expect((await repo.load()).pendingChanges, 1);
    },
  );
  test('legacy file migrates once and old restore does not resurrect archived policy', () async {
    final dir = await Directory.systemTemp.createTemp('apri-migration-');
    final file = File('${dir.path}/insights.json');
    try {
      final old = await repo.exportData();
      await FileInsightsPreferences(file).write(policy());
      final bytes = await file.readAsBytes();
      final store = DatabaseInsightsPreferences(repo, legacyFile: file);
      expect((await store.read()).toJson(), policy().toJson());
      expect(await file.exists(), isFalse);
      final archives = await dir.list().toList();
      expect(await File(archives.single.path).readAsBytes(), bytes);
      expect(
        (await DatabaseInsightsPreferences(
          repo,
          legacyFile: file,
        ).read()).disabled,
        {'A1'},
      );
      await repo.replaceData(old, beforeReplace: (_) async {});
      expect((await store.read()).profile.touched, isFalse);
      expect(
        (await DatabaseInsightsPreferences(
          repo,
          legacyFile: file,
        ).read()).disabled,
        isEmpty,
      );
    } finally {
      for (final f in await dir.list().toList()) {
        await f.delete();
      }
      await dir.delete();
    }
  });
  test('encrypted schema five restores complete profile and refresh replaces cached policy', () async {
    final old = await repo.exportData();
    await repo.writeAnalysisPolicy(policy());
    final exported = await repo.exportData();
    expect(exported.toJson()['schema'], 5);
    final encrypted = await BackupCodec.encrypt(
      exported,
      'fictional-password-123',
    );
    final restored = await BackupCodec.decrypt(
      encrypted,
      'fictional-password-123',
    );
    expect(restored.toJson(), exported.toJson());
    final vm = FinanceViewModel(
      repo,
      insightsPreferences: DatabaseInsightsPreferences(repo),
    );
    try {
      await vm.refresh();
      expect(vm.insights.policy.profile.debts, hasLength(1));
      await repo.replaceData(old, beforeReplace: (_) async {});
      await vm.refresh();
      expect(vm.insights.policy.profile.debts, isEmpty);
      await repo.replaceData(restored, beforeReplace: (_) async {});
      await vm.refresh();
      expect(vm.insights.policy.toJson(), policy().toJson());
    } finally {
      vm.dispose();
    }
  });
  test(
    'malformed or oversized stored profiles never overwrite valid state',
    () async {
      await repo.writeAnalysisPolicy(policy());
      final before = (await repo.exportData()).toJson();
      await expectLater(
        repo.writeAnalysisPolicy(
          policy().copyWith(hidden: {'я' * (3 * 1024 * 1024)}),
        ),
        throwsFormatException,
      );
      expect((await repo.exportData()).toJson(), before);
      final raw = jsonDecode(jsonEncode(before)) as Map<String, dynamic>;
      final settings = raw['tables']['settings'] as List;
      final row = settings.singleWhere((r) => r['key'] == 'analysis_policy');
      final malformed =
          jsonDecode(row['value'] as String) as Map<String, dynamic>;
      malformed['profile']['debts'][0]['principalMinor'] = -1;
      row['value'] = jsonEncode(malformed);
      expect(() => BackupData.fromJson(raw), throwsA(isA<DomainError>()));
      expect((await repo.exportData()).toJson(), before);
    },
  );
  test('monetary profile freezes currency even before first account', () async {
    await repo.writeAnalysisPolicy(policy());
    await expectLater(repo.setCurrency('USD'), throwsA(anything));
    expect((await repo.load()).currency, 'AZN');
  });
  test(
    'alias collisions cannot create two limits for one canonical category',
    () async {
      await repo.writeAnalysisPolicy(policy());
      await repo.saveBudget(
        month: DateTime(2026, 11),
        category: 'Еда',
        limitMinor: 1000,
      );
      await expectLater(
        repo.saveBudget(
          month: DateTime(2026, 11),
          category: 'Продукты',
          limitMinor: 2000,
        ),
        throwsA(anything),
      );
      expect((await repo.load()).budgets, hasLength(1));
    },
  );
  test('stale sync cannot overwrite a newer analysis edit', () async {
    final empty = await repo.exportData();
    final captured = await repo.captureSync();
    await repo.writeAnalysisPolicy(policy());
    await expectLater(
      repo.finishSync(
        expected: captured,
        data: empty,
        scope: 'test',
        revision: 1,
        payload: 'fixture',
        beforeReplace: (_) async {},
      ),
      throwsA(isA<DomainError>()),
    );
    expect((await repo.readAnalysisPolicy())!.toJson(), policy().toJson());
    expect(
      (await repo.exportData()).tables['outbox']!.where(
        (r) => r['entity_type'] == 'analysis',
      ),
      hasLength(1),
    );
    expect((await repo.captureSync()).pendingChanges, 1);
  });
}
