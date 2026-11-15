import 'package:material_ui/material_ui.dart';

import '../../domain/insights/series_plan_link.dart';
import '../../domain/models.dart';
import '../../domain/money.dart';
import '../finance_view_model.dart';

class SeriesPlanPicker extends StatelessWidget {
  const SeriesPlanPicker({
    super.key,
    required this.vm,
    required this.seriesKey,
  });
  final FinanceViewModel vm;
  final String seriesKey;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm,
    builder: (context, _) => ListenableBuilder(
      listenable: vm.insights,
      builder: (context, _) {
        final state = vm.insights,
            review = state.policy.seriesReviews[seriesKey];
        final plans = review == null
            ? <Obligation>[]
            : availableSeriesPlans(
                vm.snapshot!,
                state.policy,
                review,
                vm.today,
              );
        return Scaffold(
          appBar: AppBar(title: const Text('Выберите план')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: plans.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Выберите существующий план с тем же типом и периодичностью. Планы другого счёта и уже связанные планы исключены. Связь не помечает операции оплаченными и не изменяет суммы.',
                          ),
                          const SizedBox(height: 16),
                          if (state.saving) const LinearProgressIndicator(),
                          if (state.error != null) Text(state.error!),
                          if (plans.isEmpty)
                            const Text(
                              'Подходящих свободных планов нет. Создайте план в разделе платежей или отмените прежнюю связь.',
                            ),
                        ],
                      );
                    }
                    final plan = plans[index - 1];
                    final account = vm.snapshot!.accounts
                        .where((a) => a.id == plan.accountId)
                        .firstOrNull;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(plan.name),
                      subtitle: Text(
                        '${formatMoney(plan.amountMinor, vm.currency)} · ${plan.repeat.label}\nСчёт: ${account?.name ?? 'не выбран'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: state.saving || state.loading
                          ? null
                          : () async {
                              final saved = await state.linkSeries(
                                seriesKey,
                                plan,
                              );
                              if (!context.mounted) return;
                              if (saved) {
                                Navigator.pop(context);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      state.error ?? 'Связь не сохранена',
                                    ),
                                  ),
                                );
                              }
                            },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
