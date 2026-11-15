import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/schedule_math.dart';
import '../domain/purchases.dart';
import '../domain/purchase_deadlines.dart';
import 'finance_view_model.dart';
import 'theme.dart';

Widget paymentSurface(Widget child) => Material(
  color: Colors.white,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
    side: const BorderSide(color: LedgerColors.line),
  ),
  child: Padding(padding: const EdgeInsets.all(20), child: child),
);

List<Widget> paymentsContent(
  BuildContext context,
  FinanceViewModel vm, {
  required void Function(Obligation) edit,
  required void Function(Obligation) pay,
  required void Function(Obligation, String) action,
  required void Function(Settlement) undo,
  void Function(Purchase)? editPurchase,
}) {
  final obligations = vm.snapshot!.obligations.toList()
    ..sort(
      (a, b) =>
          periodDate(a, a.nextIndex).compareTo(periodDate(b, b.nextIndex)),
    );
  final byId = {for (final o in obligations) o.id: o};
  final entries = {for (final e in vm.snapshot!.entries) e.id: e};
  final trials =
      obligations
          .where(
            (o) =>
                o.active &&
                o.trialEnd?.year == vm.month.year &&
                o.trialEnd?.month == vm.month.month,
          )
          .toList()
        ..sort((a, b) => a.trialEnd!.compareTo(b.trialEnd!));
  final history = vm.snapshot!.settlements.where(
    (s) => s.dueDate.year == vm.month.year && s.dueDate.month == vm.month.month,
  );
  return [
    Text('Подписки и счета', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 12),
    if (obligations.isEmpty)
      paymentSurface(
        const Text(
          'Добавьте подписку, разовый счёт или ожидаемый доход. План сам по себе не меняет остаток денег.',
        ),
      ),
    ...obligations.map((o) {
      final due = periodDate(o, o.nextIndex);
      final late = o.active && due.isBefore(vm.today);
      final label = o.complete
          ? 'Завершён'
          : o.paused
          ? 'Приостановлен'
          : late
          ? 'Просрочен'
          : calendarDate(due) == calendarDate(vm.today)
          ? 'Сегодня'
          : 'Следующий срок';
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: paymentSurface(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      o.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Действия с платежом',
                    onSelected: (v) => v == 'edit' ? edit(o) : action(o, v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Изменить'),
                      ),
                      if (!o.complete)
                        PopupMenuItem(
                          value: 'pause',
                          child: Text(
                            o.paused
                                ? 'Возобновить'
                                : 'Приостановить / завершить',
                          ),
                        ),
                      if (o.active)
                        const PopupMenuItem(
                          value: 'skip',
                          child: Text('Пропустить период без операции'),
                        ),
                    ],
                  ),
                ],
              ),
              Text(
                '${o.kind.label} · ${formatMoney(o.amountMinor, vm.currency)} · ${o.repeat.label}',
              ),
              const SizedBox(height: 8),
              Text(
                '$label${o.complete ? '' : ' · ${DateFormat('dd.MM.yyyy').format(due)}'}',
                style: TextStyle(
                  color: late ? LedgerColors.expense : LedgerColors.muted,
                  fontWeight: late ? FontWeight.w600 : null,
                ),
              ),
              if (o.trialEnd != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Пробный период до ${DateFormat('dd.MM.yyyy').format(o.trialEnd!)}',
                  ),
                ),
              if (o.manageUrl.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Скопировать ссылку на управление'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: o.manageUrl));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Ссылка скопирована')),
                        );
                      }
                    },
                  ),
                ),
              if (o.active)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      key: ValueKey('pay-${o.id}'),
                      onPressed: () => pay(o),
                      child: Text(
                        o.kind == EntryKind.income
                            ? 'Доход получен'
                            : 'Оплачено',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }),
    const SizedBox(height: 20),
    Text(
      'Календарь выбранного месяца',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    const SizedBox(height: 8),
    const Text(
      'Предстоящие периоды. Оплата подтверждается последовательно, начиная с первого необработанного срока.',
    ),
    const SizedBox(height: 12),
    ...trials.map(
      (o) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: paymentSurface(
          Text(
            '${DateFormat('dd.MM.yyyy').format(o.trialEnd!)} · ${o.name}\nОкончание пробного периода',
            style: const TextStyle(height: 1.6),
          ),
        ),
      ),
    ),
    if (vm.calendar.isEmpty && trials.isEmpty && vm.purchaseDeadlines.isEmpty)
      paymentSurface(
        const Text('В этом месяце нет платежей и сроков покупок.'),
      ),
    ...vm.calendar.map(
      (p) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: paymentSurface(
          Text(
            '${DateFormat('dd.MM.yyyy').format(p.date)} · ${p.obligation.name}\n${p.obligation.kind.label}: ${formatMoney(p.obligation.amountMinor, vm.currency)}',
            style: const TextStyle(height: 1.6),
          ),
        ),
      ),
    ),
    const SizedBox(height: 20),
    if (vm.purchaseDeadlines.isNotEmpty) ...[
      Text('Возврат и гарантия', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      ...vm.purchaseDeadlines.map(
        (deadline) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: paymentSurface(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${DateFormat('dd.MM.yyyy').format(deadline.date)} · ${deadline.purchase.name}\n${deadline.kind.label}',
                  style: const TextStyle(height: 1.6),
                ),
                if (editPurchase != null)
                  TextButton(
                    onPressed: () => editPurchase(deadline.purchase),
                    child: const Text('Открыть карточку'),
                  ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
    ],
    Text('Обработанные периоды', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 12),
    if (history.isEmpty)
      paymentSurface(
        const Text('Подтверждённых и пропущенных периодов в этом месяце нет.'),
      ),
    ...history.map((s) {
      final o = byId[s.obligationId];
      final e = entries[s.entryId];
      final last = o != null && o.nextIndex - 1 == s.periodIndex;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: paymentSurface(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                o?.name ?? 'Платёж',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Срок ${DateFormat('dd.MM.yyyy').format(s.dueDate)} · ${s.skipped ? 'Пропущен без операции' : 'Подтверждён'}',
              ),
              if (e != null)
                Text(
                  '${DateFormat('dd.MM.yyyy').format(e.date)} · ${formatMoney(e.amountMinor, vm.currency)}',
                ),
              if (last)
                TextButton(
                  onPressed: () => undo(s),
                  child: const Text('Отменить подтверждение / пропуск'),
                ),
            ],
          ),
        ),
      );
    }),
  ];
}
