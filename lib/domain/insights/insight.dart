import '../models.dart';
import 'series_review.dart';
import 'analysis_profile.dart';

import 'dart:convert';

import 'package:cryptography/dart.dart';

String coverageHash(LedgerSnapshot snapshot, DateTime through) {
  final start = DateTime(through.year, through.month);
  final entries =
      snapshot.entries
          .where((e) => !e.date.isBefore(start) && !e.date.isAfter(through))
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  return const DartSha256()
      .hashSync(
        utf8.encode(
          jsonEncode([
            snapshot.currency,
            calendarDate(through),
            entries.map((e) => e.toJson()).toList(),
          ]),
        ),
      )
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

const insightRules = <String, String>{
  'A1': 'Денежный поток',
  'A2': 'Изменение остатка',
  'A4': 'Распределение денег по счетам',
  'A3': 'Отрицательный остаток',
  'A5': 'Расходы выше доходов',
  'A6': 'Доступные деньги и резервы',
  'B1': 'Изменение общих расходов',
  'B2': 'Изменение категории',
  'B3': 'Устойчивый рост расходов',
  'B4': 'Средняя сумма покупки',
  'B5': 'Частота покупок',
  'B6': 'Новая заметная категория',
  'C1': 'Крупнейшие категории',
  'C2': 'Крупнейшие расходы',
  'C3': 'Основная доля расходов',
  'C5': 'Мелкие частые расходы',
  'C4': 'Обязательные и гибкие расходы',
  'C6': 'Подтверждённые продавцы',
  'D1': 'Приближение к лимиту',
  'D2': 'Превышение лимита',
  'D3': 'Остаток на день',
  'D4': 'Сценарное превышение лимита',
  'D5': 'Повторяющиеся превышения лимита',
  'D6': 'Предложение начального лимита',
  'E1': 'Изменение доходов',
  'E2': 'Ожидаемое поступление просрочено',
  'E3': 'Регулярность поступлений',
  'E4': 'Концентрация источников дохода',
  'E5': 'Нестабильность месячного дохода',
  'E6': 'Расходы растут быстрее доходов',
  'F1': 'Ближайшие платежи',
  'F2': 'Просроченные платежи',
  'F3': 'Пробные периоды',
  'F4': 'Регулярные платежи за 12 месяцев',
  'F5': 'Несколько списаний за день',
  'F6': 'Оплата отличается от плана',
  'G1': 'Возможная ежемесячная трата',
  'G2': 'Возможная еженедельная трата',
  'G3': 'Возможное ежегодное списание',
  'G4': 'Изменение стоимости серии',
  'G5': 'Возможные дубли планов',
  'G6': 'Связь серии с планом',
  'H1': 'Необычно крупная сумма',
  'H2': 'Необычная сумма за день',
  'H3': 'Необычный месячный итог',
  'H4': 'Возможные дубликаты операций',
  'H5': 'Возможная ошибка разряда',
  'H6': 'Необычная частота покупок',
  'I1': 'Остаток после известных платежей',
  'I2': 'Возможный отрицательный остаток',
  'I3': 'Нехватка на отдельном счёте',
  'I4': 'Прогноз переменных расходов',
  'I6': 'Качество и диапазон прогноза',
  'I5': 'Задержка ожидаемого дохода',
  'J1': 'Сценарий сокращения категории',
  'J2': 'Сценарий паузы платежа',
  'J3': 'Сокращение мелких покупок',
  'J4': 'Потолок гибкой категории',
  'J5': 'Сводный сценарий экономии',
  'J6': 'Влияние сценария на остаток',
  'K1': 'Доля дохода после расходов',
  'K2': 'Резерв в месяцах расходов',
  'K3': 'Прогресс цели',
  'K4': 'Пополнение цели к сроку',
  'K5': 'Отставание от плана цели',
  'K6': 'Календарь погашения долга',
  'L1': 'Срок возврата',
  'L2': 'Гарантия',
  'L3': 'У покупки со сроком нет документа',
  'L4': 'Стоимость после возвратов',
  'L5': 'Связь покупки с расходом',
  'L6': 'Ожидаемый возврат',
  'M1': 'Достаточность истории',
  'M2': 'Разные написания категории',
  'M3': 'Будущие даты операций',
  'M4': 'Подтверждение полноты учёта',
  'M5': 'Предложения алиасов',
  'M6': 'Давность внешней резервной копии',
  'N1': 'Расходы по дням недели',
  'N2': 'Выходные и будни',
  'N3': 'Расходы после регулярного дохода',
  'N4': 'Сезонные месяцы',
  'N5': 'Повторение крупных годовых расходов',
  'N6': 'Изменение привычного уровня расходов',
  'O1': 'Недельная сводка',
  'O2': 'Итоги завершённого месяца',
  'O3': 'Причины изменения расходов',
  'O4': 'Результат выбранной рекомендации',
  'O5': 'Персональные пороги',
  'O6': 'Настройки выдачи',
};

enum InsightGroup {
  expenses,
  payments,
  scenarios,
  quality,
  summaries,
  patterns,
  planning,
}

enum InsightKind { fact, scenario, check, insufficient }

enum EvidenceKind { entry, account, budget, obligation, purchase, profile }

class InsightEvidence {
  const InsightEvidence(this.kind, this.id);
  final EvidenceKind kind;
  final String id;
  @override
  bool operator ==(Object other) =>
      other is InsightEvidence && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

class InsightDay {
  const InsightDay(this.date, this.balanceMinor);
  final DateTime date;
  final int balanceMinor;
}

class Insight {
  Insight({
    required this.rule,
    required this.entity,
    required this.period,
    required this.title,
    required this.explanation,
    required this.group,
    this.kind = InsightKind.fact,
    this.priority = 0,
    this.seriesProposal,
    this.timelineTitle = 'Остаток на конец дня',
    Iterable<InsightDay> timeline = const [],
    Map<String, int> amounts = const {},
    Iterable<InsightEvidence> evidence = const [],
  }) : timeline = List.unmodifiable(timeline),
       amounts = Map.unmodifiable(amounts),
       evidence = List.unmodifiable(
         evidence.toSet().toList()..sort((a, b) {
           final kind = a.kind.index.compareTo(b.kind.index);
           return kind != 0 ? kind : a.id.compareTo(b.id);
         }),
       );
  final String rule, entity, period, title, explanation;
  final InsightGroup group;
  final InsightKind kind;
  final int priority;
  final SeriesProposal? seriesProposal;
  final String timelineTitle;
  final List<InsightDay> timeline;
  final Map<String, int> amounts;
  final List<InsightEvidence> evidence;
  String get key => '$rule:$entity:${period.substring(0, 7)}';
}

String categoryKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String monthKey(DateTime date) =>
    calendarDate(DateTime(date.year, date.month)).substring(0, 7);

List<Insight> selectInsightPreview(Iterable<Insight> results) {
  const flow = {'A1', 'A2', 'A4', 'K1', 'O2'};
  const changes = {'B1', 'B2', 'B4', 'B5', 'B6', 'E1', 'E6', 'O3'};
  final chosen = <Insight>[], families = <String>{};
  for (final insight in results) {
    final family = flow.contains(insight.rule)
        ? 'flow'
        : {'I1', 'I2', 'I4', 'I5', 'I6', 'J6'}.contains(insight.rule)
        ? 'calendar'
        : changes.contains(insight.rule)
        ? 'changes'
        : {'D1', 'D2', 'D3', 'D4', 'D5'}.contains(insight.rule)
        ? 'budget:${insight.entity}'
        : insight.key;
    if (!families.add(family)) continue;
    chosen.add(insight);
    if (chosen.length == 3) break;
  }
  return List.unmodifiable(chosen);
}

class AnalysisPolicy {
  AnalysisPolicy({
    this.minimumChangeMinor = 1000,
    this.changePercent = 20,
    this.nearLimitPercent = 80,
    this.scenarioPercent = 10,
    this.smallExpenseMinor = 500,
    this.incomeDelayDays = 7,
    Iterable<String> disabled = const [],
    Iterable<String> hidden = const [],
    Map<String, String> snoozed = const {},
    Map<String, String> verifiedThrough = const {},
    Map<String, String> verifiedHashes = const {},
    Map<String, SeriesReview> seriesReviews = const {},
    AnalysisProfile? profile,
  }) : disabled = Set.unmodifiable(disabled),
       hidden = Set.unmodifiable(hidden),
       snoozed = Map.unmodifiable(snoozed),
       verifiedThrough = Map.unmodifiable(verifiedThrough),
       verifiedHashes = Map.unmodifiable(verifiedHashes),
       seriesReviews = Map.unmodifiable(seriesReviews),
       profile = AnalysisProfile.fromJson(
         (profile ?? AnalysisProfile()).toJson(),
       ) {
    if (seriesReviews.length > 500 ||
        seriesReviews.entries.any((e) => e.key != e.value.proposal.key)) {
      throw const FormatException(
        'Слишком много или некорректные решения по сериям',
      );
    }
    final linked = seriesReviews.values
        .map((r) => r.planLink?.planId)
        .whereType<String>()
        .toList();
    if (linked.toSet().length != linked.length ||
        seriesReviews.values.any(
          (r) => r.planLink != null && r.decision != SeriesDecision.accepted,
        )) {
      throw const FormatException(
        'План можно связать только с одной подтверждённой серией',
      );
    }
    if (incomeDelayDays < 1 ||
        incomeDelayDays > 90 ||
        minimumChangeMinor < 1 ||
        minimumChangeMinor > 900000000000000 ||
        changePercent < 1 ||
        changePercent > 1000 ||
        nearLimitPercent < 1 ||
        nearLimitPercent > 100 ||
        scenarioPercent < 1 ||
        scenarioPercent > 100 ||
        smallExpenseMinor < 1 ||
        smallExpenseMinor > 900000000000000) {
      throw const FormatException('Проверьте пороги анализа');
    }
  }
  final int minimumChangeMinor,
      changePercent,
      nearLimitPercent,
      scenarioPercent,
      smallExpenseMinor;
  final int incomeDelayDays;
  final Set<String> disabled, hidden;
  final Map<String, String> snoozed, verifiedThrough, verifiedHashes;
  final Map<String, SeriesReview> seriesReviews;
  final AnalysisProfile profile;
  int minimumFor(String rule, [String? category]) => category != null
      ? profile.categoryMinimums.entries
                .where(
                  (e) => profile.category(e.key) == profile.category(category),
                )
                .firstOrNull
                ?.value ??
            profile.ruleMinimums[rule] ??
            minimumChangeMinor
      : profile.ruleMinimums[rule] ?? minimumChangeMinor;

  AnalysisPolicy copyWith({
    int? minimumChangeMinor,
    int? changePercent,
    int? nearLimitPercent,
    int? scenarioPercent,
    int? smallExpenseMinor,
    int? incomeDelayDays,
    Set<String>? disabled,
    Set<String>? hidden,
    Map<String, String>? snoozed,
    Map<String, String>? verifiedThrough,
    Map<String, String>? verifiedHashes,
    Map<String, SeriesReview>? seriesReviews,
    AnalysisProfile? profile,
  }) => AnalysisPolicy(
    minimumChangeMinor: minimumChangeMinor ?? this.minimumChangeMinor,
    changePercent: changePercent ?? this.changePercent,
    nearLimitPercent: nearLimitPercent ?? this.nearLimitPercent,
    scenarioPercent: scenarioPercent ?? this.scenarioPercent,
    smallExpenseMinor: smallExpenseMinor ?? this.smallExpenseMinor,
    incomeDelayDays: incomeDelayDays ?? this.incomeDelayDays,
    disabled: disabled ?? this.disabled,
    hidden: hidden ?? this.hidden,
    snoozed: snoozed ?? this.snoozed,
    verifiedThrough: verifiedThrough ?? this.verifiedThrough,
    verifiedHashes: verifiedHashes ?? this.verifiedHashes,
    seriesReviews: seriesReviews ?? this.seriesReviews,
    profile: profile ?? this.profile,
  );

  bool covers(DateTime date, LedgerSnapshot snapshot) {
    final through = verifiedThrough[monthKey(date)];
    if (through == null || through.compareTo(calendarDate(date)) < 0) {
      return false;
    }
    return verifiedHashes[monthKey(date)] ==
        coverageHash(snapshot, parseCalendarDate(through));
  }

  bool shows(Insight insight, DateTime today) =>
      !disabled.contains(insight.rule) &&
      !hidden.contains(insight.key) &&
      (snoozed[insight.key] ?? '').compareTo(calendarDate(today)) <= 0;
  Map<String, Object> toJson() => {
    'version': 1,
    'minimumChangeMinor': minimumChangeMinor,
    'changePercent': changePercent,
    'nearLimitPercent': nearLimitPercent,
    'scenarioPercent': scenarioPercent,
    'smallExpenseMinor': smallExpenseMinor,
    'incomeDelayDays': incomeDelayDays,
    'profile': profile.toJson(),
    'disabled': disabled.toList()..sort(),
    'hidden': hidden.toList()..sort(),
    'snoozed': snoozed,
    'verifiedThrough': verifiedThrough,
    'verifiedHashes': verifiedHashes,
    'seriesReviews': {
      for (final entry in seriesReviews.entries)
        entry.key: entry.value.toJson(),
    },
  };

  factory AnalysisPolicy.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Неизвестная версия настроек анализа');
    }
    Map<String, String> dates(String key, {bool months = false}) {
      final source = json[key] as Map;
      return source.map((k, v) {
        if (k is! String || v is! String) {
          throw const FormatException('Некорректные настройки анализа');
        }
        final date = parseCalendarDate(v);
        if (months && monthKey(date) != k) {
          throw const FormatException('Некорректный период');
        }
        return MapEntry(k, calendarDate(date));
      });
    }

    return AnalysisPolicy(
      minimumChangeMinor: json['minimumChangeMinor'] as int,
      changePercent: json['changePercent'] as int,
      nearLimitPercent: json['nearLimitPercent'] as int,
      scenarioPercent: json['scenarioPercent'] as int,
      smallExpenseMinor: json['smallExpenseMinor'] as int? ?? 500,
      incomeDelayDays: json['incomeDelayDays'] as int? ?? 7,
      profile: json['profile'] == null
          ? AnalysisProfile()
          : AnalysisProfile.fromJson(
              Map<String, dynamic>.from(json['profile'] as Map),
            ),
      disabled: (json['disabled'] as List).cast<String>(),
      hidden: (json['hidden'] as List).cast<String>(),
      snoozed: dates('snoozed'),
      verifiedThrough: dates('verifiedThrough', months: true),
      verifiedHashes: (json['verifiedHashes'] as Map? ?? {})
          .cast<String, String>(),
      seriesReviews: (json['seriesReviews'] as Map? ?? {}).map(
        (key, value) => MapEntry(
          key as String,
          SeriesReview.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
    );
  }
}
