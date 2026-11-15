import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../data/finance_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'finance_view_model.dart';
import 'form_dialog.dart';

String userError(Object error) => switch (error) {
  DomainError(:final message) => message,
  FormatException(:final message) => message,
  _ => 'Не удалось сохранить. Попробуйте ещё раз.',
};

class AccountDialog extends StatefulWidget {
  const AccountDialog({super.key, required this.vm, this.account});
  final FinanceViewModel vm;
  final Account? account;
  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.account?.name ?? '');
  late final _opening = TextEditingController(
    text: editableMoney(widget.account?.openingMinor ?? 0),
  );
  late String _kind = widget.account?.kind ?? accountKinds.first;
  late bool _archived = widget.account?.archived ?? false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.vm.repository.saveAccount(
        id: widget.account?.id,
        expectedVersion: widget.account?.version,
        name: _name.text,
        kind: _kind,
        openingMinor: parseMoney(_opening.text, allowNegative: true),
        archived: _archived,
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
      title: Text(widget.account == null ? 'Новый счёт' : 'Изменить счёт'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('account-name'),
                controller: _name,
                enabled: !_saving,
                autofocus: true,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Название счёта'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Введите название' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Тип'),
                items: accountKinds
                    .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                    .toList(),
                onChanged: _saving ? null : (v) => setState(() => _kind = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('account-opening'),
                controller: _opening,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Начальный остаток',
                  suffixText: widget.vm.currency,
                ),
                validator: (v) {
                  try {
                    parseMoney(v ?? '', allowNegative: true);
                    return null;
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text('Остаток до начала учёта. Он не считается доходом.'),
              if (widget.account != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _archived,
                  title: const Text('Счёт в архиве'),
                  subtitle: const Text(
                    'Архивировать можно счёт с нулевым балансом.',
                  ),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _archived = v!),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
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
          key: const Key('save-account'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
        ),
      ],
    ),
  );
}

class EntryDialog extends StatefulWidget {
  const EntryDialog({super.key, required this.vm, this.entry});
  final FinanceViewModel vm;
  final LedgerEntry? entry;
  @override
  State<EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<EntryDialog> {
  final _form = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: widget.entry == null ? '' : editableMoney(widget.entry!.amountMinor),
  );
  late final _category = TextEditingController(
    text: widget.entry?.category ?? expenseCategories.first,
  );
  late final _note = TextEditingController(text: widget.entry?.note ?? '');
  late EntryKind _kind = widget.entry?.kind ?? EntryKind.expense;
  late DateTime _date = widget.entry?.date ?? widget.vm.today;
  late String _account = widget.entry?.accountId ?? _accounts.first.id;
  late String? _target = widget.entry?.targetAccountId;
  late String? _refundOf = widget.entry?.refundOf;
  String? _error;
  bool _saving = false;

  List<Account> get _accounts => widget.vm.snapshot!.accounts
      .where(
        (a) =>
            !a.archived ||
            a.id == widget.entry?.accountId ||
            a.id == widget.entry?.targetAccountId,
      )
      .toList();

  @override
  void dispose() {
    _amount.dispose();
    _category.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.vm.repository.saveEntry(
        id: widget.entry?.id,
        expectedVersion: widget.entry?.version,
        kind: _kind,
        amountMinor: parseMoney(_amount.text),
        date: _date,
        accountId: _account,
        targetAccountId: _target,
        category: _category.text,
        note: _note.text,
        refundOf: _refundOf,
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
  Widget build(BuildContext context) {
    final refundOptions = widget.vm.snapshot!.entries
        .where((e) => e.kind == EntryKind.expense)
        .toList();
    return PopScope(
      canPop: !_saving,
      child: LedgerFormDialog(
        title: Text(
          widget.entry == null ? 'Новая операция' : 'Изменить операцию',
        ),
        content: SizedBox(
          width: 480,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<EntryKind>(
                  key: const Key('entry-kind'),
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: 'Операция'),
                  items: EntryKind.values
                      .map(
                        (k) => DropdownMenuItem(value: k, child: Text(k.label)),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                          _kind = v!;
                          _category.text = v == EntryKind.income
                              ? incomeCategories.first
                              : expenseCategories.first;
                        }),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('entry-amount'),
                  controller: _amount,
                  enabled: !_saving,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Сумма',
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
                DropdownButtonFormField<String>(
                  initialValue: _account,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _kind == EntryKind.transfer ? 'Откуда' : 'Счёт',
                  ),
                  items: _accounts
                      .map(
                        (a) => DropdownMenuItem(
                          value: a.id,
                          child: Text(a.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                          _account = v!;
                          if (_target == v) _target = null;
                        }),
                ),
                if (_kind == EntryKind.transfer) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('target-$_account'),
                    initialValue: _target,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Куда'),
                    items: _accounts
                        .where((a) => a.id != _account)
                        .map(
                          (a) => DropdownMenuItem(
                            value: a.id,
                            child: Text(a.name),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _target = v),
                    validator: (v) =>
                        v == null ? 'Выберите счёт получателя' : null,
                  ),
                ] else if (_kind == EntryKind.refund) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const Key('entry-refund-source'),
                    initialValue: _refundOf,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Исходный расход',
                    ),
                    items: refundOptions
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.id,
                            child: Text(
                              '${e.category} · ${formatMoney(e.amountMinor, widget.vm.currency)} · ${DateFormat('dd.MM.yy').format(e.date)}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _refundOf = v),
                    validator: (v) => v == null ? 'Выберите расход' : null,
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('entry-category'),
                    controller: _category,
                    enabled: !_saving,
                    maxLength: 60,
                    decoration: const InputDecoration(labelText: 'Категория'),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Укажите категорию'
                        : null,
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children:
                        (_kind == EntryKind.income
                                ? incomeCategories
                                : expenseCategories.take(5))
                            .map(
                              (c) => ActionChip(
                                label: Text(c),
                                onPressed: _saving
                                    ? null
                                    : () => setState(() => _category.text = c),
                              ),
                            )
                            .toList(),
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  label: Text(DateFormat('d MMMM yyyy', 'ru').format(_date)),
                  onPressed: _saving
                      ? null
                      : () async {
                          final result = await showDatePicker(
                            context: context,
                            initialDate: _date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (result != null && mounted) {
                            setState(() => _date = result);
                          }
                        },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _note,
                  enabled: !_saving,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Комментарий',
                    hintText: 'Необязательно',
                  ),
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
            key: const Key('save-entry'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }
}
