import 'package:material_ui/material_ui.dart';

import '../../domain/insights/series_review.dart';
import '../../domain/insights/series_plan_link.dart';
import '../../domain/models.dart';
import '../../domain/money.dart';
import '../finance_view_model.dart';
import '../theme.dart';
import 'series_plan_picker.dart';

class SeriesReviewsScreen extends StatelessWidget {
  const SeriesReviewsScreen({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm,
    builder: (context, _) => ListenableBuilder(
      listenable: vm.insights,
      builder: (context, _) {
        final state = vm.insights, snapshot = vm.snapshot!;
        final reviews = state.policy.seriesReviews.values.toList()
          ..sort((a, b) {
            final date = b.reviewedOn.compareTo(a.reviewedOn);
            return date != 0 ? date : a.proposal.key.compareTo(b.proposal.key);
          });
        return Scaffold(
          appBar: AppBar(title: const Text('Серии')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Ваши решения о повторениях',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Подтверждение связывает внесённые операции для анализа. Оно не создаёт план платежей и не добавляет будущие списания. Решения сохраняются в базе и включаются в зашифрованную копию .mfin. При подключённой синхронизации решения переносятся между вашими устройствами.',
                    ),
                    const SizedBox(height: 16),
                    if (state.saving) const LinearProgressIndicator(),
                    if (state.error != null) Text(state.error!),
                    if (reviews.isEmpty)
                      const Text(
                        'Решений пока нет. Откройте найденное повторение в анализе, проверьте операции и подтвердите или отклоните его.',
                      ),
                    for (final review in reviews)
                      Builder(
                        builder: (context) {
                          final rows =
                              snapshot.entries
                                  .where(
                                    (e) => review.proposal.sourceIds.contains(
                                      e.id,
                                    ),
                                  )
                                  .toList()
                                ..sort((a, b) => a.date.compareTo(b.date));
                          final valid = review.validAt(snapshot, vm.today);
                          final linked = linkedSeriesPlan(
                            snapshot,
                            review,
                            vm.today,
                          );
                          final accepted =
                              review.decision == SeriesDecision.accepted;
                          final cadence = switch (review.proposal.cadence) {
                            SeriesCadence.weekly => 'Еженедельно',
                            SeriesCadence.monthly => 'Ежемесячно',
                            SeriesCadence.yearly => 'Ежегодно',
                          };
                          return Card(
                            elevation: 0,
                            color: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: const BorderSide(color: LedgerColors.line),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    rows.isEmpty
                                        ? 'Исходные операции недоступны'
                                        : '${rows.first.kind.label}: ${rows.first.note}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${accepted ? 'Подтверждено' : 'Отклонено'} · $cadence · ${calendarDate(review.reviewedOn)}',
                                  ),
                                  if (rows.isNotEmpty)
                                    Text(
                                      'Счёт: ${snapshot.accounts.where((a) => a.id == rows.first.accountId).firstOrNull?.name ?? 'удалён'}',
                                    ),
                                  if (!valid)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                        'Решение сейчас не применяется. Проверьте исходные операции и дату подтверждения.',
                                      ),
                                    ),
                                  ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    title: const Text('Исходные операции'),
                                    children: [
                                      for (final row in rows)
                                        ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: Text(
                                            '${calendarDate(row.date)} · ${row.category}',
                                          ),
                                          subtitle: Text(
                                            formatMoney(
                                              row.amountMinor,
                                              vm.currency,
                                            ),
                                          ),
                                        ),
                                      if (rows.length !=
                                          review.proposal.sourceIds.length)
                                        const Text('Часть операций удалена.'),
                                    ],
                                  ),
                                  if (review.planLink != null)
                                    Text(
                                      linked == null
                                          ? 'Связь с планом сейчас не действует. Проверьте план и исходные операции.'
                                          : 'План: ${linked.name}',
                                    ),
                                  if (accepted && valid)
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton(
                                        onPressed: state.saving || state.loading
                                            ? null
                                            : () => Navigator.push<void>(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      SeriesPlanPicker(
                                                        vm: vm,
                                                        seriesKey:
                                                            review.proposal.key,
                                                      ),
                                                ),
                                              ),
                                        child: Text(
                                          review.planLink == null
                                              ? 'Связать с планом'
                                              : 'Изменить связь',
                                        ),
                                      ),
                                    ),
                                  if (review.planLink != null)
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton(
                                        onPressed: state.saving || state.loading
                                            ? null
                                            : () => state.unlinkSeries(
                                                review.proposal.key,
                                              ),
                                        child: const Text('Убрать связь'),
                                      ),
                                    ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton(
                                      onPressed: state.saving || state.loading
                                          ? null
                                          : () => state.forgetSeries(
                                              review.proposal.key,
                                            ),
                                      child: const Text('Отменить решение'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
