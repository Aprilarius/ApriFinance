import 'package:material_ui/material_ui.dart';

import '../../domain/insights/insight.dart';
import '../../domain/models.dart';
import '../../domain/money.dart';
import '../finance_view_model.dart';
import '../form_dialog.dart';

class InsightsSettings extends StatefulWidget {
  const InsightsSettings({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  State<InsightsSettings> createState() => _InsightsSettingsState();
}

class _InsightsSettingsState extends State<InsightsSettings> {
  final _form = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: editableMoney(widget.vm.insights.policy.minimumChangeMinor),
  );
  late final _change = TextEditingController(
    text: '${widget.vm.insights.policy.changePercent}',
  );
  late final _near = TextEditingController(
    text: '${widget.vm.insights.policy.nearLimitPercent}',
  );
  late final _scenario = TextEditingController(
    text: '${widget.vm.insights.policy.scenarioPercent}',
  );
  late final _small = TextEditingController(
    text: editableMoney(widget.vm.insights.policy.smallExpenseMinor),
  );
  late final _delay = TextEditingController(
    text: '${widget.vm.insights.policy.incomeDelayDays}',
  );
  late final _disabled = {...widget.vm.insights.policy.disabled};
  late final _verified = {...widget.vm.insights.policy.verifiedThrough};
  late final _hashes = {...widget.vm.insights.policy.verifiedHashes};
  bool _resetHidden = false, _busy = false;
  String? _error;
  @override
  void dispose() {
    for (final c in [_amount, _change, _near, _scenario, _small, _delay]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = widget.vm.insights;
    final next = state.policy.copyWith(
      minimumChangeMinor: parseMoney(_amount.text),
      changePercent: int.parse(_change.text),
      nearLimitPercent: int.parse(_near.text),
      scenarioPercent: int.parse(_scenario.text),
      smallExpenseMinor: parseMoney(_small.text),
      incomeDelayDays: int.parse(_delay.text),
      disabled: _disabled,
      verifiedThrough: _verified,
      verifiedHashes: _hashes,
      hidden: _resetHidden ? {} : null,
      snoozed: _resetHidden ? {} : null,
    );
    final saved = await state.configure(next);
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error =
            state.error ??
            'Настройки ещё загружаются. Попробуйте повторить расчёт.';
      });
    }
  }

  Widget _percent(
    TextEditingController controller,
    String label,
    int maximum,
  ) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextFormField(
      controller: controller,
      enabled: !_busy,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      validator: (v) {
        final n = int.tryParse(v ?? '');
        return n == null || n < 1 || n > maximum
            ? 'Укажите целое число от 1 до $maximum'
            : null;
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final thisEnd = DateTime(vm.month.year, vm.month.month + 1, 0);
    final end = thisEnd.isAfter(vm.today) ? vm.today : thisEnd;
    final prev = DateTime(vm.month.year, vm.month.month, 0);
    final days = end.day.clamp(1, prev.day);
    final dates = [end, DateTime(prev.year, prev.month, days)];
    return PopScope(
      canPop: !_busy,
      child: LedgerFormDialog(
        title: const Text('Настройки анализа'),
        content: SizedBox(
          width: 520,
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Настройки меняют только анализ. В установленном приложении они сохраняются вместе с базой и включаются в зашифрованную копию .mfin.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('insights-minimum'),
                  controller: _amount,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Значимое изменение, ${vm.currency}',
                  ),
                  validator: (v) {
                    try {
                      return parseMoney(v ?? '') > 0
                          ? null
                          : 'Укажите сумму больше нуля';
                    } on FormatException catch (e) {
                      return e.message;
                    }
                  },
                ),
                _percent(_change, 'Изменение, минимум %', 1000),
                _percent(_near, 'Приближение к лимиту, %', 100),
                _percent(_scenario, 'Сокращение в сценарии, %', 100),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('insights-small'),
                  controller: _small,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Мелкий расход, не более ${vm.currency}',
                  ),
                  validator: (v) {
                    try {
                      return parseMoney(v ?? '') > 0
                          ? null
                          : 'Укажите сумму больше нуля';
                    } on FormatException catch (e) {
                      return e.message;
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('insights-income-delay'),
                  controller: _delay,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Задержка планового дохода, дней',
                  ),
                  validator: (v) {
                    final days = int.tryParse(v ?? '');
                    return days == null || days < 1 || days > 90
                        ? 'Укажите от 1 до 90 дней'
                        : null;
                  },
                ),
                const SizedBox(height: 20),
                Text(
                  'Полнота учёта',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text(
                  'Подтверждайте только периоды, за которые внесены все доходы, расходы и возвраты. Наличие записей само по себе этого не доказывает.',
                ),
                if (!DateTime(vm.month.year, vm.month.month).isAfter(vm.today))
                  for (final d in dates)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Все операции внесены: ${calendarDate(DateTime(d.year, d.month))} — ${calendarDate(d)}',
                      ),
                      value:
                          (_verified[monthKey(d)] ?? '').compareTo(
                                calendarDate(d),
                              ) >=
                              0 &&
                          _hashes[monthKey(d)] ==
                              coverageHash(
                                vm.snapshot!,
                                parseCalendarDate(_verified[monthKey(d)]!),
                              ),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                _verified[monthKey(d)] = calendarDate(d);
                                _hashes[monthKey(d)] = coverageHash(
                                  vm.snapshot!,
                                  d,
                                );
                              } else {
                                _verified.remove(monthKey(d));
                                _hashes.remove(monthKey(d));
                              }
                            }),
                    ),
                const SizedBox(height: 16),
                Text('Правила', style: Theme.of(context).textTheme.titleLarge),
                for (final rule in insightRules.entries)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(rule.value),
                    value: !_disabled.contains(rule.key),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            if (v) {
                              _disabled.remove(rule.key);
                            } else {
                              _disabled.add(rule.key);
                            }
                          }),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Вернуть скрытые и отложенные карточки'),
                  value: _resetHidden,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _resetHidden = v!),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('save-insights-settings'),
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Сохраняем…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }
}
