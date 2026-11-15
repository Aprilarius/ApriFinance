import 'package:flutter/foundation.dart';

import '../../data/insights_preferences_repository.dart';
import '../../domain/insights/insight.dart';
import '../../domain/insights/insight_engine.dart';
import '../../domain/insights/series_review.dart';
import '../../domain/insights/series_plan_link.dart';
import '../../domain/insights/analysis_profile.dart';
import '../../domain/insights/analysis_facts.dart';
import '../../domain/insights/profile_math.dart';
import '../../domain/purchases.dart';
import '../../domain/models.dart';

typedef AnalysisRequest = ({
  LedgerSnapshot snapshot,
  DateTime month,
  DateTime today,
  AnalysisPolicy policy,
});
List<Insight> analyzeRequest(AnalysisRequest request) => InsightEngine()
    .analyze(request.snapshot, request.month, request.today, request.policy);
typedef AnalysisRunner = Future<List<Insight>> Function(
  AnalysisRequest request,
);
Future<List<Insight>> runAnalysis(AnalysisRequest request) async =>
    request.snapshot.entries.length >= 1000
    ? await compute(analyzeRequest, request)
    : analyzeRequest(request);

class InsightsViewModel extends ChangeNotifier {
  InsightsViewModel({
    InsightsPreferences? preferences,
    this.runner = runAnalysis,
  }) : preferences = preferences ?? MemoryInsightsPreferences();
  final InsightsPreferences preferences;
  final AnalysisRunner runner;
  Future<void>? _queue;
  AnalysisPolicy policy = AnalysisPolicy();
  int localChangeRevision = 0;
  List<Insight> results = const [];
  bool loading = false, saving = false, initialized = false;
  String? error;
  AnalysisRequest? _request;
  int _generation = 0;
  bool _disposed = false;

  Future<void> initialize({bool force = false}) async {
    if ((initialized && !force) || _disposed) return;
    try {
      policy = await preferences.read();
      error = null;
    } catch (_) {
      initialized = false;
      error = 'Не удалось прочитать настройки анализа. Учёт работает; попробуйте прочитать настройки повторно.';
    }
    if (_disposed) return;
    initialized = error == null;
    notifyListeners();
  }

  Future<void> update(LedgerSnapshot snapshot, DateTime month, DateTime today) {
    if (_disposed) return Future.value();
    final generation = ++_generation;
    loading = true;
    _request = (snapshot: snapshot, month: month, today: today, policy: policy);
    notifyListeners();
    final preceding = _queue;
    Future<void> calculate() async {
      try {
        await _calculate(snapshot, month, today, generation);
      } finally {
        if (generation == _generation) _queue = null;
      }
    }

    final operation = preceding == null
        ? calculate()
        : preceding.then((_) => calculate());
    _queue = operation;
    return operation;
  }

  Future<void> _calculate(
    LedgerSnapshot snapshot,
    DateTime month,
    DateTime today,
    int generation,
  ) async {
    if (_disposed || generation != _generation) return;
    await initialize(force: true);
    if (_disposed || generation != _generation) return;
    if (!initialized) {
      loading = false;
      notifyListeners();
      return;
    }
    final request = (
      snapshot: snapshot,
      month: month,
      today: today,
      policy: policy,
    );
    _request = request;
    try {
      final next = await runner(request);
      if (_disposed || generation != _generation) return;
      results = next;
      error = null;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      results = const [];
      error = 'Не удалось рассчитать анализ. Данные учёта не изменены. Повторите расчёт.';
    }
    if (_disposed || generation != _generation) return;
    loading = false;
    notifyListeners();
  }

  Future<void> retry() async {
    final request = _request;
    if (request != null) {
      await update(request.snapshot, request.month, request.today);
    }
  }

  Future<bool> configure(AnalysisPolicy next, {bool recover = false}) async {
    if (saving || (!initialized && !recover)) return false;
    saving = true;
    notifyListeners();
    try {
      await preferences.write(next);
      if (_disposed) return false;
      policy = next;
      initialized = true;
      await retry();
      localChangeRevision++;
      return true;
    } catch (_) {
      if (!_disposed) error = 'Не удалось сохранить настройки анализа. Прежние настройки сохранены.';
      return false;
    } finally {
      if (!_disposed) {
        saving = false;
        notifyListeners();
      }
    }
  }

  Future<bool> hide(Insight insight) =>
      configure(policy.copyWith(hidden: {...policy.hidden, insight.key}));
  Future<bool> snooze(Insight insight, DateTime today) => configure(
    policy.copyWith(
      snoozed: {
        ...policy.snoozed,
        insight.key: calendarDate(
          DateTime(today.year, today.month, today.day + 7),
        ),
      },
    ),
  );
  Future<bool> disable(String rule) =>
      configure(policy.copyWith(disabled: {...policy.disabled, rule}));

  Future<bool> reviewSeries(
    SeriesProposal proposal,
    SeriesDecision decision,
  ) async {
    final request = _request;
    if (saving || loading || request == null || !initialized) return false;
    final sources = proposal.sources(request.snapshot);
    if (sources == null || sources.any((e) => e.date.isAfter(request.today))) {
      error = 'Исходные операции изменились. Вернитесь в анализ и откройте новую карточку.';
      notifyListeners();
      return false;
    }
    if (policy.seriesReviews.length >= 500 &&
        !policy.seriesReviews.containsKey(proposal.key)) {
      error =
          'Сохранено 500 решений. Удалите ненужные решения в разделе «Серии».';
      notifyListeners();
      return false;
    }
    return configure(
      policy.copyWith(
        seriesReviews: {
          ...policy.seriesReviews,
          proposal.key: SeriesReview(
            proposal: proposal,
            decision: decision,
            reviewedOn: parseCalendarDate(calendarDate(request.today)),
          ),
        },
      ),
    );
  }

  Future<bool> forgetSeries(String key) => configure(
    policy.copyWith(seriesReviews: {...policy.seriesReviews}..remove(key)),
  );

  Future<bool> linkSeries(String key, Obligation selected) async {
    final request = _request, review = policy.seriesReviews[key];
    if (saving ||
        loading ||
        request == null ||
        review == null ||
        !initialized) {
      return false;
    }
    final plan =
        availableSeriesPlans(request.snapshot, policy, review, request.today)
            .where(
              (o) =>
                  o.id == selected.id &&
                  planLinkHash(o) == planLinkHash(selected),
            )
            .firstOrNull;
    if (plan == null) {
      error = 'Серия или план изменились, либо план уже связан. Откройте список планов заново.';
      notifyListeners();
      return false;
    }
    return configure(
      policy.copyWith(
        seriesReviews: {
          ...policy.seriesReviews,
          key: review.withLink(
            SeriesPlanLink(
              planId: plan.id,
              planHash: planLinkHash(plan),
              linkedOn: request.today,
            ),
          ),
        },
      ),
    );
  }

  Future<bool> unlinkSeries(String key) async {
    final review = policy.seriesReviews[key];
    if (review == null) return false;
    return configure(
      policy.copyWith(
        seriesReviews: {...policy.seriesReviews, key: review.withLink(null)},
      ),
    );
  }

  Future<bool> updateProfile(
    Map<String, Object?> changes, {
    bool checkFunding = false,
  }) async {
    final request = _request;
    if (saving || loading || request == null || !initialized) return false;
    try {
      final next = policy.profile.patch(changes);
      if (changes.containsKey('categoryAliases') &&
          AnalysisFacts(
            request.snapshot,
            request.month,
            request.today,
            profile: next,
          ).budgetAmbiguities.isNotEmpty) {
        throw const DomainError(
          'Алиас объединяет категории с несколькими лимитами одного месяца. Сначала оставьте один подходящий лимит.',
        );
      }
      if (checkFunding) {
        final previous = requestedAllocations(policy.profile),
            requested = requestedAllocations(next);
        if (requested.entries.any((e) => e.value > (previous[e.key] ?? 0))) {
          validateProfileFunding(next, request.snapshot, request.today);
        }
      }
      return await configure(policy.copyWith(profile: next));
    } on DomainError catch (e) {
      error = e.message;
    } on FormatException catch (e) {
      error = e.message.toString();
    }
    notifyListeners();
    return false;
  }

  bool profileError(String message) {
    error = message;
    if (!_disposed) notifyListeners();
    return false;
  }

  Future<bool> annotateEntry(
    LedgerEntry selected,
    ExpenseRole role,
    String counterparty,
    bool oneOff,
  ) async {
    final request = _request;
    if (request == null) return false;
    final current = request.snapshot.entries
        .where((e) => e.id == selected.id)
        .firstOrNull;
    if (current == null ||
        annotationHash(current) != annotationHash(selected)) {
      error = 'Операция изменилась. Откройте её метки заново.';
      notifyListeners();
      return false;
    }
    final tag = EntryAnnotation(
      entryId: current.id,
      sourceHash: annotationHash(current),
      reviewedOn: request.today,
      role: role,
      counterparty: counterparty,
      oneOff: oneOff,
    );
    return updateProfile({
      'annotations': {
        ...policy.profile.toJson()['annotations'] as Map,
        current.id: tag.toJson(),
      },
    });
  }

  Future<bool> expectRefund({
    required String id,
    required Purchase purchase,
    required int amountMinor,
    required DateTime due,
  }) async {
    final request = _request;
    if (request == null || purchase.entryId == null) {
      error = 'Сначала свяжите покупку с исходным расходом.';
      notifyListeners();
      return false;
    }
    final current = request.snapshot.purchases
        .where((p) => p.id == purchase.id)
        .firstOrNull;
    if (current == null ||
        seriesDigest(current.toJson()) != seriesDigest(purchase.toJson())) {
      error = 'Покупка изменилась. Откройте форму заново.';
      notifyListeners();
      return false;
    }
    final previous = policy.profile.refunds
        .where((r) => r.id == id)
        .firstOrNull;
    final baseline = previous?.purchaseId == current.id
        ? previous!.baselineRefundMinor
        : sumMinor(
            request.snapshot.entries
                .where(
                  (e) =>
                      e.kind == EntryKind.refund &&
                      e.refundOf == current.entryId &&
                      !e.date.isAfter(request.today),
                )
                .map((e) => e.amountMinor),
          );
    final expected = ExpectedRefund(
      id: id,
      purchaseId: current.id,
      purchaseHash: seriesDigest(current.toJson()),
      expectedMinor: amountMinor,
      baselineRefundMinor: baseline,
      due: due,
    );
    return updateProfile({
      'refunds': [
        ...policy.profile.refunds
            .where((r) => r.id != id)
            .map((r) => r.toJson()),
        expected.toJson(),
      ],
    });
  }

  Future<bool> trackRecommendation(Insight insight) async {
    final request = _request;
    if (request == null || !{'J1', 'J4'}.contains(insight.rule)) return false;
    final f = AnalysisFacts(
      request.snapshot,
      request.month,
      request.today,
      profile: policy.profile,
    );
    if (f.current || f.future || !f.covered(policy, f.end)) {
      error = 'Для отслеживания выберите завершённый месяц и подтвердите полноту его учёта.';
      notifyListeners();
      return false;
    }
    final category = policy.profile.category(insight.entity),
        baseline = f.categories[category] ?? 0;
    if (baseline <= 0) {
      error = 'Нужна положительная база расходов категории.';
      notifyListeners();
      return false;
    }
    final target = insight.rule == 'J4'
        ? policy.profile.flexibleCaps.entries
              .where((e) => policy.profile.category(e.key) == category)
              .firstOrNull
              ?.value
        : baseline - percentMinor(baseline, policy.scenarioPercent);
    if (target == null) return false;
    final tracked = TrackedAdvice(
      id: seriesDigest([category, monthKey(f.start)]),
      category: category,
      baselineMonth: f.start,
      baselineMinor: baseline,
      targetMinor: target,
      baselineHash: coverageHash(request.snapshot, f.end),
    );
    return updateProfile({
      'tracked': [
        ...policy.profile.tracked
            .where((r) => r.id != tracked.id)
            .map((r) => r.toJson()),
        tracked.toJson(),
      ],
    });
  }

  Future<bool> confirmBackupExport() async {
    final request = _request;
    if (request == null) return false;
    return updateProfile({'lastBackupOn': calendarDate(request.today)});
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
