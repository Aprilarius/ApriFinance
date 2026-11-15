import '../models.dart';
import '../schedule_math.dart';
import 'analysis_facts.dart';
import 'insight.dart';
import 'rules/descriptive_rules.dart';
import 'rules/pattern_rules.dart';
import 'rules/confirmed_series_rules.dart';
import 'rules/calendar_rules.dart';
import 'rules/personal_rules.dart';
import 'rules/history_rules.dart';
import 'rules/forecast_rules.dart';

class InsightEngine {
  List<Insight> analyze(
    LedgerSnapshot snapshot,
    DateTime month,
    DateTime now,
    AnalysisPolicy policy,
  ) {
    final f = AnalysisFacts(snapshot, month, now, profile: policy.profile);
    if (snapshot.currency == null) return [];
    final result = <Insight>[];
    void add(
      String rule,
      String entity,
      String title,
      String explanation, {
      InsightGroup group = InsightGroup.expenses,
      InsightKind kind = InsightKind.fact,
      int priority = 0,
      Map<String, int> amounts = const {},
      Iterable<InsightEvidence> evidence = const [],
    }) => result.add(
      Insight(
        rule: rule,
        entity: entity,
        period: f.period,
        title: title,
        explanation: explanation,
        group: group,
        kind: kind,
        priority: priority,
        amounts: amounts,
        evidence: evidence,
      ),
    );
    List<InsightEvidence> refs(Iterable<LedgerEntry> entries) =>
        entries.map((e) => InsightEvidence(EvidenceKind.entry, e.id)).toList();
    final periodText = '${calendarDate(f.start)} — ${calendarDate(f.end)}';
    if (f.future) {
      add(
        'M1',
        'future',
        'Этот период ещё не наступил',
        'Выберите текущий или завершённый месяц.',
        group: InsightGroup.quality,
        kind: InsightKind.insufficient,
      );
      return _visible(result, policy, f.today);
    }
    if (f.entries.isNotEmpty) {
      add(
        'A1',
        'flow',
        'Денежный поток',
        'По внесённым операциям: $periodText. Переводы и начальные остатки исключены; возвраты учтены в дату получения.',
        amounts: {
          'Доходы': f.income,
          'Расходы до возвратов': f.gross,
          'Возвраты': f.returned,
          'Чистые расходы': f.netExpense,
          'Разница': difference(f.income, f.netExpense),
        },
        evidence: refs(f.entries),
      );
      if (f.netExpense > f.income) {
        add(
          'A5',
          'deficit',
          'Расходы выше доходов',
          'По внесённым операциям за $periodText. Покупки могли оплачиваться накоплениями; это не оценка платёжеспособности.',
          priority: 40,
          amounts: {
            'Разница расходов и доходов': difference(f.netExpense, f.income),
          },
          evidence: refs(f.entries),
        );
      }
    }
    for (final a in snapshot.accounts) {
      if ((f.balances[a.id] ?? 0) < 0) {
        add(
          'A3',
          a.id,
          'Отрицательный остаток: ${a.name}',
          'На ${calendarDate(f.end)}, с учётом начального остатка. Проверьте полноту записей; отрицательный остаток сам по себе не означает долг.',
          priority: 70,
          amounts: {'Остаток': f.balances[a.id]!},
          evidence: [
            InsightEvidence(EvidenceKind.account, a.id),
            ...refs(f.accountEntries[a.id] ?? []),
          ],
        );
      }
    }
    final categoryEntries = <String, List<LedgerEntry>>{};
    for (final e in f.entries.where(
      (e) => e.kind == EntryKind.expense || e.kind == EntryKind.refund,
    )) {
      categoryEntries
          .putIfAbsent(f.canonicalCategory(e.category), () => [])
          .add(e);
    }
    final ranked = f.categories.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) {
        final d = b.value.compareTo(a.value);
        return d != 0 ? d : a.key.compareTo(b.key);
      });
    for (final c in ranked.take(3)) {
      add(
        'C1',
        c.key,
        'Крупная категория: ${c.key}',
        'Чистые расходы за $periodText. Названия сгруппированы без учёта регистра и лишних пробелов.',
        amounts: {'Расходы после возвратов': c.value},
        evidence: refs(categoryEntries[c.key]!),
      );
      add(
        'J1',
        c.key,
        'Сценарий: сократить «${c.key}» на ${policy.scenarioPercent}%',
        'Если уменьшить такую же сумму чистых расходов за аналогичный период. Это арифметический сценарий, а не уже полученная экономия.',
        group: InsightGroup.scenarios,
        kind: InsightKind.scenario,
        amounts: {
          'База сценария': c.value,
          'Возможное сокращение': percentMinor(c.value, policy.scenarioPercent),
        },
        evidence: refs(categoryEntries[c.key]!),
      );
    }
    final largest = f.entries.where((e) => e.kind == EntryKind.expense).toList()
      ..sort((a, b) {
        final d = b.amountMinor.compareTo(a.amountMinor);
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    for (final e in largest.take(3)) {
      add(
        'C2',
        e.id,
        'Крупный расход: ${e.category}',
        'Дата ${calendarDate(e.date)}. Показана исходная сумма списания до возвратов; размер покупки не означает её ненужность.',
        amounts: {'Списание': e.amountMinor},
        evidence: refs([e]),
      );
    }
    final canCompare =
        f.covered(policy, f.comparableEnd) &&
        f.covered(policy, f.comparisonEnd);
    final currentComparable = snapshot.entries
        .where((e) => AnalysisFacts.within(e.date, f.start, f.comparableEnd))
        .toList();
    final previous = snapshot.entries
        .where(
          (e) =>
              AnalysisFacts.within(e.date, f.comparisonStart, f.comparisonEnd),
        )
        .toList();
    if (!canCompare) {
      add(
        'M1',
        'coverage',
        'Сравнения пока ограничены',
        'Для сравнения подтвердите полноту учёта за ${calendarDate(f.start)} — ${calendarDate(f.comparableEnd)} и ${calendarDate(f.comparisonStart)} — ${calendarDate(f.comparisonEnd)} в настройках анализа. Пустые дни не доказывают отсутствие расходов.',
        group: InsightGroup.quality,
        kind: InsightKind.insufficient,
      );
    } else {
      void compare(
        String rule,
        String entity,
        String title,
        int current,
        int before,
        Iterable<LedgerEntry> evidence,
      ) {
        final delta = difference(current, before);
        final magnitude = BigInt.from(delta).abs();
        if (magnitude <
            BigInt.from(
              policy.minimumFor(rule, rule == 'B2' ? entity : null),
            )) {
          return;
        }
        if (before > 0 &&
            current >= 0 &&
            magnitude * BigInt.from(100) <
                BigInt.from(before) * BigInt.from(policy.changePercent)) {
          return;
        }
        final suffix = before <= 0 || current < 0
            ? 'Процент не рассчитывается при нулевой или отрицательной базе.'
            : 'Изменение ${(magnitude * BigInt.from(100) ~/ BigInt.from(before)).toString()}% (${delta > 0 ? 'рост' : 'снижение'}).';
        add(
          rule,
          entity,
          title,
          '${calendarDate(f.start)} — ${calendarDate(f.comparableEnd)} против ${calendarDate(f.comparisonStart)} — ${calendarDate(f.comparisonEnd)}. $suffix',
          priority: 20,
          amounts: {
            'Текущий период': current,
            'Предыдущий период': before,
            'Изменение': delta,
          },
          evidence: refs(evidence),
        );
      }

      int net(List<LedgerEntry> entries) => difference(
        AnalysisFacts.total(entries, EntryKind.expense),
        AnalysisFacts.total(entries, EntryKind.refund),
      );
      compare(
        'B1',
        'expenses',
        'Изменились общие расходы',
        net(currentComparable),
        net(previous),
        [...currentComparable, ...previous].where(
          (e) => e.kind == EntryKind.expense || e.kind == EntryKind.refund,
        ),
      );
      compare(
        'E1',
        'income',
        'Изменились доходы',
        AnalysisFacts.total(currentComparable, EntryKind.income),
        AnalysisFacts.total(previous, EntryKind.income),
        [
          ...currentComparable,
          ...previous,
        ].where((e) => e.kind == EntryKind.income),
      );
      final c = f.categoryTotals(currentComparable),
          p = f.categoryTotals(previous);
      final comparableCategories = <String, List<LedgerEntry>>{};
      for (final e in [...currentComparable, ...previous]) {
        if (e.kind == EntryKind.expense || e.kind == EntryKind.refund) {
          comparableCategories
              .putIfAbsent(f.canonicalCategory(e.category), () => [])
              .add(e);
        }
      }
      final keys = {...c.keys, ...p.keys}.toList()..sort();
      for (final key in keys) {
        compare(
          'B2',
          key,
          'Изменились расходы: $key',
          c[key] ?? 0,
          p[key] ?? 0,
          comparableCategories[key] ?? [],
        );
      }
    }
    for (final b in snapshot.budgets.where(
      (b) => b.month == monthKey(f.start) && f.unambiguousBudget(b),
    )) {
      final spent = f.categories[f.canonicalCategory(b.category)] ?? 0;
      final evidence = [
        InsightEvidence(EvidenceKind.budget, b.id),
        ...refs(categoryEntries[f.canonicalCategory(b.category)] ?? []),
      ];
      if (spent > b.limitMinor) {
        add(
          'D2',
          b.id,
          'Лимит превышен: ${b.category}',
          'За $periodText. Возвраты учтены в дату получения.',
          priority: 60,
          amounts: {
            'Лимит': b.limitMinor,
            'Чистые расходы': spent,
            'Превышение': difference(spent, b.limitMinor),
          },
          evidence: evidence,
        );
      } else if (BigInt.from(spent) * BigInt.from(100) >=
          BigInt.from(b.limitMinor) * BigInt.from(policy.nearLimitPercent)) {
        add(
          'D1',
          b.id,
          'Близко к лимиту: ${b.category}',
          'Использовано не менее ${policy.nearLimitPercent}% лимита. Это точный итог внесённых операций.',
          priority: 30,
          amounts: {'Лимит': b.limitMinor, 'Чистые расходы': spent},
          evidence: evidence,
        );
      }
      if (f.current) {
        final remaining = difference(
          b.limitMinor,
          spent,
        ).clamp(0, 9223372036854775807);
        final days =
            DateTime(f.today.year, f.today.month + 1, 0).day - f.today.day + 1;
        add(
          'D3',
          b.id,
          'Остаток на день: ${b.category}',
          'Остаток лимита распределён на $days дн., включая сегодня. Дневная сумма округлена вниз; это не прогноз.',
          amounts: {
            'Осталось в лимите': remaining,
            'В среднем на день': remaining ~/ days,
          },
          evidence: evidence,
        );
      }
    }
    if (f.current) {
      final horizon = DateTime(f.today.year, f.today.month, f.today.day + 29);
      final yearEnd = DateTime(
        f.today.year + 1,
        f.today.month,
        f.today.day - 1,
      );
      final expenses = snapshot.obligations.where(
        (o) => o.active && o.kind == EntryKind.expense,
      );
      final future = <PlannedOccurrence>[];
      for (final o in snapshot.obligations.where((o) => o.active)) {
        final next = periodDate(o, o.nextIndex);
        final evidence = [InsightEvidence(EvidenceKind.obligation, o.id)];
        if (next.isBefore(f.today)) {
          add(
            o.kind == EntryKind.income ? 'E2' : 'F2',
            '${o.id}:${calendarDate(next)}',
            'Срок прошёл: ${o.name}',
            'Первый неподтверждённый срок ${calendarDate(next)}. Запись плана не доказывает фактическую оплату или поступление.',
            group: InsightGroup.payments,
            priority: 80,
            amounts: {'Ожидаемая сумма': o.amountMinor},
            evidence: evidence,
          );
        }
        if (o.kind == EntryKind.expense) {
          future.addAll(occurrences(o, f.today, horizon));
        }
        if (o.trialEnd != null &&
            !o.trialEnd!.isBefore(f.today) &&
            !o.trialEnd!.isAfter(
              DateTime(f.today.year, f.today.month, f.today.day + 7),
            )) {
          add(
            'F3',
            '${o.id}:${calendarDate(o.trialEnd!)}',
            'Проверьте пробный период: ${o.name}',
            'Указанная дата окончания ${calendarDate(o.trialEnd!)}. Отмена выполняется у поставщика услуги.',
            group: InsightGroup.payments,
            priority: 75,
            evidence: evidence,
          );
        }
      }
      if (future.isNotEmpty) {
        add(
          'F1',
          'upcoming',
          'Ближайшие платежи',
          'С ${calendarDate(f.today)} по ${calendarDate(horizon)}: ${future.length} неподтверждённых периодов. Планы не меняют фактический баланс.',
          group: InsightGroup.payments,
          priority: 50,
          amounts: {
            'За 30 дней': sumMinor(future.map((e) => e.obligation.amountMinor)),
            'Из них за 7 дней': sumMinor(
              future
                  .where(
                    (e) => !e.date.isAfter(
                      DateTime(f.today.year, f.today.month, f.today.day + 6),
                    ),
                  )
                  .map((e) => e.obligation.amountMinor),
            ),
          },
          evidence: future
              .map(
                (e) =>
                    InsightEvidence(EvidenceKind.obligation, e.obligation.id),
              )
              .toSet(),
        );
      }
      final regular = expenses
          .where((o) => o.repeat != RepeatRule.once)
          .toList();
      final annual = regular
          .expand((o) => occurrences(o, f.today, yearEnd))
          .toList();
      if (annual.isNotEmpty) {
        add(
          'F4',
          'annual',
          'Регулярные платежи за следующие 12 месяцев',
          'По текущим планам: ${calendarDate(f.today)} — ${calendarDate(yearEnd)}, ${annual.length} периодов. Просроченные и разовые платежи не включены.',
          group: InsightGroup.payments,
          amounts: {
            'Запланировано': sumMinor(
              annual.map((e) => e.obligation.amountMinor),
            ),
          },
          evidence: regular.map(
            (o) => InsightEvidence(EvidenceKind.obligation, o.id),
          ),
        );
      }
      for (final o in regular) {
        final planned = occurrences(o, f.today, yearEnd);
        if (planned.isEmpty) continue;
        add(
          'J2',
          o.id,
          'Сценарий паузы: ${o.name}',
          'Если не выполнять ${planned.length} будущих списаний с ${calendarDate(f.today)} по ${calendarDate(yearEnd)}. Условия договора не проверены; приложение не отменяет подписку.',
          group: InsightGroup.scenarios,
          kind: InsightKind.scenario,
          amounts: {
            'Сумма этих списаний': sumMinor(
              planned.map((e) => e.obligation.amountMinor),
            ),
          },
          evidence: [InsightEvidence(EvidenceKind.obligation, o.id)],
        );
      }
      final byDay = <String, List<PlannedOccurrence>>{};
      for (final due in future) {
        byDay.putIfAbsent(calendarDate(due.date), () => []).add(due);
      }
      for (final day in byDay.entries.where((e) => e.value.length >= 2)) {
        add(
          'F5',
          day.key,
          'Несколько списаний ${day.key}',
          '${day.value.length} плановых платежей в один день. Проверьте остатки нужных счетов.',
          group: InsightGroup.payments,
          priority: 55,
          amounts: {
            'Всего запланировано': sumMinor(
              day.value.map((e) => e.obligation.amountMinor),
            ),
          },
          evidence: day.value.map(
            (e) => InsightEvidence(EvidenceKind.obligation, e.obligation.id),
          ),
        );
      }
      for (final p in snapshot.purchases.where(
        (p) => !p.archived && !p.date.isAfter(f.today),
      )) {
        for (final (rule, date, label) in [
          ('L1', p.returnBy, 'Возврат'),
          ('L2', p.warrantyUntil, 'Гарантия'),
        ]) {
          if (date != null &&
              !date.isBefore(f.today) &&
              calendarDaysBetween(f.today, date) <= 7) {
            add(
              rule,
              '${p.id}:${calendarDate(date)}',
              '$label: ${p.name}',
              'Указанный вами срок ${calendarDate(date)}. Это напоминание о дате, а не правовая оценка условий продавца.',
              group: InsightGroup.payments,
              priority: 65,
              evidence: [InsightEvidence(EvidenceKind.purchase, p.id)],
            );
          }
        }
      }
      final futureEntries = snapshot.entries
          .where((e) => e.date.isAfter(f.today))
          .toList();
      if (futureEntries.isNotEmpty) {
        add(
          'M3',
          'future_entries',
          'Есть операции с будущей датой',
          '${futureEntries.length} записей. Они исключены из сегодняшнего среза анализа. Проверьте, не должен ли это быть плановый платёж.',
          group: InsightGroup.quality,
          kind: InsightKind.check,
          priority: 25,
          evidence: refs(futureEntries),
        );
      }
    }
    final obligations = {for (final o in snapshot.obligations) o.id: o};
    for (final s in snapshot.settlements.where(
      (s) => !s.skipped && AnalysisFacts.within(s.dueDate, f.start, f.end),
    )) {
      final entry = f.entryById[s.entryId], plan = obligations[s.obligationId];
      if (entry == null ||
          plan == null ||
          entry.date.isAfter(f.end) ||
          entry.amountMinor == plan.amountMinor) {
        continue;
      }
      add(
        'F6',
        s.id,
        'Оплата отличается от текущего плана: ${plan.name}',
        'Срок периода ${calendarDate(s.dueDate)}. Сравнение с текущей суммой плана; прежняя цена плана не хранится.',
        group: InsightGroup.payments,
        amounts: {
          'Фактическая сумма': entry.amountMinor,
          'Текущий план': plan.amountMinor,
          'Разница': difference(entry.amountMinor, plan.amountMinor),
        },
        evidence: [
          InsightEvidence(EvidenceKind.entry, entry.id),
          InsightEvidence(EvidenceKind.obligation, plan.id),
        ],
      );
    }
    for (final p in snapshot.purchases.where(
      (p) => !p.date.isAfter(f.end) && p.entryId != null,
    )) {
      final entry = f.entryById[p.entryId];
      if (entry == null || entry.date.isAfter(f.end)) continue;
      final refunds = (f.refunds[entry.id] ?? [])
          .where((e) => !e.date.isAfter(f.end))
          .toList();
      if (refunds.isEmpty ||
          ![
            entry,
            ...refunds,
          ].any((e) => AnalysisFacts.within(e.date, f.start, f.end))) {
        continue;
      }
      final total = sumMinor(refunds.map((e) => e.amountMinor));
      add(
        'L4',
        p.id,
        'После возвратов: ${p.name}',
        'Стоимость связанного расхода после возвратов до ${calendarDate(f.end)}. Это показатель покупки за всё время, отдельно от денежного потока месяца.',
        amounts: {
          'Исходный расход': entry.amountMinor,
          'Возвращено': total,
          'Стоимость после возвратов': difference(entry.amountMinor, total),
        },
        evidence: [
          InsightEvidence(EvidenceKind.purchase, p.id),
          ...refs([entry, ...refunds]),
        ],
      );
    }
    final variants = <String, Set<String>>{};
    final variantEntries = <String, List<LedgerEntry>>{};
    for (final e in snapshot.entries.where(
      (e) =>
          !e.date.isAfter(f.end) &&
          e.category.trim().isNotEmpty &&
          e.kind != EntryKind.transfer,
    )) {
      variants.putIfAbsent(categoryKey(e.category), () => {}).add(e.category);
      variantEntries.putIfAbsent(categoryKey(e.category), () => []).add(e);
    }
    for (final v in variants.entries.where((e) => e.value.length > 1)) {
      final names = v.value.toList()..sort();
      add(
        'M2',
        v.key,
        'Разные написания категории',
        'В анализе объединены: ${names.join(' / ')}. Исходные записи не изменены.',
        group: InsightGroup.quality,
        kind: InsightKind.check,
        evidence: refs(variantEntries[v.key]!),
      );
    }
    result.addAll(
      descriptiveInsights(f, policy, comparisonsAllowed: canCompare),
    );
    result.addAll(patternInsights(f, policy));
    result.addAll(confirmedSeriesInsights(f, policy));
    result.addAll(calendarInsights(f, policy));
    result.addAll(personalInsights(f, policy));
    result.addAll(historyInsights(f, policy));
    result.addAll(forecastInsights(f, policy));
    return _visible(result, policy, f.today);
  }

  List<Insight> _visible(
    List<Insight> all,
    AnalysisPolicy policy,
    DateTime today,
  ) {
    final byKey = <String, Insight>{};
    for (final insight in all.where((i) => policy.shows(i, today))) {
      final custom = policy.profile.priorities[insight.rule];
      byKey[insight.key] = custom == null
          ? insight
          : Insight(
              rule: insight.rule,
              entity: insight.entity,
              period: insight.period,
              title: insight.title,
              explanation: insight.explanation,
              group: insight.group,
              kind: insight.kind,
              priority: custom,
              amounts: insight.amounts,
              evidence: insight.evidence,
              seriesProposal: insight.seriesProposal,
              timelineTitle: insight.timelineTitle,
              timeline: insight.timeline,
            );
    }
    final sorted = byKey.values.toList()
      ..sort((a, b) {
        final d = b.priority.compareTo(a.priority);
        return d != 0 ? d : a.key.compareTo(b.key);
      });
    return List.unmodifiable(sorted);
  }
}
