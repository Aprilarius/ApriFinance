import '../../models.dart';
import '../analysis_facts.dart';
import '../analysis_profile.dart';
import '../debt_math.dart';
import '../insight.dart';
import '../profile_math.dart';
import '../series_review.dart';

List<Insight> personalInsights(AnalysisFacts f, AnalysisPolicy policy) {
  final s = f.snapshot, p = f.profile, result = <Insight>[];
  List<InsightEvidence> refs(Iterable<LedgerEntry> rows) =>
      rows.map((e) => InsightEvidence(EvidenceKind.entry, e.id)).toList();
  void emit(
    String rule,
    String entity,
    String title,
    String explanation, {
    Map<String, int> amounts = const {},
    Iterable<InsightEvidence> evidence = const [],
    InsightGroup group = InsightGroup.planning,
    InsightKind kind = InsightKind.fact,
    int priority = 0,
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
  final outflows = f.entries
      .where((e) => e.kind == EntryKind.expense || e.kind == EntryKind.refund)
      .toList();
  if (outflows.isNotEmpty && p.annotations.isNotEmpty) {
    final roles = {for (final role in ExpenseRole.values) role: <int>[]},
        sellers = <String, List<LedgerEntry>>{};
    for (final e in outflows) {
      final source = e.kind == EntryKind.refund ? f.entryById[e.refundOf] : e;
      final tag = source == null ? null : p.annotation(source);
      roles[tag?.role ?? ExpenseRole.unspecified]!.add(
        e.kind == EntryKind.refund ? -e.amountMinor : e.amountMinor,
      );
      if (e.kind == EntryKind.expense) {
        sellers
            .putIfAbsent(
              tag == null || tag.counterparty.isEmpty
                  ? 'Не указано'
                  : p.counterparty(tag.counterparty),
              () => [],
            )
            .add(e);
      }
    }
    emit(
      'C4',
      'roles',
      'Обязательные и гибкие расходы',
      'Только явные метки владельца. Возврат относится к роли исходного расхода; непомеченные суммы показаны отдельно. Роль не означает, что расход можно безопасно отменить.',
      amounts: {
        'Обязательные': sumMinor(roles[ExpenseRole.mandatory]!),
        'Гибкие': sumMinor(roles[ExpenseRole.flexible]!),
        'Не помечены': sumMinor(roles[ExpenseRole.unspecified]!),
      },
      evidence: refs(outflows),
      group: InsightGroup.expenses,
    );
    if (sellers.keys.any((key) => key != 'Не указано')) {
      emit(
        'C6',
        'sellers',
        'Расходы по подтверждённым продавцам',
        'Продавцы внесены владельцем и объединены только подтверждёнными алиасами. Исходные списания до возвратов; комментарий сам по себе продавцом не считается.',
        amounts: {
          for (final e in sellers.entries)
            e.key: sumMinor(e.value.map((r) => r.amountMinor)),
        },
        evidence: refs(outflows),
        group: InsightGroup.expenses,
      );
    }
  }
  final missingCoverage =
      p.trackingStart == null ||
      p.trackingStart!.isAfter(f.start) ||
      !f.covered(policy, f.end);
  final staleTags = p.annotations.entries
      .where(
        (e) =>
            f.entryById[e.key] == null || !e.value.valid(f.entryById[e.key]!),
      )
      .length;
  final staleRefunds = p.refunds
      .where(
        (r) => !s.purchases.any(
          (purchase) =>
              purchase.id == r.purchaseId &&
              seriesDigest(purchase.toJson()) == r.purchaseHash &&
              purchase.entryId != null,
        ),
      )
      .length;
  final underfunded = underfundedAccounts(f);
  if ((s.accounts.isNotEmpty || p.touched) &&
      (missingCoverage ||
          staleTags > 0 ||
          staleRefunds > 0 ||
          underfunded.isNotEmpty ||
          f.budgetAmbiguities.isNotEmpty)) {
    emit(
      'M4',
      'quality',
      'Проверьте настройки полноты и метки',
      '${p.trackingStart == null ? 'Укажите дату начала учёта в данных анализа. ' : ''}${missingCoverage ? 'Полнота выбранного месяца не подтверждена целиком; отсутствие записей не означает нулевой расход. ' : ''}${staleTags > 0 ? 'Недействительных меток после изменения или удаления операций: $staleTags. ' : ''}${staleRefunds > 0 ? 'Перепроверьте ожидаемые возвраты после изменения покупок: $staleRefunds. ' : ''}${underfunded.isNotEmpty ? 'Суммы резервов и целей превышают остаток или относятся к недоступному счёту. Цели на таких счетах не считаются обеспеченными.' : ''}${f.budgetAmbiguities.isNotEmpty ? ' После алиасов несколько лимитов относятся к одной категории одного месяца. Уточните лимиты; неоднозначные бюджетные советы не рассчитываются.' : ''}',
      group: InsightGroup.quality,
      kind: InsightKind.check,
      evidence: [
        const InsightEvidence(EvidenceKind.profile, 'history'),
        if (staleRefunds > 0)
          const InsightEvidence(EvidenceKind.profile, 'refunds'),
        for (final b in s.budgets.where((b) => !f.unambiguousBudget(b)))
          InsightEvidence(EvidenceKind.budget, b.id),
      ],
    );
  }
  if (f.current) {
    if (p.reserves.isNotEmpty || p.goals.isNotEmpty) {
      final allocations = requestedAllocations(p);
      final protected = sumMinor(
        allocations.entries.map((e) {
          final balance = f.balances[e.key] ?? 0;
          return balance <= 0
              ? 0
              : e.value < balance
              ? e.value
              : balance;
        }),
      );
      emit(
        'A6',
        'available',
        'Деньги вне резервов и целей',
        'Защищённые суммы явно назначены владельцем. Для каждого счёта защита ограничена положительным сегодняшним остатком; отрицательные счета остаются в общем балансе. Это не банковский доступный лимит.',
        amounts: {
          'Баланс на сегодня': sumMinor(f.balances.values),
          'Защищено': protected,
          'Вне защиты': difference(sumMinor(f.balances.values), protected),
        },
        evidence: [
          for (final id in allocations.keys)
            InsightEvidence(EvidenceKind.account, id),
        ],
      );
    }
    for (final goal in p.goals) {
      final evidence = [
        InsightEvidence(EvidenceKind.profile, 'goals:${goal.id}'),
        InsightEvidence(EvidenceKind.account, goal.accountId),
      ];
      if (underfunded.contains(goal.accountId)) {
        emit(
          'K3',
          goal.id,
          'Проверьте обеспечение цели: ${goal.name}',
          'На счёте недостаточно денег для всех назначенных резервов и целей. Уточните распределение; заявленная сумма не считается подтверждённым прогрессом.',
          evidence: evidence,
          kind: InsightKind.insufficient,
        );
        continue;
      }
      final remaining = goal.targetMinor > goal.allocatedMinor
          ? difference(goal.targetMinor, goal.allocatedMinor)
          : 0;
      emit(
        'K3',
        goal.id,
        'Прогресс цели: ${goal.name}',
        'Явно назначенная сумма на сегодняшний день, не отдельный банковский счёт. Проверено отсутствие повторного распределения тех же средств между целями и резервами.',
        amounts: {
          'Назначено': goal.allocatedMinor,
          'Цель': goal.targetMinor,
          'Осталось': remaining,
        },
        evidence: evidence,
      );
      if (remaining > 0) {
        final months = goal.deadline.isBefore(f.today)
            ? 0
            : (goal.deadline.year - f.today.year) * 12 +
                  goal.deadline.month -
                  f.today.month +
                  1;
        final payment = months == 0
            ? remaining
            : checked(
                (BigInt.from(remaining) + BigInt.from(months - 1)) ~/
                    BigInt.from(months),
              );
        emit(
          'K4',
          goal.id,
          'Пополнение цели к сроку: ${goal.name}',
          months == 0
              ? 'Указанный срок уже прошёл; оставшаяся сумма нужна сейчас. Это арифметика цели, без обещания её достижимости.'
              : 'До ${calendarDate(goal.deadline)} осталось $months календарных месяцев, включая текущий. Равномерное пополнение округлено вверх до минимальной денежной единицы.',
          amounts: {'Осталось накопить': remaining, 'На месяц': payment},
          evidence: evidence,
          kind: InsightKind.scenario,
        );
      }
      if (goal.monthlyMinor > 0 && !goal.start.isAfter(f.today)) {
        final anchorDay = goal.start.day.clamp(
          1,
          DateTime(f.today.year, f.today.month + 1, 0).day,
        );
        final elapsed =
            ((f.today.year - goal.start.year) * 12 +
                    f.today.month -
                    goal.start.month -
                    (f.today.day < anchorDay ? 1 : 0))
                .clamp(0, 1200);
        final expected = checked(
          BigInt.from(goal.initialMinor) +
              BigInt.from(goal.monthlyMinor) * BigInt.from(elapsed),
        );
        final capped = expected < goal.targetMinor
            ? expected
            : goal.targetMinor;
        if (capped > goal.allocatedMinor &&
            capped - goal.allocatedMinor >= policy.minimumChangeMinor) {
          emit(
            'K5',
            goal.id,
            'Цель отстаёт от вашего плана: ${goal.name}',
            'Сравнение с начальной суммой и $elapsed завершёнными месячными интервалами по заданному взносу. Это ваш ориентир, а не оценка будущего дохода.',
            amounts: {
              'По вашему графику': capped,
              'Назначено сейчас': goal.allocatedMinor,
              'Разница': difference(capped, goal.allocatedMinor),
            },
            evidence: evidence,
            kind: InsightKind.check,
            priority: 25,
          );
        }
      }
    }
    for (final debt in p.debts) {
      if (debt.firstDue.isBefore(f.today)) {
        emit(
          'K6',
          debt.id,
          'Обновите параметры долга: ${debt.name}',
          'Дата следующего платежа уже прошла. Укажите текущую основную сумму и следующую дату; внесённые операции не списывают долг автоматически.',
          kind: InsightKind.insufficient,
          evidence: [InsightEvidence(EvidenceKind.profile, 'debts:${debt.id}')],
        );
        continue;
      }
      final schedule = debtSchedule(debt),
          evidence = [
            InsightEvidence(EvidenceKind.profile, 'debts:${debt.id}'),
          ];
      if (!schedule.amortizes) {
        emit(
          'K6',
          debt.id,
          'Платёж не уменьшает долг: ${debt.name}',
          'При заданной ставке и ежемесячной комиссии платёж не покрывает проценты и комиссию первого непогашаемого периода. Проверьте условия; расчёт не заменяет график кредитора.',
          amounts: {
            'Остаток долга': debt.principalMinor,
            'Платёж': debt.monthlyPaymentMinor,
          },
          evidence: evidence,
          kind: InsightKind.check,
          priority: 60,
        );
        continue;
      }
      final payments = sumMinor(schedule.months.map((m) => m.paymentMinor)),
          interest = sumMinor(schedule.months.map((m) => m.interestMinor)),
          fees = sumMinor(schedule.months.map((m) => m.feeMinor));
      result.add(
        Insight(
          rule: 'K6',
          entity: debt.id,
          period: f.period,
          title: 'Сценарий погашения: ${debt.name}',
          explanation:
              'Заданы текущая основная сумма, фиксированная годовая ставка и ежемесячная комиссия. Процент за месяц = ставка / 12 с округлением вверх; платёж в конце периода. ${schedule.capped ? 'Достигнут предел 600 месяцев: долг ещё не погашен.' : 'Погашение за ${schedule.months.length} месяцев до ${calendarDate(schedule.months.last.date)}.'} Фактические условия и округления кредитора могут отличаться. График не создаёт расходов и не добавляется к планам автоматически.',
          group: InsightGroup.planning,
          kind: InsightKind.scenario,
          amounts: {
            'Основная сумма': debt.principalMinor,
            'Платежи в рассчитанном интервале': payments,
            'Проценты': interest,
            'Комиссии': fees,
          },
          evidence: evidence,
          timelineTitle: 'График: остаток долга после платежа',
          timeline: [
            for (final m in schedule.months)
              InsightDay(m.date, m.remainingMinor),
          ],
        ),
      );
    }
    final last = p.lastBackupOn;
    if ((p.touched || s.entries.isNotEmpty) &&
        (last == null ||
            calendarDaysBetween(last, f.today) >= p.backupEveryDays)) {
      emit(
        'M6',
        'backup',
        'Пора сохранить внешнюю резервную копию',
        last == null
            ? 'Успешный экспорт .mfin пока не подтверждён приложением. Внутренняя защитная копия не заменяет внешний файл.'
            : 'Последний подтверждённый экспорт ${calendarDate(last)}; выбран интервал ${p.backupEveryDays} дней. Он не гарантирует, что внешняя копия доступна и содержит последние изменения.',
        group: InsightGroup.quality,
        kind: InsightKind.check,
        priority: 30,
        evidence: [const InsightEvidence(EvidenceKind.profile, 'backup')],
      );
    }
    for (final expected in p.refunds) {
      final purchase = s.purchases
          .where((r) => r.id == expected.purchaseId)
          .firstOrNull;
      if (purchase == null ||
          seriesDigest(purchase.toJson()) != expected.purchaseHash ||
          purchase.entryId == null ||
          !expected.due.isBefore(f.today)) {
        continue;
      }
      final returned = sumMinor(
        (f.refunds[purchase.entryId] ?? [])
            .where((r) => !r.date.isAfter(f.today))
            .map((r) => r.amountMinor),
      );
      final received = (returned - expected.baselineRefundMinor).clamp(
            0,
            expected.expectedMinor,
          ),
          remaining = expected.expectedMinor - received;
      if (remaining > 0) {
        emit(
          'L6',
          expected.id,
          'Ожидаемый возврат ещё не поступил: ${purchase.name}',
          'Владелец указал сумму и ожидаемую дату ${calendarDate(expected.due)}. Учитываются только связанные возвраты исходного расхода сверх суммы на момент регистрации ожидания. Это не юридический срок.',
          amounts: {
            'Ожидалось дополнительно': expected.expectedMinor,
            'Получено после регистрации': received,
            'Ещё ожидается': remaining,
          },
          evidence: [
            InsightEvidence(EvidenceKind.purchase, purchase.id),
            InsightEvidence(EvidenceKind.profile, 'refunds:${expected.id}'),
          ],
          group: InsightGroup.payments,
          kind: InsightKind.check,
          priority: 50,
        );
      }
    }
  }
  final closed = f.current
      ? DateTime(f.start.year, f.start.month - 1)
      : f.start;
  final incomeMonths = [
    for (var n = 2; n >= 0; n--) DateTime(closed.year, closed.month - n),
  ];
  if (p.annotations.isNotEmpty &&
      incomeMonths.every(
        (m) => f.covered(policy, DateTime(m.year, m.month + 1, 0)),
      )) {
    final income = s.entries
        .where(
          (e) =>
              e.kind == EntryKind.income &&
              AnalysisFacts.within(
                e.date,
                incomeMonths.first,
                DateTime(closed.year, closed.month + 1, 0),
              ),
        )
        .toList();
    final bySource = <String, List<int>>{};
    var missing = false;
    for (final e in income) {
      final tag = p.annotation(e);
      if (tag == null || tag.counterparty.isEmpty) {
        missing = true;
      } else {
        bySource
            .putIfAbsent(p.counterparty(tag.counterparty), () => [])
            .add(e.amountMinor);
      }
    }
    final total = sumMinor(income.map((e) => e.amountMinor));
    if (missing && total > 0) {
      emit(
        'E4',
        'income-sources',
        'Уточните источники поступлений',
        'Для концентрации дохода за три завершённых месяца нужны подтверждённые источники всех поступлений. Комментарии не заменяют метки.',
        group: InsightGroup.quality,
        kind: InsightKind.insufficient,
        evidence: refs(income),
      );
    } else if (total > 0 && bySource.isNotEmpty) {
      final sources = bySource.entries.toList()
        ..sort((a, b) {
          final c = sumMinor(b.value).compareTo(sumMinor(a.value));
          return c != 0 ? c : a.key.compareTo(b.key);
        });
      final main = sumMinor(sources.first.value);
      if (BigInt.from(main) * BigInt.from(100) >=
          BigInt.from(total) * BigInt.from(70)) {
        emit(
          'E4',
          'income-sources',
          'Большая доля дохода из одного источника',
          'За три полных месяца ${sources.first.key} обеспечивает не менее 70% внесённого дохода. Это описание концентрации, без прогноза потери дохода.',
          amounts: {'Этот источник': main, 'Весь доход': total},
          evidence: refs(income),
          group: InsightGroup.expenses,
        );
      }
    }
  }
  if (f.current && p.reserves.isNotEmpty) {
    final months = [
      for (var n = 3; n >= 1; n--) DateTime(f.start.year, f.start.month - n),
    ];
    final rows = s.entries
        .where(
          (e) =>
              e.kind == EntryKind.expense &&
              AnalysisFacts.within(
                e.date,
                months.first,
                DateTime(f.start.year, f.start.month, 0),
              ),
        )
        .toList();
    final complete = months.every(
      (m) => f.covered(policy, DateTime(m.year, m.month + 1, 0)),
    );
    if (complete &&
        rows.every(
          (e) =>
              p.annotation(e)?.role != null &&
              p.annotation(e)!.role != ExpenseRole.unspecified,
        )) {
      final mandatory =
          sumMinor(
            rows
                .where((e) => p.annotation(e)?.role == ExpenseRole.mandatory)
                .map((e) => e.amountMinor),
          ) ~/
          3;
      final reserve = sumMinor(
        p.reserves.entries.map(
          (e) => e.value.clamp(
            0,
            (f.balances[e.key] ?? 0).clamp(0, 9223372036854775807),
          ),
        ),
      );
      if (mandatory > 0) {
        final hundredths = checked(
          BigInt.from(reserve) * BigInt.from(100) ~/ BigInt.from(mandatory),
        );
        emit(
          'K2',
          'runway',
          'Резерв относительно обязательных расходов',
          'Три подтверждённых месяца; все расходы размечены. Отношение резерва к средним обязательным списаниям: ${hundredths ~/ 100},${(hundredths % 100).toString().padLeft(2, '0')} мес. Возвраты не уменьшают этот консервативный ориентир, будущие цены неизвестны.',
          amounts: {
            'Явно назначенный резерв': reserve,
            'Обязательные списания в среднем за месяц': mandatory,
          },
          evidence: [
            ...refs(rows),
            for (final id in p.reserves.keys)
              InsightEvidence(EvidenceKind.account, id),
          ],
        );
      }
    } else {
      emit(
        'K2',
        'runway',
        'Для оценки резерва не хватает разметки',
        'Нужны три подтверждённых полных месяца и явная роль всех расходов. Непомеченные покупки не считаются гибкими автоматически.',
        kind: InsightKind.insufficient,
        evidence: [const InsightEvidence(EvidenceKind.profile, 'reserves')],
      );
    }
  }
  if (p.touched || policy.disabled.isNotEmpty) {
    emit(
      'O5',
      'thresholds',
      'Персональные параметры анализа',
      'Общий процент изменения ${policy.changePercent}%; индивидуальных порогов правил ${p.ruleMinimums.length}, категорий ${p.categoryMinimums.length}. Порог C5 — максимальная сумма мелкой покупки; B1/B2/H1 — минимальное значимое изменение. Отключено правил: ${policy.disabled.length}.',
      amounts: {'Общий денежный порог': policy.minimumChangeMinor},
      group: InsightGroup.quality,
      evidence: [const InsightEvidence(EvidenceKind.profile, 'thresholds')],
    );
  }
  if (p.touched || policy.hidden.isNotEmpty || policy.snoozed.isNotEmpty) {
    emit(
      'O6',
      'delivery',
      'Настройки выдачи рекомендаций',
      'Индивидуальных приоритетов: ${p.priorities.length}. Скрыто карточек: ${policy.hidden.length}, записей паузы: ${policy.snoozed.length}. Обзор показывает до трёх разных причин; полный список доступен в анализе. Настройки не являются оценкой финансового здоровья.',
      group: InsightGroup.quality,
      evidence: [const InsightEvidence(EvidenceKind.profile, 'priorities')],
    );
  }
  return result;
}
