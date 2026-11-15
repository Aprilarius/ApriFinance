import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/series_review.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/insights/insights_view_model.dart';

import '../domain/insights_test.dart' show fixture;
import '../domain/confirmed_series_test.dart' show seriesFixture;
import '../domain/series_plan_link_test.dart'
    show linkedFixture, linkPlan, linkedPolicy;

class FailingInsightsStore extends MemoryInsightsPreferences {
  bool failRead = false, failWrite = false;
  @override
  Future<AnalysisPolicy> read() async {
    if (failRead) throw const FormatException('test');
    return super.read();
  }

  @override
  Future<void> write(AnalysisPolicy policy) async {
    if (failWrite) throw const FormatException('test');
    await super.write(policy);
  }
}

void main() {
  test(
    'failed forced settings reload cannot silently publish stale calculations',
    () async {
      final store = FailingInsightsStore();
      var calls = 0;
      final state = InsightsViewModel(
        preferences: store,
        runner: (request) async {
          calls++;
          return analyzeRequest(request);
        },
      );
      try {
        await state.update(
          fixture(),
          DateTime(2026, 11),
          DateTime(2026, 11, 14),
        );
        expect(calls, 1);
        store.failRead = true;
        await state.update(
          fixture(),
          DateTime(2026, 11),
          DateTime(2026, 11, 14),
        );
        expect(state.error, contains('прочитать'));
        expect(state.initialized, isFalse);
        expect(calls, 1);
        expect(await state.disable('A1'), isFalse);
        store.failRead = false;
        await state.retry();
        expect(state.error, isNull);
        expect(state.initialized, isTrue);
        expect(calls, 2);
      } finally {
        state.dispose();
      }
    },
  );

  test('link writes are atomic and stale selected plan cannot overwrite a newer plan', () async {
    final store = FailingInsightsStore();
    final state = InsightsViewModel(preferences: store);
    await state.update(
      linkedFixture(),
      DateTime(2026, 11),
      DateTime(2026, 11, 14),
    );
    await state.configure(
      linkedPolicy().copyWith(
        seriesReviews: {
          for (final e in linkedPolicy().seriesReviews.entries)
            e.key: e.value.withLink(null),
        },
      ),
    );
    final key = state.policy.seriesReviews.keys.single;
    store.failWrite = true;
    expect(await state.linkSeries(key, linkPlan()), isFalse);
    expect(state.policy.seriesReviews[key]!.planLink, isNull);
    store.failWrite = false;
    expect(await state.linkSeries(key, linkPlan()), isTrue);
    expect(state.policy.seriesReviews[key]!.planLink!.planId, 'plan');
    expect(await state.unlinkSeries(key), isTrue);
    expect(state.policy.seriesReviews[key]!.decision.name, 'accepted');
    await state.update(
      linkedFixture(linkPlan(amount: 15000)),
      DateTime(2026, 11),
      DateTime(2026, 11, 14),
    );
    expect(await state.linkSeries(key, linkPlan()), isFalse);
    expect(state.policy.seriesReviews[key]!.planLink, isNull);
    state.dispose();
  });
  test(
    'series decision persists and write failure retains previous policy',
    () async {
      final store = FailingInsightsStore();
      final vm = InsightsViewModel(preferences: store);
      final s = seriesFixture();
      await vm.update(s, DateTime(2026, 11), DateTime(2026, 11, 14));
      final p = vm.results.singleWhere((i) => i.rule == 'G1').seriesProposal!;
      store.failWrite = true;
      expect(await vm.reviewSeries(p, SeriesDecision.accepted), isFalse);
      expect(vm.policy.seriesReviews, isEmpty);
      store.failWrite = false;
      expect(await vm.reviewSeries(p, SeriesDecision.accepted), isTrue);
      expect(vm.results.where((i) => i.rule == 'G1'), isEmpty);
      vm.dispose();
      final reopened = InsightsViewModel(preferences: store);
      await reopened.update(s, DateTime(2026, 11), DateTime(2026, 11, 14));
      expect(reopened.policy.seriesReviews, hasLength(1));
      expect(await reopened.forgetSeries(p.key), isTrue);
      expect(reopened.results.where((i) => i.rule == 'G1'), hasLength(1));
      reopened.dispose();
    },
  );
  test(
    'stale series proposal cannot be confirmed after source deletion',
    () async {
      final vm = InsightsViewModel(), s = seriesFixture();
      await vm.update(s, DateTime(2026, 11), DateTime(2026, 11, 14));
      final p = vm.results.singleWhere((i) => i.rule == 'G1').seriesProposal!;
      await vm.update(
        seriesFixture(entries: s.entries.skip(1).toList()),
        DateTime(2026, 11),
        DateTime(2026, 11, 14),
      );
      expect(await vm.reviewSeries(p, SeriesDecision.accepted), isFalse);
      expect(vm.policy.seriesReviews, isEmpty);
      expect(vm.error, contains('изменились'));
      vm.dispose();
    },
  );
  final month = DateTime(2026, 11), today = DateTime(2026, 11, 14);
  test(
    'large snapshot is calculated across the real isolate boundary',
    () async {
      final s = fixture();
      final snapshot = LedgerSnapshot(
        currency: s.currency,
        accounts: s.accounts,
        obligations: [
          Obligation(
            id: 'future-plan',
            name: 'План',
            kind: EntryKind.expense,
            amountMinor: 1000,
            category: 'Планы',
            anchor: DateTime(2026, 11, 16),
            repeat: RepeatRule.once,
          ),
        ],
        entries: List.generate(
          1000,
          (n) => LedgerEntry(
            id: 'large-$n',
            kind: EntryKind.expense,
            amountMinor: 100,
            date: DateTime(2026, 11, 2),
            accountId: 'a',
            category: 'Еда',
          ),
        ),
      );
      final state = InsightsViewModel();
      try {
        await state.update(snapshot, month, today);
        expect(state.error, isNull);
        expect(
          state.results.singleWhere((i) => i.rule == 'I1').timeline,
          hasLength(91),
        );
        expect(
          state.results
              .singleWhere((i) => i.rule == 'A1')
              .amounts['Расходы до возвратов'],
          100000,
        );
      } finally {
        state.dispose();
      }
    },
  );
  test('latest request wins and expensive runners never overlap', () async {
    final gate = Completer<void>();
    var running = 0, maximum = 0, calls = 0;
    final vm = InsightsViewModel(
      runner: (request) async {
        calls++;
        running++;
        if (running > maximum) maximum = running;
        if (calls == 1) await gate.future;
        running--;
        return analyzeRequest(request);
      },
    );
    try {
      final first = vm.update(fixture(), month, today);
      await Future<void>.delayed(Duration.zero);
      final middle = vm.update(fixture(), DateTime(2026, 12), today);
      final last = vm.update(fixture(), DateTime(2027, 1), today);
      gate.complete();
      await Future.wait([first, middle, last]);
      expect(maximum, 1);
      expect(calls, 2);
      expect(vm.results.single.entity, 'future');
      expect(vm.results.single.period, startsWith('2027-01'));
      expect(vm.loading, false);
    } finally {
      vm.dispose();
    }
  });
  test(
    'failed preference write keeps previous policy and can be retried',
    () async {
      final store = FailingInsightsStore();
      final state = InsightsViewModel(preferences: store);
      try {
        await state.update(fixture(), month, today);
        store.failWrite = true;
        expect(await state.disable('A1'), false);
        expect(state.policy.disabled, isEmpty);
        expect(state.error, isNotNull);
        store.failWrite = false;
        expect(await state.disable('A1'), true);
        expect(state.results.where((i) => i.rule == 'A1'), isEmpty);
        expect(state.saving, false);
      } finally {
        state.dispose();
      }
    },
  );
  test(
    'read failure leaves finance untouched and analysis retry recovers',
    () async {
      final store = FailingInsightsStore()..failRead = true;
      final state = InsightsViewModel(preferences: store);
      try {
        await state.update(fixture(), month, today);
        expect(state.initialized, false);
        expect(state.error, isNotNull);
        store.failRead = false;
        await state.retry();
        expect(state.error, isNull);
        expect(state.results, isNotEmpty);
      } finally {
        state.dispose();
      }
    },
  );
  test('disposing ignores an outstanding analysis response', () async {
    final gate = Completer<List<Insight>>();
    final state = InsightsViewModel(runner: (_) => gate.future);
    final pending = state.update(fixture(), month, today);
    await Future<void>.delayed(Duration.zero);
    state.dispose();
    gate.complete([]);
    await pending;
  });
}
