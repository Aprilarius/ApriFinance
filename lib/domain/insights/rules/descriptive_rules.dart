import '../../models.dart';
import '../analysis_facts.dart';
import '../insight.dart';

List<Insight> descriptiveInsights(
  AnalysisFacts f,
  AnalysisPolicy policy, {
  required bool comparisonsAllowed,
}) {
  final s = f.snapshot, result = <Insight>[];
  List<InsightEvidence> refs(Iterable<LedgerEntry> entries) =>
      entries.map((e) => InsightEvidence(EvidenceKind.entry, e.id)).toList();
  void add(
    String rule,
    String entity,
    String title,
    String explanation, {
    Map<String, int> amounts = const {},
    Iterable<InsightEvidence> evidence = const [],
    InsightGroup group = InsightGroup.expenses,
    InsightKind kind = InsightKind.fact,
    int priority = 0,
  }) {
    result.add(
      Insight(
        rule: rule,
        entity: entity,
        period: f.period,
        title: title,
        explanation: explanation,
        amounts: amounts,
        evidence: evidence,
        group: group,
        kind: kind,
        priority: priority,
      ),
    );
  }

  final period = '${calendarDate(f.start)} — ${calendarDate(f.end)}';
  final expenses = f.entries.where((e) => e.kind == EntryKind.expense).toList();
  final grossCategories = <String, List<LedgerEntry>>{};
  for (final e in expenses) {
    grossCategories
        .putIfAbsent(f.canonicalCategory(e.category), () => [])
        .add(e);
  }
  if (f.entries.isNotEmpty) {
    final change = difference(f.income, f.netExpense),
        after = sumMinor(f.balances.values);
    add(
      'A2',
      'balance',
      'Как изменился остаток',
      'Период $period. Изменение равно доходам минус чистые расходы; переводы между своими счетами исключены. Начальные остатки включены в оба среза, их даты в базе не хранятся.',
      amounts: {
        'На начало периода': difference(after, change),
        'На конец периода': after,
        'Изменение': change,
      },
      evidence: refs(f.entries),
    );
  }
  final positive = s.accounts.where((a) => (f.balances[a.id] ?? 0) > 0).toList()
    ..sort((a, b) {
      final d = f.balances[b.id]!.compareTo(f.balances[a.id]!);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
  final positiveTotal = sumMinor(positive.map((a) => f.balances[a.id]!));
  for (final a in positive.take(3)) {
    final share =
        BigInt.from(f.balances[a.id]!) *
        BigInt.from(100) ~/
        BigInt.from(positiveTotal);
    add(
      'A4',
      a.id,
      'Деньги на счёте: ${a.name}',
      'На ${calendarDate(f.end)}: $share% суммы положительных остатков (процент округлён вниз). Отрицательные остатки показаны отдельно и не уменьшают знаменатель этой структуры.',
      amounts: {
        'На этом счёте': f.balances[a.id]!,
        'Положительные остатки всех счетов': positiveTotal,
      },
      evidence: [InsightEvidence(EvidenceKind.account, a.id)],
    );
  }
  if (f.gross > 0) {
    final ranked =
        grossCategories.entries
            .map(
              (e) => MapEntry(
                e.key,
                AnalysisFacts.total(e.value, EntryKind.expense),
              ),
            )
            .toList()
          ..sort((a, b) {
            final d = b.value.compareTo(a.value);
            return d != 0 ? d : a.key.compareTo(b.key);
          });
    var accumulated = BigInt.zero;
    final selected = <String>[];
    for (final c in ranked) {
      selected.add(c.key);
      accumulated += BigInt.from(c.value);
      if (accumulated * BigInt.from(100) >=
          BigInt.from(f.gross) * BigInt.from(80)) {
        break;
      }
    }
    add(
      'C3',
      'concentration',
      'Что формирует основную часть расходов',
      'Не менее 80% списаний до возвратов за $period: ${selected.take(5).join(', ')}${selected.length > 5 ? ' и ещё ${selected.length - 5}' : ''}. Большая доля не означает, что траты ненужные.',
      amounts: {
        'Расходы этих категорий': checked(accumulated),
        'Все расходы до возвратов': f.gross,
      },
      evidence: refs(selected.expand((key) => grossCategories[key]!)),
    );
  }
  final small = expenses
      .where(
        (e) =>
            e.amountMinor <=
            (policy.profile.ruleMinimums['C5'] ?? policy.smallExpenseMinor),
      )
      .toList();
  if (small.length >= 5) {
    add(
      'C5',
      'small',
      'Мелкие расходы в сумме',
      '${small.length} списаний не больше заданного порога за $period. Показана сумма исходных расходов; возвраты в неё не вычитались. Это описание, а не оценка необходимости покупок.',
      amounts: {
        'Порог одной покупки':
            policy.profile.ruleMinimums['C5'] ?? policy.smallExpenseMinor,
        'В сумме': sumMinor(small.map((e) => e.amountMinor)),
      },
      evidence: refs(small),
    );
  }
  if (f.income > 0) {
    final remaining = difference(f.income, f.netExpense);
    final ratio =
        BigInt.from(remaining) * BigInt.from(100) ~/ BigInt.from(f.income);
    add(
      'K1',
      'remaining_income',
      'Доля дохода после расходов',
      'За $period разница составляет $ratio% внесённого дохода (округление к нулю). Это показатель денежного потока, а не подтверждённые накопления. Поздние возвраты могут сделать долю больше 100%.',
      amounts: {
        'Доходы': f.income,
        'Разница доходов и чистых расходов': remaining,
      },
      evidence: refs(f.entries),
    );
  }
  final documented = s.documents.map((d) => d.purchaseId).toSet();
  for (final p in s.purchases.where(
    (p) =>
        !p.archived &&
        !p.date.isAfter(f.end) &&
        (p.returnBy != null || p.warrantyUntil != null) &&
        !documented.contains(p.id),
  )) {
    add(
      'L3',
      p.id,
      'У покупки нет документа: ${p.name}',
      'В карточке указаны сроки возврата или гарантии, но вложений нет. Можно добавить чек или условия продавца; наличие файла само по себе не подтверждает его содержание.',
      group: InsightGroup.quality,
      kind: InsightKind.check,
      evidence: [InsightEvidence(EvidenceKind.purchase, p.id)],
    );
  }
  final previous = s.entries
      .where(
        (e) => AnalysisFacts.within(e.date, f.comparisonStart, f.comparisonEnd),
      )
      .toList();
  final current = s.entries
      .where((e) => AnalysisFacts.within(e.date, f.start, f.comparableEnd))
      .toList();
  if (comparisonsAllowed) {
    final prevExpenses = previous
        .where((e) => e.kind == EntryKind.expense)
        .toList();
    final curExpenses = current
        .where((e) => e.kind == EntryKind.expense)
        .toList();
    final previousGross = AnalysisFacts.total(prevExpenses, EntryKind.expense),
        currentGross = AnalysisFacts.total(curExpenses, EntryKind.expense);
    final comparePeriod =
        '${calendarDate(f.start)} — ${calendarDate(f.comparableEnd)} против ${calendarDate(f.comparisonStart)} — ${calendarDate(f.comparisonEnd)}';
    bool significant(int a, int b) =>
        (BigInt.from(a) - BigInt.from(b)).abs() >=
            BigInt.from(policy.minimumChangeMinor) &&
        (b <= 0 ||
            (BigInt.from(a) - BigInt.from(b)).abs() * BigInt.from(100) >=
                BigInt.from(b) * BigInt.from(policy.changePercent));
    if (curExpenses.length >= 3 && prevExpenses.length >= 3) {
      final a = currentGross ~/ curExpenses.length,
          b = previousGross ~/ prevExpenses.length;
      final averageDifference =
          (BigInt.from(currentGross) * BigInt.from(prevExpenses.length) -
                  BigInt.from(previousGross) * BigInt.from(curExpenses.length))
              .abs();
      final absoluteMet =
          averageDifference >=
          BigInt.from(policy.minimumChangeMinor) *
              BigInt.from(curExpenses.length) *
              BigInt.from(prevExpenses.length);
      final relativeMet =
          previousGross <= 0 ||
          averageDifference * BigInt.from(100) >=
              BigInt.from(previousGross) *
                  BigInt.from(curExpenses.length) *
                  BigInt.from(policy.changePercent);
      if (absoluteMet && relativeMet) {
        add(
          'B4',
          'average',
          'Изменилась средняя сумма покупки',
          '$comparePeriod. В расчёте ${curExpenses.length} и ${prevExpenses.length} исходных списаний; возвраты не считаются покупками. Средние округлены вниз до минимальной единицы валюты.',
          amounts: {
            'Сейчас в среднем': a,
            'Раньше в среднем': b,
            'Разница средних': difference(a, b),
          },
          evidence: refs([...curExpenses, ...prevExpenses]),
        );
      }
    }
    final countDelta = curExpenses.length - prevExpenses.length;
    if (prevExpenses.isNotEmpty &&
        countDelta.abs() >= 2 &&
        BigInt.from(countDelta.abs()) * BigInt.from(100) >=
            BigInt.from(prevExpenses.length) *
                BigInt.from(policy.changePercent)) {
      add(
        'B5',
        'frequency',
        'Изменилась частота покупок',
        '$comparePeriod: ${curExpenses.length} списаний против ${prevExpenses.length}; разница ${countDelta > 0 ? '+' : ''}$countDelta. Это число записей, а не число товаров.',
        amounts: {
          'Списания сейчас': currentGross,
          'Списания раньше': previousGross,
        },
        evidence: refs([...curExpenses, ...prevExpenses]),
      );
    }
    final seen = s.entries
        .where((e) => e.kind == EntryKind.expense && e.date.isBefore(f.start))
        .map((e) => f.canonicalCategory(e.category))
        .toSet();
    final newCategories = <String, List<LedgerEntry>>{};
    for (final e in curExpenses) {
      if (!seen.contains(f.canonicalCategory(e.category))) {
        newCategories
            .putIfAbsent(f.canonicalCategory(e.category), () => [])
            .add(e);
      }
    }
    for (final c in newCategories.entries) {
      final amount = sumMinor(c.value.map((e) => e.amountMinor));
      if (amount < policy.minimumChangeMinor) continue;
      add(
        'B6',
        c.key,
        'Новая заметная категория: ${c.key}',
        'В текущем сравнительном отрезке есть списания, а в более ранних внесённых расходах категория не найдена. Это не доказывает, что раньше таких трат не было.',
        amounts: {'Расходы в текущем сравнении': amount},
        evidence: refs(c.value),
      );
    }
    final beforeNet = difference(
      previousGross,
      AnalysisFacts.total(previous, EntryKind.refund),
    );
    final currentNet = difference(
      currentGross,
      AnalysisFacts.total(current, EntryKind.refund),
    );
    final oldIncome = AnalysisFacts.total(previous, EntryKind.income),
        newIncome = AnalysisFacts.total(current, EntryKind.income);
    if (beforeNet > 0 &&
        currentNet > beforeNet &&
        oldIncome > 0 &&
        newIncome > 0 &&
        significant(currentNet, beforeNet) &&
        BigInt.from(currentNet) * BigInt.from(oldIncome) >
            BigInt.from(newIncome) * BigInt.from(beforeNet)) {
      add(
        'E6',
        'relative_growth',
        'Расходы растут быстрее доходов',
        '$comparePeriod. Сравниваются отношения сумм без округления процентов. Это описание внесённых данных; причины роста не предполагаются.',
        amounts: {
          'Чистые расходы сейчас': currentNet,
          'Чистые расходы раньше': beforeNet,
          'Доход сейчас': newIncome,
          'Доход раньше': oldIncome,
        },
        evidence: refs(
          [...current, ...previous].where((e) => e.kind != EntryKind.transfer),
        ),
        priority: 25,
      );
    }
    final c = f.categoryTotals(current), p = f.categoryTotals(previous);
    final contributions = <String, int>{
      for (final key in {...c.keys, ...p.keys})
        key: difference(c[key] ?? 0, p[key] ?? 0),
    };
    final delta = difference(currentNet, beforeNet);
    if (BigInt.from(delta).abs() >= BigInt.from(policy.minimumChangeMinor)) {
      final ranked = contributions.entries.where((e) => e.value != 0).toList()
        ..sort((a, b) {
          final d = BigInt.from(b.value)
              .abs()
              .compareTo(BigInt.from(a.value).abs());
          return d != 0 ? d : a.key.compareTo(b.key);
        });
      final amounts = <String, int>{'Общее изменение': delta};
      for (final c in ranked.take(3)) {
        amounts['Вклад категории «${c.key}»'] = c.value;
      }
      amounts['Остальные категории'] = difference(
        delta,
        sumMinor(ranked.take(3).map((e) => e.value)),
      );
      add(
        'O3',
        'drivers',
        'За счёт чего изменились расходы',
        '$comparePeriod. Положительный вклад увеличивает расходы, отрицательный уменьшает. Вклады категорий и остаток в сумме равны общему изменению; возвраты учитываются в дату получения.',
        group: InsightGroup.summaries,
        amounts: amounts,
        evidence: refs(
          [...current, ...previous].where(
            (e) => e.kind == EntryKind.expense || e.kind == EntryKind.refund,
          ),
        ),
      );
    }
  }
  final weekStart = DateTime(f.end.year, f.end.month, f.end.day - 6);
  final week = s.entries
      .where((e) => AnalysisFacts.within(e.date, weekStart, f.end))
      .toList();
  if (week.isNotEmpty) {
    final gross = AnalysisFacts.total(week, EntryKind.expense),
        returned = AnalysisFacts.total(week, EntryKind.refund);
    add(
      'O1',
      calendarDate(weekStart),
      'Сводка за последние 7 дней периода',
      '${calendarDate(weekStart)} — ${calendarDate(f.end)}. По внесённым операциям; это скользящий семидневный отрезок, а не календарная неделя. Планы отдельно от фактических денег.',
      group: InsightGroup.summaries,
      amounts: {
        'Доходы': AnalysisFacts.total(week, EntryKind.income),
        'Расходы до возвратов': gross,
        'Возвраты': returned,
        'Чистые расходы': difference(gross, returned),
      },
      evidence: refs(week),
    );
  }
  if (!f.current && f.covered(policy, f.end)) {
    add(
      'O2',
      'closed_month',
      'Итоги завершённого месяца',
      '$period. Полнота внесённых операций подтверждена владельцем. Планы, начальные остатки и переводы не входят в доходы/расходы.',
      group: InsightGroup.summaries,
      amounts: {
        'Доходы': f.income,
        'Расходы до возвратов': f.gross,
        'Возвраты': f.returned,
        'Чистые расходы': f.netExpense,
        'Разница': difference(f.income, f.netExpense),
      },
      evidence: refs(f.entries),
    );
  }
  final months = [
    for (var n = 3; n >= 1; n--) DateTime(f.start.year, f.start.month - n),
  ];
  if (months.every(
    (m) => f.covered(policy, DateTime(m.year, m.month + 1, 0)),
  )) {
    final history = <String, List<LedgerEntry>>{
      for (final m in months) monthKey(m): [],
    };
    for (final e in s.entries) {
      history[monthKey(e.date)]?.add(e);
    }
    final netByMonth = {
      for (final m in months)
        monthKey(m): f.categoryTotals(history[monthKey(m)]!),
    };
    final currentBudgets = {
      for (final b in s.budgets.where((b) => b.month == monthKey(f.start)))
        f.canonicalCategory(b.category): b,
    };
    for (final b in currentBudgets.entries) {
      if (!f.unambiguousBudget(b.value)) continue;
      final past = [
        for (final m in months)
          s.budgets
              .where(
                (old) =>
                    old.month == monthKey(m) &&
                    f.unambiguousBudget(old) &&
                    f.canonicalCategory(old.category) == b.key,
              )
              .firstOrNull,
      ];
      if (past.any((b) => b == null)) continue;
      final exceeded = [
        for (var n = 0; n < months.length; n++)
          if ((netByMonth[monthKey(months[n])]![b.key] ?? 0) >
              past[n]!.limitMinor)
            n,
      ];
      if (exceeded.length >= 2) {
        add(
          'D5',
          b.value.id,
          'Лимит часто превышался: ${b.key}',
          'Превышение в ${exceeded.length} из трёх подтверждённых завершённых месяцев. Каждый месяц сравнивается со своим сохранённым лимитом. Можно пересмотреть сумму или состав категории.',
          evidence: [
            InsightEvidence(EvidenceKind.budget, b.value.id),
            ...past.map((b) => InsightEvidence(EvidenceKind.budget, b!.id)),
            ...refs(
              history.values
                  .expand((e) => e)
                  .where((e) => f.canonicalCategory(e.category) == b.key),
            ),
          ],
        );
      }
    }
    final proposals = <({String category, int median, List<int> values})>[];
    final keys = netByMonth.values.expand((m) => m.keys).toSet();
    for (final key in keys.where((key) => !currentBudgets.containsKey(key))) {
      final values = [
        for (final m in months) netByMonth[monthKey(m)]![key] ?? 0,
      ]..sort();
      if (values.first < 0 || values[1] <= 0) continue;
      proposals.add((category: key, median: values[1], values: values));
    }
    proposals.sort((a, b) {
      final d = b.median.compareTo(a.median);
      return d != 0 ? d : a.category.compareTo(b.category);
    });
    for (final p in proposals.take(3)) {
      final proposed = difference(
        p.median,
        percentMinor(p.median, policy.scenarioPercent),
      );
      if (proposed <= 0) continue;
      add(
        'D6',
        p.category,
        'Ориентир лимита: ${p.category}',
        'Медиана чистых расходов за три подтверждённых завершённых месяца: ${months.map(monthKey).join(', ')}. Сценарий сокращения ${policy.scenarioPercent}%; текущего лимита нет. Это ориентир, не обязательная норма; лимит автоматически не создаётся.',
        group: InsightGroup.scenarios,
        kind: InsightKind.scenario,
        amounts: {'Медиана за месяц': p.median, 'Сценарный лимит': proposed},
        evidence: refs(
          history.values
              .expand((e) => e)
              .where((e) => f.canonicalCategory(e.category) == p.category),
        ),
      );
    }
  }
  return result;
}
