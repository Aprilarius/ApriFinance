import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../data/finance_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/schedule_math.dart';
import 'dialogs.dart';
import 'finance_view_model.dart';
import 'form_dialog.dart';

class ObligationDialog extends StatefulWidget {
  const ObligationDialog({super.key, required this.vm, this.obligation});
  final FinanceViewModel vm;
  final Obligation? obligation;
  @override
  State<ObligationDialog> createState() => _ObligationDialogState();
}

class _ObligationDialogState extends State<ObligationDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.obligation?.name ?? '');
  late final _amount = TextEditingController(
    text: widget.obligation == null
        ? ''
        : editableMoney(widget.obligation!.amountMinor),
  );
  late final _category = TextEditingController(
    text: widget.obligation?.category ?? 'Подписки',
  );
  late final _url = TextEditingController(
    text: widget.obligation?.manageUrl ?? '',
  );
  late EntryKind _kind = widget.obligation?.kind ?? EntryKind.expense;
  late RepeatRule _repeat = widget.obligation?.repeat ?? RepeatRule.monthly;
  late DateTime _anchor = widget.obligation?.anchor ?? widget.vm.today;
  late DateTime? _trial = widget.obligation?.trialEnd;
  late String? _account = widget.obligation?.accountId;
  late int _reminder = widget.obligation?.reminderDays ?? 3;
  late bool _paused = widget.obligation?.paused ?? false;
  bool _saving = false;
  String? _error;
  bool get _locked => (widget.obligation?.nextIndex ?? 0) > 0;
  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _category.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pick(bool trial) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: trial ? (_trial ?? _anchor) : _anchor,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (mounted && selected != null) {
      setState(() {
        if (trial) {
          _trial = selected;
        } else {
          _anchor = selected;
        }
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.vm.repository.saveObligation(
        Obligation(
          id: widget.obligation?.id ?? widget.vm.repository.newId(),
          name: _name.text,
          kind: _kind,
          amountMinor: parseMoney(_amount.text),
          category: _category.text,
          anchor: _anchor,
          repeat: _repeat,
          accountId: _account,
          paused: _paused,
          trialEnd: _trial,
          reminderDays: _reminder,
          manageUrl: _url.text,
        ),
        expectedVersion: widget.obligation?.version,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: LedgerFormDialog(
      title: Text(
        widget.obligation == null ? 'Новый платёж' : 'Изменить платёж',
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('payment-name'),
                controller: _name,
                enabled: !_saving,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Название'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Введите название' : null,
              ),
              DropdownButtonFormField<EntryKind>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Тип'),
                items: [EntryKind.expense, EntryKind.income]
                    .map(
                      (k) => DropdownMenuItem(value: k, child: Text(k.label)),
                    )
                    .toList(),
                onChanged: _saving || _locked
                    ? null
                    : (v) => setState(() => _kind = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('payment-amount'),
                controller: _amount,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Ожидаемая сумма',
                  suffixText: widget.vm.currency,
                ),
                validator: (v) {
                  try {
                    return parseMoney(v ?? '') > 0
                        ? null
                        : 'Сумма должна быть больше нуля';
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _category,
                enabled: !_saving,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Категория'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Укажите категорию' : null,
              ),
              DropdownButtonFormField<RepeatRule>(
                initialValue: _repeat,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Периодичность'),
                items: RepeatRule.values
                    .map(
                      (r) => DropdownMenuItem(value: r, child: Text(r.label)),
                    )
                    .toList(),
                onChanged: _saving || _locked
                    ? null
                    : (v) => setState(() => _repeat = v!),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('payment-date'),
                onPressed: _saving || _locked ? null : () => _pick(false),
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text(
                  'Первый срок: ${DateFormat('dd.MM.yyyy').format(_anchor)}',
                ),
              ),
              if (_locked)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'История уже начата. Дата и периодичность сохранены для правильного учёта периодов.',
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: _account,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Счёт по умолчанию',
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Выбирать при оплате'),
                  ),
                  ...widget.vm.snapshot!.accounts.map(
                    (a) => DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(
                        '${a.name}${a.archived ? ' · архив' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: _saving ? null : (v) => setState(() => _account = v),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _reminder,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Напомнить'),
                items: [0, 1, 3, 7]
                    .map(
                      (d) => DropdownMenuItem(
                        value: d,
                        child: Text(
                          d == 0 ? 'В день срока' : 'За $d дн. заранее',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _reminder = v!),
              ),
              const SizedBox(height: 16),
              const Text('Также напомним в день срока.'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _saving ? null : () => _pick(true),
                child: Text(
                  _trial == null
                      ? 'Добавить конец пробного периода'
                      : 'Пробный период до ${DateFormat('dd.MM.yyyy').format(_trial!)}',
                ),
              ),
              if (_trial != null)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _trial = null),
                  child: const Text('Убрать пробный период'),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _url,
                enabled: !_saving,
                maxLength: 500,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Ссылка на управление',
                  hintText: 'https://… · необязательно',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Приостановлен'),
                value: _paused,
                onChanged: _saving ? null : (v) => setState(() => _paused = v),
              ),
              const Text(
                'Деньги учитываются только после подтверждения. Само приложение не списывает средства и не отменяет подписки у поставщика.',
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('save-payment'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
        ),
      ],
    ),
  );
}

class SettleDialog extends StatefulWidget {
  const SettleDialog({super.key, required this.vm, required this.obligation});
  final FinanceViewModel vm;
  final Obligation obligation;
  @override
  State<SettleDialog> createState() => _SettleDialogState();
}

class _SettleDialogState extends State<SettleDialog> {
  late final _amount = TextEditingController(
    text: editableMoney(widget.obligation.amountMinor),
  );
  late DateTime _date = widget.vm.today;
  late String _account =
      widget.vm.snapshot!.accounts
          .where((a) => !a.archived)
          .any((a) => a.id == widget.obligation.accountId)
      ? widget.obligation.accountId!
      : widget.vm.snapshot!.accounts.firstWhere((a) => !a.archived).id;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final o = widget.obligation;
      await widget.vm.repository.settleObligation(
        o.id,
        expectedVersion: o.version,
        periodIndex: o.nextIndex,
        paidOn: _date,
        amountMinor: parseMoney(_amount.text),
        accountId: _account,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = userError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: LedgerFormDialog(
      title: Text(
        widget.obligation.kind == EntryKind.income
            ? 'Подтвердить доход'
            : 'Подтвердить оплату',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.obligation.name),
            const SizedBox(height: 8),
            Text(
              'Период со сроком ${DateFormat('dd.MM.yyyy').format(periodDate(widget.obligation, widget.obligation.nextIndex))}',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('settle-amount'),
              controller: _amount,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Фактическая сумма',
                suffixText: widget.vm.currency,
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _account,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Счёт'),
              items: widget.vm.snapshot!.accounts
                  .where((a) => !a.archived)
                  .map(
                    (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                  )
                  .toList(),
              onChanged: _busy ? null : (v) => setState(() => _account = v!),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100, 12, 31),
                      );
                      if (mounted && date != null) {
                        setState(() => _date = date);
                      }
                    },
              child: Text(
                'Дата операции: ${DateFormat('dd.MM.yyyy').format(_date)}',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('confirm-settlement'),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Сохраняем…' : 'Подтвердить'),
        ),
      ],
    ),
  );
}
