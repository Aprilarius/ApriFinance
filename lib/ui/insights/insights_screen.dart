import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../domain/insights/insight.dart';
import '../../domain/insights/series_review.dart';
import '../../domain/models.dart';
import '../../domain/money.dart';
import '../budget_dialog.dart';
import '../dialogs.dart';
import '../finance_view_model.dart';
import '../payment_dialogs.dart';
import '../purchase_dialog.dart';
import '../theme.dart';
import 'insights_settings.dart';
import 'series_reviews_screen.dart';
import 'analysis_setup_screen.dart';

String insightKindLabel(InsightKind kind) => switch (kind) {
  InsightKind.fact => 'По внесённым данным',
  InsightKind.scenario => 'Сценарий',
  InsightKind.check => 'Проверьте',
  InsightKind.insufficient => 'Недостаточно данных',
};
String insightGroupLabel(InsightGroup group) => switch (group) {
  InsightGroup.expenses => 'Расходы и доходы',
  InsightGroup.payments => 'Платежи и сроки',
  InsightGroup.scenarios => 'Сценарии',
  InsightGroup.quality => 'Качество данных',
  InsightGroup.summaries => 'Сводки',
  InsightGroup.patterns => 'Повторения и необычное',
  InsightGroup.planning => 'Резервы, цели и долги',
};

Future<void> openInsights(BuildContext context, FinanceViewModel vm) =>
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => InsightsScreen(vm: vm)),
    );

class InsightsPreview extends StatelessWidget {
  const InsightsPreview({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm.insights,
    builder: (context, _) {
      final state = vm.insights;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Анализ и рекомендации',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              TextButton(
                key: const Key('open-insights'),
                onPressed: () => openInsights(context, vm),
                child: const Text('Открыть анализ'),
              ),
            ],
          ),
          const Text('Расчёты по вашим записям выполняются на устройстве.'),
          if (state.loading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (state.error != null) Text(state.error!),
          if (!state.loading && state.error == null)
            for (final insight in selectInsightPreview(state.results))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(insight.title),
                subtitle: Text(insightKindLabel(insight.kind)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => InsightDetails(vm: vm, insight: insight),
                  ),
                ),
              ),
          if (!state.loading && state.error == null && state.results.isEmpty)
            const Text(
              'Нет рекомендаций для выбранного периода. Проверьте настройки правил.',
            ),
        ],
      );
    },
  );
}

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  InsightGroup? _group;
  bool _important = false;
  int _limit = 10;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.vm,
    builder: (context, _) => ListenableBuilder(
      listenable: widget.vm.insights,
      builder: (context, _) {
        final vm = widget.vm, state = vm.insights;
        final filtered = state.results
            .where(
              (i) =>
                  (_group == null || i.group == _group) &&
                  (!_important || i.priority >= 50),
            )
            .toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Анализ')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Анализ и рекомендации',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Только внесённые записи. Сценарии не меняют операции и не гарантируют будущий результат.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Предыдущий месяц',
                          onPressed: () {
                            _limit = 10;
                            vm.changeMonth(-1);
                          },
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text(
                          DateFormat('LLLL yyyy', 'ru').format(vm.month),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        IconButton(
                          tooltip: 'Следующий месяц',
                          onPressed: () {
                            _limit = 10;
                            vm.changeMonth(1);
                          },
                          icon: const Icon(Icons.chevron_right),
                        ),
                        OutlinedButton.icon(
                          key: const Key('insights-settings'),
                          onPressed: state.loading || state.saving
                              ? null
                              : () => showDialog<void>(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (_) => InsightsSettings(vm: vm),
                                ),
                          icon: const Icon(Icons.tune),
                          label: const Text('Настройки анализа'),
                        ),
                        TextButton.icon(
                          key: const Key('series-reviews'),
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SeriesReviewsScreen(vm: vm),
                            ),
                          ),
                          icon: const Icon(Icons.repeat),
                          label: const Text('Серии'),
                        ),
                        TextButton.icon(
                          key: const Key('analysis-data'),
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AnalysisSetupScreen(vm: vm),
                            ),
                          ),
                          icon: const Icon(Icons.edit_note),
                          label: const Text('Данные анализа'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Все'),
                          selected: _group == null,
                          onSelected: (_) => setState(() {
                            _group = null;
                            _limit = 10;
                          }),
                        ),
                        for (final g in InsightGroup.values)
                          ChoiceChip(
                            label: Text(insightGroupLabel(g)),
                            selected: _group == g,
                            onSelected: (_) => setState(() {
                              _group = g;
                              _limit = 10;
                            }),
                          ),
                        FilterChip(
                          label: const Text('Важно'),
                          selected: _important,
                          onSelected: (v) => setState(() {
                            _important = v;
                            _limit = 10;
                          }),
                        ),
                      ],
                    ),
                    if (state.loading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      ),
                    if (state.error != null) ...[
                      const SizedBox(height: 16),
                      Text(state.error!),
                      TextButton(
                        onPressed: state.loading ? null : state.retry,
                        child: const Text('Повторить расчёт'),
                      ),
                      if (!state.initialized)
                        TextButton(
                          onPressed: state.saving
                              ? null
                              : () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                      scrollable: true,
                                      title: const Text(
                                        'Сбросить настройки анализа?',
                                      ),
                                      content: const Text(
                                        'Будут сброшены только пороги, скрытые рекомендации и подтверждения полноты учёта. Финансовые записи сохранятся.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c, false),
                                          child: const Text('Отмена'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Сбросить'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    await state.configure(
                                      AnalysisPolicy(),
                                      recover: true,
                                    );
                                  }
                                },
                          child: const Text('Сбросить настройки анализа'),
                        ),
                    ],
                    if (!state.loading && state.error == null) ...[
                      const SizedBox(height: 16),
                      Text('Найдено: ${filtered.length}'),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            state.policy.disabled.length == insightRules.length
                                ? 'Все правила выключены. Включите нужные в настройках.'
                                : _group != null || _important
                                ? 'По этому фильтру рекомендаций нет.'
                                : 'Существенных рекомендаций нет. Проверьте скрытые карточки и настройки правил.',
                          ),
                        ),
                      for (final insight in filtered.take(_limit))
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Card(
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
                                    insightKindLabel(insight.kind),
                                    style: const TextStyle(
                                      color: LedgerColors.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    insight.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(insight.explanation),
                                  for (final amount
                                      in insight.amounts.entries.take(2))
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        '${amount.key}: ${formatMoney(amount.value, vm.currency)}',
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  TextButton(
                                    onPressed: () => Navigator.push<void>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => InsightDetails(
                                          vm: vm,
                                          insight: insight,
                                        ),
                                      ),
                                    ),
                                    child: const Text(
                                      'Объяснение и исходные записи',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (filtered.length > _limit)
                        TextButton(
                          onPressed: () => setState(() => _limit += 10),
                          child: const Text('Показать ещё'),
                        ),
                    ],
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

class InsightDetails extends StatelessWidget {
  const InsightDetails({super.key, required this.vm, required this.insight});
  final FinanceViewModel vm;
  final Insight insight;

  Future<void> _edit(BuildContext context, InsightEvidence evidence) async {
    final s = vm.snapshot!;
    Widget? dialog;
    switch (evidence.kind) {
      case EvidenceKind.profile:
        final section = evidence.id.split(':').first;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => AnalysisSetupScreen(
              vm: vm,
              initialSection:
                  {
                    'backup': 'history',
                    'thresholds': 'ruleMinimums',
                    'scenario': 'scenarioCategories',
                  }[section] ??
                  section,
            ),
          ),
        );
        return;
      case EvidenceKind.entry:
        final e = s.entries.where((e) => e.id == evidence.id).firstOrNull;
        if (e != null) dialog = EntryDialog(vm: vm, entry: e);
      case EvidenceKind.account:
        final a = s.accounts.where((a) => a.id == evidence.id).firstOrNull;
        if (a != null) dialog = AccountDialog(vm: vm, account: a);
      case EvidenceKind.budget:
        final b = s.budgets.where((b) => b.id == evidence.id).firstOrNull;
        if (b != null) dialog = BudgetDialog(vm: vm, budget: b);
      case EvidenceKind.obligation:
        final o = s.obligations.where((o) => o.id == evidence.id).firstOrNull;
        if (o != null) dialog = ObligationDialog(vm: vm, obligation: o);
      case EvidenceKind.purchase:
        final p = s.purchases.where((p) => p.id == evidence.id).firstOrNull;
        if (p != null) dialog = PurchaseDialog(vm: vm, purchase: p);
    }
    if (dialog == null || !context.mounted) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => dialog!,
    );
    if (changed == true) await vm.refresh();
  }

  String _label(InsightEvidence evidence) {
    final s = vm.snapshot!;
    switch (evidence.kind) {
      case EvidenceKind.profile:
        return 'Открыть данные анализа: ${const {'history': 'история учёта', 'backup': 'резервные копии', 'thresholds': 'пороги', 'priorities': 'приоритеты', 'scenario': 'выбранный сценарий', 'reserves': 'резервы', 'goals': 'цели', 'debts': 'долги', 'refunds': 'ожидаемые возвраты', 'tracked': 'отслеживание', 'categoryAliases': 'алиасы категорий', 'counterpartyAliases': 'продавцы и источники'}[evidence.id.split(':').first] ?? 'настройки'}';
      case EvidenceKind.entry:
        final e = s.entries.where((e) => e.id == evidence.id).firstOrNull;
        return e == null
            ? 'Операция удалена'
            : '${calendarDate(e.date)} · ${e.kind.label} · ${e.category}\n${formatMoney(e.amountMinor, vm.currency)}${e.note.isEmpty ? '' : '\n${e.note}'}';
      case EvidenceKind.account:
        return 'Счёт: ${s.accounts.where((a) => a.id == evidence.id).firstOrNull?.name ?? 'удалён'}';
      case EvidenceKind.budget:
        return 'Лимит: ${s.budgets.where((b) => b.id == evidence.id).firstOrNull?.category ?? 'удалён'}';
      case EvidenceKind.obligation:
        return 'Платёж: ${s.obligations.where((o) => o.id == evidence.id).firstOrNull?.name ?? 'удалён'}';
      case EvidenceKind.purchase:
        return 'Покупка: ${s.purchases.where((p) => p.id == evidence.id).firstOrNull?.name ?? 'удалена'}';
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm,
    builder: (context, _) => ListenableBuilder(
      listenable: vm.insights,
      builder: (context, _) {
        final evidence = insight.evidence.toSet().toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Объяснение')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: evidence.length + 1,
                  itemBuilder: (context, index) {
                    if (index > 0) {
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_label(evidence[index - 1])),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: vm.loading
                            ? null
                            : () => _edit(context, evidence[index - 1]),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          insight.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${insightKindLabel(insight.kind)} · ${insight.rule}',
                        ),
                        const SizedBox(height: 12),
                        Text(insight.explanation),
                        for (final amount in insight.amounts.entries)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              '${amount.key}: ${formatMoney(amount.value, vm.currency)}',
                            ),
                          ),
                        const SizedBox(height: 16),
                        const Text(
                          'Расчёт зафиксирован при открытии карточки. Ниже — текущее состояние исходных записей; после правок вернитесь в анализ за новым расчётом.',
                        ),
                        if (insight.timeline.isNotEmpty)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text(insight.timelineTitle),
                            children: [
                              for (final day in insight.timeline)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(calendarDate(day.date)),
                                  subtitle: Text(
                                    formatMoney(day.balanceMinor, vm.currency),
                                  ),
                                ),
                            ],
                          ),
                        if (vm.insights.error != null) Text(vm.insights.error!),
                        if ({'J1', 'J4'}.contains(insight.rule))
                          TextButton(
                            onPressed: vm.insights.saving || vm.insights.loading
                                ? null
                                : () async {
                                    final saved = await vm.insights
                                        .trackRecommendation(insight);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                saved
                                                    ? 'Рекомендация добавлена в отслеживание. Сравнение появится за следующий завершённый подтверждённый месяц.'
                                                    : vm.insights.error ?? 'Не удалось начать отслеживание',
                                              ),
                                            ),
                                          );
                                    }
                                  },
                            child: const Text('Отслеживать результат'),
                          ),
                        if (insight.seriesProposal != null) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Связаны ли эти операции одним повторением? Решение действует с сегодняшнего дня. После изменения исходных операций потребуется новая проверка.',
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (decision, label) in [
                                (
                                  SeriesDecision.accepted,
                                  'Подтвердить повторение',
                                ),
                                (SeriesDecision.rejected, 'Это не повторение'),
                              ])
                                OutlinedButton(
                                  onPressed:
                                      vm.insights.saving || vm.insights.loading
                                      ? null
                                      : () async {
                                          if (await vm.insights.reviewSeries(
                                                insight.seriesProposal!,
                                                decision,
                                              ) &&
                                              context.mounted) {
                                            Navigator.pop(context);
                                          }
                                        },
                                  child: Text(label),
                                ),
                            ],
                          ),
                        ],
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: vm.insights.saving
                                  ? null
                                  : () async {
                                      if (await vm.insights.hide(insight) &&
                                          context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                              child: const Text('Скрыть на этот период'),
                            ),
                            TextButton(
                              onPressed: vm.insights.saving
                                  ? null
                                  : () async {
                                      if (await vm.insights.snooze(
                                            insight,
                                            vm.today,
                                          ) &&
                                          context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                              child: const Text('Отложить на 7 дней'),
                            ),
                            TextButton(
                              onPressed: vm.insights.saving
                                  ? null
                                  : () async {
                                      if (await vm.insights.disable(
                                            insight.rule,
                                          ) &&
                                          context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                              child: const Text('Выключить это правило'),
                            ),
                          ],
                        ),
                        const Divider(),
                        Text(
                          'Исходные записи: ${evidence.length}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
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
