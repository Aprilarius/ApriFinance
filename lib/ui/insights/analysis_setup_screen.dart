import 'package:material_ui/material_ui.dart';

import '../../domain/insights/analysis_profile.dart';
import '../../domain/insights/insight.dart';
import '../../domain/models.dart';
import '../../domain/money.dart';
import '../finance_view_model.dart';
import '../theme.dart';
import 'setup_form.dart';

class AnalysisSetupScreen extends StatelessWidget {
  const AnalysisSetupScreen({
    super.key,
    required this.vm,
    this.initialSection = 'history',
  });
  final FinanceViewModel vm;
  final String initialSection;
  AnalysisProfile get p => vm.insights.policy.profile;
  Map<String, Object?> get json => p.toJson();
  Map<String, String> get accounts => {
    for (final a in vm.snapshot!.accounts.where((a) => !a.archived))
      a.id: a.name,
  };
  Future<void> form(
    BuildContext context,
    String title,
    List<SetupField> fields,
    Map<String, Object?> initial,
    Future<bool> Function(Map<String, Object?>) save, {
    String help = '',
  }) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SetupForm(
      title: title,
      fields: fields,
      initial: initial,
      save: save,
      errorText: () => vm.insights.error,
      help: help,
    ),
  );
  Future<bool> upsertMap(
    String section,
    String key,
    Object value, [
    String? oldKey,
  ]) async {
    final map = Map<String, Object?>.from(json[section]! as Map);
    final cleaned = {'categoryAliases', 'counterpartyAliases'}.contains(section)
        ? normalizedLabel(key)
        : {'flexibleCaps', 'categoryMinimums'}.contains(section)
        ? p.category(key)
        : key;
    if (cleaned != oldKey && map.containsKey(cleaned)) {
      return vm.insights.profileError(
        'Такая настройка уже существует. Откройте её для изменения.',
      );
    }
    if (oldKey != null) map.remove(oldKey);
    map[cleaned] = value;
    return vm.insights.updateProfile({
      section: map,
    }, checkFunding: section == 'reserves');
  }

  Future<bool> upsertRecord(String section, Map<String, Object?> row) async {
    final records =
        (json[section]! as List)
            .map((r) => Map<String, Object?>.from(r as Map))
            .where((r) => r['id'] != row['id'])
            .toList()
          ..add(row);
    return vm.insights.updateProfile({
      section: records,
    }, checkFunding: section == 'goals');
  }

  Future<void> editMap(
    BuildContext context,
    String section, [
    String? key,
    Object? value,
  ]) {
    final isAlias =
        section == 'categoryAliases' || section == 'counterpartyAliases';
    final keyField = switch (section) {
      'reserves' => SetupField(
        'key',
        'Счёт',
        type: SetupFieldType.choice,
        choices: accounts,
      ),
      'ruleMinimums' => SetupField(
        'key',
        'Правило',
        type: SetupFieldType.choice,
        choices: {
          for (final id in ['B1', 'B2', 'H1', 'C5']) id: insightRules[id]!,
        },
      ),
      'priorities' => SetupField(
        'key',
        'Правило',
        type: SetupFieldType.choice,
        choices: insightRules,
      ),
      _ => SetupField(
        'key',
        isAlias ? 'Исходное название' : 'Категория, как в журнале',
      ),
    };
    final valField = isAlias
        ? const SetupField('value', 'Объединить под названием')
        : section == 'priorities'
        ? const SetupField(
            'value',
            'Приоритет от 0 до 100',
            type: SetupFieldType.integer,
            maximum: 100,
          )
        : SetupField(
            'value',
            section == 'reserves'
                ? 'Защищённая сумма, ${vm.currency}'
                : section == 'flexibleCaps'
                ? 'Потолок категории, ${vm.currency}'
                : 'Денежный порог, ${vm.currency}',
            type: SetupFieldType.money,
            minimum: {'ruleMinimums', 'categoryMinimums'}.contains(section)
                ? 1
                : 0,
          );
    return form(
      context,
      isAlias
          ? 'Подтверждённый алиас'
          : section == 'reserves'
          ? 'Резерв на счёте'
          : section == 'priorities'
          ? 'Приоритет правила'
          : 'Параметр категории или правила',
      [keyField, valField],
      {'key': key, 'value': value ?? (isAlias ? '' : 0)},
      (data) => upsertMap(section, data['key']! as String, data['value']!, key),
      help: isAlias
          ? 'Подтвердите, что это одна категория или один продавец. Исходные записи не меняются; циклы объединения запрещены.'
          : section == 'reserves'
          ? 'Это защищённая часть существующих денег. Вместе с целями она не может превышать остаток этого счёта на сегодня.'
          : section == 'ruleMinimums'
          ? 'Для C5 задаётся максимальная сумма мелкой покупки. Для B1/B2/H1 — минимальное денежное отклонение. Процент остаётся общим.'
          : 'Настройка меняет только анализ, финансовые операции не проводятся.',
    );
  }

  Future<void> editRecord(
    BuildContext context,
    String section, [
    Map<String, Object?>? existing,
  ]) {
    final today = vm.today, id = existing?['id'] ?? vm.repository.newId();
    if (section == 'goals') {
      return form(
        context,
        'Цель накоплений',
        [
          const SetupField('name', 'Название цели'),
          SetupField(
            'accountId',
            'Счёт с назначенными деньгами',
            type: SetupFieldType.choice,
            choices: accounts,
          ),
          SetupField(
            'targetMinor',
            'Целевая сумма, ${vm.currency}',
            type: SetupFieldType.money,
            minimum: 1,
          ),
          SetupField(
            'allocatedMinor',
            'Уже назначено цели, ${vm.currency}',
            type: SetupFieldType.money,
          ),
          SetupField(
            'initialMinor',
            'Сумма на старте графика, ${vm.currency}',
            type: SetupFieldType.money,
          ),
          SetupField(
            'monthlyMinor',
            'Плановый взнос за месяц, ${vm.currency}',
            type: SetupFieldType.money,
          ),
          const SetupField(
            'start',
            'Дата начала графика',
            type: SetupFieldType.date,
          ),
          const SetupField('deadline', 'Срок цели', type: SetupFieldType.date),
        ],
        existing ??
            {
              'id': id,
              'name': '',
              'accountId': null,
              'targetMinor': 0,
              'allocatedMinor': 0,
              'initialMinor': 0,
              'monthlyMinor': 0,
              'start': calendarDate(today),
              'deadline': calendarDate(
                DateTime(today.year + 1, today.month, today.day),
              ),
            },
        (data) => upsertRecord(section, data),
        help: 'Назначьте часть остатка одного счёта. Одинаковые деньги нельзя одновременно распределить в другие цели и резерв. Взнос 0 отключает проверку отставания от графика.',
      );
    }
    if (section == 'debts') {
      return form(
        context,
        'Параметры долга',
        [
          const SetupField('name', 'Название долга'),
          SetupField(
            'principalMinor',
            'Оставшаяся основная сумма, ${vm.currency}',
            type: SetupFieldType.money,
            minimum: 1,
          ),
          const SetupField(
            'annualRateBp',
            'Фиксированная годовая ставка, %',
            type: SetupFieldType.money,
            maximum: 100000,
          ),
          SetupField(
            'monthlyPaymentMinor',
            'Платёж за месяц, ${vm.currency}',
            type: SetupFieldType.money,
            minimum: 1,
          ),
          SetupField(
            'monthlyFeeMinor',
            'Ежемесячная комиссия, ${vm.currency}',
            type: SetupFieldType.money,
          ),
          const SetupField(
            'firstDue',
            'Дата следующего платежа',
            type: SetupFieldType.date,
          ),
        ],
        existing ??
            {
              'id': id,
              'name': '',
              'principalMinor': 0,
              'annualRateBp': 0,
              'monthlyPaymentMinor': 0,
              'monthlyFeeMinor': 0,
              'firstDue': calendarDate(
                DateTime(today.year, today.month + 1, today.day),
              ),
            },
        (data) => upsertRecord(section, data),
        help: 'Упрощённый сценарий: ставка / 12, процент округляется вверх, фиксированная комиссия каждый месяц. Он не заменяет условия кредитора, не создаёт расходы и планы. Отрицательный счёт сам по себе долгом не считается.',
      );
    }
    return form(
      context,
      'Ожидаемый возврат',
      [
        SetupField(
          'purchaseId',
          'Покупка с исходным расходом',
          type: SetupFieldType.choice,
          choices: {
            for (final r in vm.snapshot!.purchases.where(
              (r) => !r.archived && r.entryId != null,
            ))
              r.id: r.name,
          },
        ),
        SetupField(
          'expectedMinor',
          'Дополнительно ожидается, ${vm.currency}',
          type: SetupFieldType.money,
          minimum: 1,
        ),
        const SetupField('due', 'Ожидаемая дата', type: SetupFieldType.date),
      ],
      existing ??
          {
            'id': id,
            'purchaseId': null,
            'expectedMinor': 0,
            'due': calendarDate(
              DateTime(today.year, today.month, today.day + 14),
            ),
          },
      (data) async {
        final purchase = vm.snapshot!.purchases
            .where((r) => r.id == data['purchaseId'])
            .firstOrNull;
        if (purchase == null) {
          return vm.insights.profileError(
            'Покупка недоступна. Свяжите её с исходным расходом в карточке покупки.',
          );
        }
        return vm.insights.expectRefund(
          id: data['id']! as String,
          purchase: purchase,
          amountMinor: data['expectedMinor']! as int,
          due: parseCalendarDate(data['due']! as String),
        );
      },
      help: 'Укажите собственное ожидание, а не предполагаемый законный срок. Уже внесённые возвраты на момент добавления не считаются новыми поступлениями.',
    );
  }

  Future<void> editSelection(
    BuildContext context,
    String section, [
    String? old,
  ]) {
    final plans = {
      for (final o in vm.snapshot!.obligations.where(
        (o) => o.kind == EntryKind.expense && o.active,
      ))
        o.id: o.name,
    };
    return form(
      context,
      section == 'pausePlanIds'
          ? 'Пауза плана в сценарии'
          : 'Сокращение гибкой категории',
      [
        section == 'pausePlanIds'
            ? SetupField(
                'value',
                'Расходный план',
                type: SetupFieldType.choice,
                choices: plans,
              )
            : const SetupField('value', 'Категория'),
      ],
      {'value': old},
      (data) {
        final values = (json[section]! as List).cast<String>().toSet();
        if (old != null) values.remove(old);
        values.add(
          section == 'pausePlanIds'
              ? data['value']! as String
              : p.category(data['value']! as String),
        );
        return vm.insights.updateProfile({section: values.toList()});
      },
      help: section == 'pausePlanIds'
          ? 'Пауза действует только в сценарии. Настоящий план, оплаченные периоды и будущие внесённые операции не изменяются.'
          : 'Общий процент берётся из настроек анализа. Сокращаются только явно гибкие операции этой категории; возвраты и пересечения учитываются.',
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm,
    builder: (context, _) => ListenableBuilder(
      listenable: vm.insights,
      builder: (context, _) {
        final state = vm.insights,
            disabled = state.saving || state.loading || !state.initialized;
        final sections = <({String key, String title, Widget body})>[
          (
            key: 'history',
            title: 'История и резервные копии',
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Начало учёта: ${p.trackingStart == null ? 'не указано' : calendarDate(p.trackingStart!)}\nПоследний экспорт .mfin: ${p.lastBackupOn == null ? 'не подтверждён' : calendarDate(p.lastBackupOn!)}\nИнтервал копий: ${p.backupEveryDays} дней. Пропуск мелких покупок в сценарии: ${p.smallSkipCount}.',
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => form(
                          context,
                          'Общие данные анализа',
                          [
                            const SetupField(
                              'trackingStart',
                              'Начало полного учёта',
                              type: SetupFieldType.date,
                              optional: true,
                            ),
                            const SetupField(
                              'backupEveryDays',
                              'Интервал внешней копии, дней',
                              type: SetupFieldType.integer,
                              minimum: 1,
                              maximum: 365,
                            ),
                            const SetupField(
                              'smallSkipCount',
                              'Мелких гибких покупок исключить в сценарии',
                              type: SetupFieldType.integer,
                              maximum: 100,
                            ),
                          ],
                          {
                            'trackingStart': p.trackingStart == null
                                ? null
                                : calendarDate(p.trackingStart!),
                            'backupEveryDays': p.backupEveryDays,
                            'smallSkipCount': p.smallSkipCount,
                          },
                          state.updateProfile,
                          help: 'Подтверждайте полноту месяцев отдельно в настройках анализа. Для прогнозов нужны 112 последовательных дней, для сезонности — 24 полных месяца. Дата копии отмечается только после успешного сохранения файла.',
                        ),
                  child: const Text('Изменить общие данные'),
                ),
              ],
            ),
          ),
          (
            key: 'annotations',
            title: 'Метки операций и источников дохода',
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Метки: ${p.annotations.length}. Продавцы, источники дохода, роль расхода и разовые события задаются явно.',
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OperationAnnotationsScreen(vm: vm),
                          ),
                        ),
                  child: const Text('Открыть операции для разметки'),
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () {
                          final entries = {
                            for (final e in vm.snapshot!.entries) e.id: e,
                          };
                          state.updateProfile({
                            'annotations': {
                              for (final e in p.annotations.entries.where(
                                (e) =>
                                    entries[e.key] != null &&
                                    e.value.valid(entries[e.key]!),
                              ))
                                e.key: e.value.toJson(),
                            },
                          });
                        },
                  child: const Text('Убрать недействительные метки'),
                ),
              ],
            ),
          ),
          for (final (key, title) in [
            ('reserves', 'Резервы по счетам'),
            ('goals', 'Цели накоплений'),
            ('debts', 'Долги'),
            ('refunds', 'Ожидаемые возвраты'),
            ('flexibleCaps', 'Потолки гибких категорий'),
            ('scenarioCategories', 'Категории выбранного сценария'),
            ('pausePlanIds', 'Паузы планов в сценарии'),
            ('categoryAliases', 'Алиасы категорий'),
            ('counterpartyAliases', 'Алиасы продавцов и источников'),
            ('ruleMinimums', 'Пороги отдельных правил'),
            ('categoryMinimums', 'Пороги категорий для B2/H1'),
            ('priorities', 'Приоритеты правил'),
            ('tracked', 'Отслеживаемые рекомендации'),
          ])
            (key: key, title: title, body: _records(context, key, disabled)),
        ];
        final ordered = [
          ...sections.where((s) => s.key == initialSection),
          ...sections.where((s) => s.key != initialSection),
        ];
        return Scaffold(
          appBar: AppBar(title: const Text('Данные анализа')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'Явные настройки для расчётов. Они не проводят финансовые операции и включаются в зашифрованную копию .mfin. Подтверждения серий и полноты учёта сохраняются вместе с ними.',
                    ),
                    const SizedBox(height: 12),
                    if (state.saving) const LinearProgressIndicator(),
                    if (state.error != null) Text(state.error!),
                    for (final section in ordered)
                      Card(
                        elevation: 0,
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: const BorderSide(color: LedgerColors.line),
                        ),
                        child: ExpansionTile(
                          key: Key('analysis-section-${section.key}'),
                          initiallyExpanded: section.key == initialSection,
                          title: Text(section.title),
                          childrenPadding: const EdgeInsets.all(16),
                          children: [section.body],
                        ),
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
  Widget _records(BuildContext context, String section, bool disabled) {
    final value = json[section]!;
    final isList = value is List,
        isRecord = {'goals', 'debts', 'refunds', 'tracked'}.contains(section);
    final rows = isList
        ? value
              .map(
                (e) => isRecord
                    ? Map<String, Object?>.from(e as Map)
                    : <String, Object?>{'key': e},
              )
              .toList()
        : (value as Map).entries
              .map((e) => <String, Object?>{'key': e.key, 'value': e.value})
              .toList();
    String label(Map<String, Object?> row) {
      if (isRecord) {
        if (section == 'tracked') {
          return '${row['category']} · ${row['baselineMonth']}\nОриентир: ${formatMoney(row['targetMinor']! as int, vm.currency)}';
        }
        if (section == 'refunds') {
          return '${vm.snapshot!.purchases.where((r) => r.id == row['purchaseId']).firstOrNull?.name ?? 'Покупка недоступна'}\n${formatMoney(row['expectedMinor']! as int, vm.currency)} · ${row['due']}';
        }
        return '${row['name']}\n${formatMoney(row[section == 'goals' ? 'allocatedMinor' : 'principalMinor']! as int, vm.currency)}';
      }
      final key = row['key']! as String;
      final name = section == 'reserves'
          ? vm.snapshot!.accounts.where((a) => a.id == key).firstOrNull?.name ??
                'Счёт недоступен'
          : section == 'pausePlanIds'
          ? vm.snapshot!.obligations
                    .where((o) => o.id == key)
                    .firstOrNull
                    ?.name ??
                'План недоступен'
          : {'priorities', 'ruleMinimums'}.contains(section)
          ? insightRules[key] ?? key
          : key;
      return isList
          ? name
          : '$name\n${row['value'] is int && section != 'priorities' ? formatMoney(row['value']! as int, vm.currency) : row['value']}';
    }

    Future<void> remove(Map<String, Object?> row) async {
      if (isList) {
        await vm.insights.updateProfile({
          section: (json[section]! as List)
              .where(
                (e) =>
                    isRecord ? (e as Map)['id'] != row['id'] : e != row['key'],
              )
              .toList(),
        }, checkFunding: section == 'goals');
      } else {
        await vm.insights.updateProfile({
          section: Map<String, Object?>.from(json[section]! as Map)
            ..remove(row['key']),
        }, checkFunding: section == 'reserves');
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isEmpty) const Text('Пока не настроено.'),
        for (final row in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(label(row)),
            onTap: disabled || section == 'tracked'
                ? null
                : () => isRecord
                      ? editRecord(context, section, row)
                      : isList
                      ? editSelection(context, section, row['key']! as String)
                      : editMap(
                          context,
                          section,
                          row['key']! as String,
                          row['value'],
                        ),
            trailing: IconButton(
              tooltip: 'Удалить настройку',
              onPressed: disabled ? null : () => remove(row),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        if (section == 'tracked')
          const Text(
            'Откройте рекомендацию сокращения категории за завершённый подтверждённый месяц и нажмите «Отслеживать результат».',
          ),
        if (section != 'tracked')
          TextButton.icon(
            key: Key('add-analysis-$section'),
            onPressed: disabled
                ? null
                : () => isRecord
                      ? editRecord(context, section)
                      : isList
                      ? editSelection(context, section)
                      : editMap(context, section),
            icon: const Icon(Icons.add),
            label: const Text('Добавить'),
          ),
      ],
    );
  }
}

class OperationAnnotationsScreen extends StatefulWidget {
  const OperationAnnotationsScreen({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  State<OperationAnnotationsScreen> createState() =>
      _OperationAnnotationsScreenState();
}

class _OperationAnnotationsScreenState
    extends State<OperationAnnotationsScreen> {
  String query = '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.vm.insights,
    builder: (context, _) {
      final vm = widget.vm, state = vm.insights;
      final rows =
          vm.snapshot!.entries
              .where(
                (e) =>
                    (e.kind == EntryKind.expense ||
                        e.kind == EntryKind.income) &&
                    '${e.category} ${e.note} ${calendarDate(e.date)}'
                        .toLowerCase()
                        .contains(query.toLowerCase()),
              )
              .toList()
            ..sort((a, b) {
              final c = b.date.compareTo(a.date);
              return c != 0 ? c : a.id.compareTo(b.id);
            });
      final shown = rows.take(200).toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Метки операций')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: shown.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const Key('annotation-search'),
                          decoration: const InputDecoration(
                            labelText:
                                'Поиск по категории, комментарию или дате',
                          ),
                          onChanged: (v) => setState(() => query = v),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Показано ${shown.length} из ${rows.length}. Для другой операции уточните поиск. Метки не меняют сумму и счёт; после правки операции нужна новая проверка.',
                        ),
                        if (state.error != null) Text(state.error!),
                      ],
                    );
                  }
                  final e = shown[index - 1],
                      tag = state.policy.profile.annotation(e);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${calendarDate(e.date)} · ${e.kind.label} · ${e.category}',
                    ),
                    subtitle: Text(
                      '${formatMoney(e.amountMinor, vm.currency)}${e.note.isEmpty ? '' : '\n${e.note}'}${tag == null ? '' : '\nМетка сохранена: ${tag.counterparty}'}',
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: state.saving || state.loading
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => SetupForm(
                              title: 'Метки операции',
                              help: 'Подтвердите роль и продавца или источник дохода. Комментарий автоматически не переносится в подтверждённое поле.',
                              fields: [
                                if (e.kind == EntryKind.expense)
                                  const SetupField(
                                    'role',
                                    'Роль расхода',
                                    type: SetupFieldType.choice,
                                    choices: {
                                      'unspecified': 'Не указана',
                                      'mandatory': 'Обязательный',
                                      'flexible': 'Гибкий',
                                    },
                                  ),
                                SetupField(
                                  'counterparty',
                                  e.kind == EntryKind.income
                                      ? 'Подтверждённый источник дохода'
                                      : 'Подтверждённый продавец',
                                  optional: true,
                                ),
                                if (e.kind == EntryKind.expense)
                                  const SetupField(
                                    'oneOff',
                                    'Разовый расход: исключить из оценки обычных трат',
                                    type: SetupFieldType.toggle,
                                  ),
                              ],
                              initial: {
                                'role':
                                    (tag?.role ?? ExpenseRole.unspecified).name,
                                'counterparty': tag?.counterparty ?? '',
                                'oneOff': tag?.oneOff ?? false,
                              },
                              save: (data) => state.annotateEntry(
                                e,
                                ExpenseRole.values.byName(
                                  data['role']! as String,
                                ),
                                data['counterparty']! as String,
                                data['oneOff']! as bool,
                              ),
                              errorText: () => state.error,
                            ),
                          ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}
