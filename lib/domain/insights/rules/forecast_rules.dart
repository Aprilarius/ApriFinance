import '../../models.dart';
import '../analysis_facts.dart';
import '../cash_calendar.dart';
import '../insight.dart';
import '../scenario_math.dart';
import '../variable_forecast.dart';

List<Insight> forecastInsights(AnalysisFacts f, AnalysisPolicy policy) {
  final result = <Insight>[],
      p = f.profile,
      s = f.snapshot,
      cuts = scenarioCuts(f, policy);
  void emit(
    String rule,
    String entity,
    String title,
    String explanation, {
    Map<String, int> amounts = const {},
    Iterable<InsightEvidence> evidence = const [],
    InsightKind kind = InsightKind.scenario,
    InsightGroup group = InsightGroup.scenarios,
    Iterable<InsightDay> timeline = const [],
    String timelineTitle = 'Сценарный остаток на конец дня',
  }) => result.add(
    Insight(
      rule: rule,
      entity: entity,
      period: f.period,
      title: title,
      explanation: explanation,
      group: group,
      kind: kind,
      amounts: amounts,
      evidence: evidence,
      timeline: timeline,
      timelineTitle: timelineTitle,
    ),
  );
  if (p.smallSkipCount > 0) {
    emit(
      'J3',
      'small',
      'Сценарий меньшего числа мелких покупок',
      'Выбрано не совершать до ${p.smallSkipCount} покупок. В примере взяты ${cuts.smallIds.length} явно гибких мелких расходов выбранного периода, в порядке даты и ID. Связанные возвраты вычтены; это не уже полученная экономия.',
      amounts: {
        'На выбранных покупках': sumMinor(
          cuts.smallIds.map(
            (id) =>
                f.entryById[id]!.amountMinor -
                sumMinor(
                  (f.refunds[id] ?? [])
                      .where((r) => !r.date.isAfter(f.end))
                      .map((r) => r.amountMinor),
                ),
          ),
        ),
      },
      evidence: [
        for (final id in cuts.smallIds) InsightEvidence(EvidenceKind.entry, id),
      ],
      kind: cuts.smallIds.isEmpty
          ? InsightKind.insufficient
          : InsightKind.scenario,
    );
  }
  for (final e in cuts.capSavings.entries) {
    emit(
      'J4',
      e.key,
      'Сценарий потолка гибкой категории: ${e.key}',
      'Предел выбран владельцем. Сравнение с явно гибкими расходами выбранного периода после связанных возвратов. Изменение поведения и будущая достижимость не предполагаются автоматически.',
      amounts: {
        'Выбранный потолок': p.flexibleCaps.entries
            .firstWhere((r) => p.category(r.key) == e.key)
            .value,
        'Разница на внесённых расходах': e.value,
      },
      evidence: f.entries
          .where((r) => p.category(r.category) == e.key)
          .map((r) => InsightEvidence(EvidenceKind.entry, r.id)),
    );
  }
  final configured =
      p.scenarioCategories.isNotEmpty ||
      p.smallSkipCount > 0 ||
      p.flexibleCaps.isNotEmpty ||
      p.pausePlanIds.isNotEmpty;
  if (configured) {
    emit(
      'J5',
      'combined',
      'Сводный пример выбранных сокращений',
      'Процент выбранных гибких категорий, мелкие покупки, потолки и расходы выбранных планов объединены по ID операции. Для пересекающихся предложений берётся наибольшее сокращение одной операции, не их сумма. Возвраты ограничивают доступную сумму. Это повторение внесённого периода, не прогноз будущих денег.',
      amounts: {'Сокращение без повторного учёта': sumMinor(cuts.cuts.values)},
      evidence: [
        for (final id in cuts.cuts.keys)
          InsightEvidence(EvidenceKind.entry, id),
        const InsightEvidence(EvidenceKind.profile, 'scenario'),
      ],
    );
  }
  if (!f.current) return result;
  if (s.entries.isEmpty && s.obligations.isEmpty && !p.touched) return result;
  final forecast = variableForecast(f, policy), calendar = cashCalendar(f);
  const assumptions =
      'Обучение использует только прошлые суммы; четыре rolling-проверки по 14 дней. Планы, связанные серии и подтверждённые разовые расходы исключаются по доступным на соответствующую дату меткам. Это ориентир, не обещание; редкие покупки могут отсутствовать в истории. Переменные траты добавляются с завтрашнего дня; остаток сегодня включает только внесённые события. Точность проверена на окнах 14 дней: продолжение на 30 и 90 дней отдельно не откалибровано. Диапазон — сценарий ошибки, не вероятностный интервал.';
  if (forecast.usable) {
    var cumulative = BigInt.zero;
    final timeline = <InsightDay>[];
    for (var n = 0; n <= 90; n++) {
      if (n > 0) cumulative += BigInt.from(forecast.days[n - 1].balanceMinor);
      timeline.add(
        InsightDay(
          calendar.days[n].date,
          checked(BigInt.from(calendar.days[n].balanceMinor) - cumulative),
        ),
      );
    }
    emit(
      'I4',
      'variable',
      'Ориентир переменных расходов',
      'Метод: ${forecastMethodLabel(forecast.method)}. ${forecast.reason} $assumptions',
      amounts: {
        'Переменные траты, 30 дней': forecast.total(30),
        'Переменные траты, 90 дней': forecast.total(90),
        'Остаток с ними, +30 дней': timeline[30].balanceMinor,
        'Остаток с ними, +90 дней': timeline[90].balanceMinor,
      },
      evidence: [...forecast.evidence, ...calendar.evidence],
      timeline: timeline,
    );
    final low = sumMinor(
          forecast.days
              .take(30)
              .map(
                (d) => (d.balanceMinor - forecast.meanErrorMinor).clamp(
                  0,
                  d.balanceMinor,
                ),
              ),
        ),
        high = checked(
          BigInt.from(forecast.total(30)) +
              BigInt.from(forecast.meanErrorMinor) * BigInt.from(30),
        );
    emit(
      'I6',
      'quality',
      'Проверка качества и сценарный диапазон',
      '${forecast.reason} Выбран ${forecastMethodLabel(forecast.method)}; сложный вариант берётся только при снижении MAE хотя бы на 5% против среднего. Диапазон трат на 30 дней: прогноз ± одна средняя абсолютная ошибка на каждый день, низ ограничен нулём. Он не имеет заявленной вероятности покрытия. $assumptions',
      amounts: {
        for (final e in forecast.errors.entries)
          'MAE: ${forecastMethodLabel(e.key)}': e.value,
        'Низкий сценарий трат, 30 дней': low,
        'Высокий сценарий трат, 30 дней': high,
        'Остаток при высоких тратах': difference(
          calendar.at(30).balanceMinor,
          high,
        ),
        'Остаток при низких тратах': difference(
          calendar.at(30).balanceMinor,
          low,
        ),
      },
      evidence: forecast.evidence,
      group: InsightGroup.quality,
    );
  } else {
    emit(
      'I6',
      'quality',
      'Переменный прогноз пока ограничен',
      '${forecast.reason} Календарь известных событий остаётся доступен. $assumptions',
      amounts: {
        for (final e in forecast.errors.entries)
          'MAE: ${forecastMethodLabel(e.key)}': e.value,
      },
      group: InsightGroup.quality,
      kind: InsightKind.insufficient,
      evidence: [const InsightEvidence(EvidenceKind.profile, 'history')],
    );
  }
  final monthEnd = DateTime(f.start.year, f.start.month + 1, 0),
      remainingDays = calendarDaysBetween(f.today, monthEnd);
  for (final budget in s.budgets.where(
    (b) => b.month == monthKey(f.start) && f.unambiguousBudget(b),
  )) {
    final category = p.category(budget.category),
        actual = f.categories[category] ?? 0;
    if (actual >= budget.limitMinor) continue;
    final known = sumMinor(
      calendar.expenses
          .where(
            (e) =>
                !e.date.isAfter(monthEnd) && p.category(e.category) == category,
          )
          .map((e) => e.amountMinor),
    );
    final variable = forecast.usable
            ? sumMinor(
                forecast.categoryDays
                    .take(remainingDays)
                    .map((e) => e[category] ?? 0),
              )
            : 0,
        projected = sumMinor([actual, known, variable]);
    if (projected > budget.limitMinor) {
      emit(
        'D4',
        budget.id,
        'Возможное превышение к концу месяца: ${budget.category}',
        '${forecast.usable ? 'Включён проверенный на прошлых окнах ориентир переменных трат.' : 'Даже известные события превышают лимит; переменный прогноз недоступен и не включён.'} Факт, ещё не учтённые известные события и переменный ориентир разделены; оплаченные планы не добавлены повторно.',
        amounts: {
          'Факт после возвратов': actual,
          'Известные будущие события, нетто': known,
          'Переменный ориентир': variable,
          'Сценарный итог': projected,
          'Лимит': budget.limitMinor,
        },
        evidence: [
          InsightEvidence(EvidenceKind.budget, budget.id),
          ...calendar.evidence,
          ...forecast.evidence,
        ],
      );
    }
  }
  if (configured) {
    final paused = s.obligations
            .where(
              (o) =>
                  o.kind == EntryKind.expense && p.pausePlanIds.contains(o.id),
            )
            .map((o) => o.id)
            .toSet(),
        modified = cashCalendar(f, pausedPlanIds: paused);
    var baseVariable = BigInt.zero, reducedVariable = BigInt.zero;
    final baseDays = <int>[], changedDays = <InsightDay>[];
    for (var n = 0; n <= 90; n++) {
      if (n > 0 && forecast.usable) {
        baseVariable += BigInt.from(forecast.days[n - 1].balanceMinor);
        var changed = BigInt.zero;
        for (final category in forecast.categoryDays[n - 1].entries) {
          final reference = cuts.variableBase[category.key] ?? 0,
              reduction = cuts.variableCuts[category.key] ?? 0;
          final cut = reference <= 0
              ? BigInt.zero
              : BigInt.from(category.value) *
                    BigInt.from(reduction.clamp(0, reference)) ~/
                    BigInt.from(reference);
          changed += BigInt.from(category.value) - cut;
        }
        reducedVariable += changed;
      }
      baseDays.add(
        checked(BigInt.from(calendar.days[n].balanceMinor) - baseVariable),
      );
      changedDays.add(
        InsightDay(
          modified.days[n].date,
          checked(BigInt.from(modified.days[n].balanceMinor) - reducedVariable),
        ),
      );
    }
    emit(
      'J6',
      'future-scenario',
      'Как выбранный сценарий меняет остаток',
      '${forecast.usable ? 'Переменная часть уменьшена в долях выбранных сокращений на внесённых расходах текущего периода.' : 'Переменный прогноз недоступен: сравнивается только календарь известных событий.'} Пауза выбранных расходных планов применяется только к ещё не оплаченным периодам. Будущие внесённые операции не удаляются. Уже исключённые из переменной модели связанные планы не сокращаются второй раз; результат не обещает реальной экономии.',
      amounts: {
        'База, +30 дней': baseDays[30],
        'Сценарий, +30 дней': changedDays[30].balanceMinor,
        'Разница, +30 дней': difference(
          changedDays[30].balanceMinor,
          baseDays[30],
        ),
        'База, +90 дней': baseDays[90],
        'Сценарий, +90 дней': changedDays[90].balanceMinor,
      },
      evidence: [
        ...calendar.evidence,
        ...forecast.evidence,
        const InsightEvidence(EvidenceKind.profile, 'scenario'),
      ],
      timeline: changedDays,
    );
  }
  return result;
}
