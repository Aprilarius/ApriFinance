import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../domain/models.dart';
import '../domain/purchases.dart';
import '../domain/money.dart';
import '../data/finance_repository.dart';
import 'finance_view_model.dart';
import 'form_dialog.dart';
import 'dialogs.dart';

class PurchaseDialog extends StatefulWidget {
  const PurchaseDialog({super.key, required this.vm, this.purchase});
  final FinanceViewModel vm;
  final Purchase? purchase;
  @override
  State<PurchaseDialog> createState() => _PurchaseDialogState();
}

class _PurchaseDialogState extends State<PurchaseDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _amount, _store, _serial, _note;
  late DateTime _date;
  DateTime? _returnBy, _warranty;
  String _mode = 'none';
  String? _entry, _account;
  bool _archived = false, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final p = widget.purchase;
    _name = TextEditingController(text: p?.name ?? '');
    _amount = TextEditingController(
      text: p == null ? '' : editableMoney(p.amountMinor),
    );
    _store = TextEditingController(text: p?.store ?? '');
    _serial = TextEditingController(text: p?.serial ?? '');
    _note = TextEditingController(text: p?.note ?? '');
    _date = p?.date ?? widget.vm.today;
    _returnBy = p?.returnBy;
    _warranty = p?.warrantyUntil;
    _archived = p?.archived ?? false;
    _entry = p?.entryId;
    if (_entry != null) _mode = 'existing';
    _account = widget.vm.snapshot!.accounts
        .where((a) => !a.archived)
        .firstOrNull
        ?.id;
  }

  @override
  void dispose() {
    for (final c in [_name, _amount, _store, _serial, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(DateTime? current, void Function(DateTime) set) async {
    final d = await showDatePicker(
      context: context,
      initialDate: current ?? _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (d != null && mounted) setState(() => set(d));
  }

  Widget _dateField(
    String label,
    DateTime? date,
    void Function(DateTime) set,
    VoidCallback? clear,
  ) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TextButton.icon(
        onPressed: _busy ? null : () => _pick(date, set),
        icon: const Icon(Icons.calendar_today_outlined, size: 18),
        label: Text(
          '$label: ${date == null ? 'не указан' : DateFormat('dd.MM.yyyy').format(date)}',
        ),
      ),
      if (date != null && clear != null)
        IconButton(
          tooltip: 'Убрать срок',
          onPressed: _busy ? null : clear,
          icon: const Icon(Icons.close, size: 18),
        ),
    ],
  );
  Future<void> _save() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final amount = parseMoney(_amount.text);
      if (_mode == 'existing' && _entry == null) {
        throw const DomainError('Выберите расход');
      }
      if (_mode == 'new' && _account == null) {
        throw const DomainError('Сначала добавьте счёт');
      }
      await widget.vm.repository.savePurchase(
        Purchase(
          id: widget.purchase?.id ?? widget.vm.repository.newId(),
          name: _name.text,
          amountMinor: amount,
          date: _date,
          store: _store.text,
          serial: _serial.text,
          note: _note.text,
          returnBy: _returnBy,
          warrantyUntil: _warranty,
          archived: _archived,
          entryId: _mode == 'existing' ? _entry : null,
        ),
        expectedVersion: widget.purchase?.version,
        newExpenseAccountId: _mode == 'new' ? _account : null,
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
  Widget build(BuildContext context) {
    final s = widget.vm.snapshot!;
    final expenses =
        s.entries
            .where(
              (e) =>
                  e.kind == EntryKind.expense &&
                  !s.purchases.any(
                    (p) => p.id != widget.purchase?.id && p.entryId == e.id,
                  ),
            )
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    return PopScope(
      canPop: !_busy,
      child: LedgerFormDialog(
        title: Text(
          widget.purchase == null ? 'Новая покупка' : 'Карточка покупки',
        ),
        content: SizedBox(
          width: 520,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const Key('purchase-name'),
                  controller: _name,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'Название'),
                  enabled: !_busy,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Укажите название' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('purchase-mode'),
                  initialValue: _mode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Учёт денег'),
                  items: [
                    const DropdownMenuItem(
                      value: 'none',
                      child: Text('Только карточка'),
                    ),
                    const DropdownMenuItem(
                      value: 'existing',
                      child: Text('Связать с расходом'),
                    ),
                    if (widget.purchase == null)
                      const DropdownMenuItem(
                        value: 'new',
                        child: Text('Создать новый расход'),
                      ),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _mode = v!),
                ),
                const SizedBox(height: 8),
                Text(
                  _mode == 'none'
                      ? 'Баланс не изменится. Можно связать с расходом позже.'
                      : _mode == 'existing'
                      ? 'Повторного списания не будет. Стоимость совпадает с расходом.'
                      : 'При сохранении будет одна новая операция в категории «Покупки».',
                ),
                if (_mode == 'existing') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('purchase-entry'),
                    initialValue: _entry,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Расход'),
                    items: expenses
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.id,
                            child: Text(
                              '${DateFormat('dd.MM.yy').format(e.date)} · ${formatMoney(e.amountMinor, s.currency!)} · ${e.note.isEmpty ? e.category : e.note}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _entry = v;
                            final e = expenses.firstWhere((e) => e.id == v);
                            _amount.text = editableMoney(e.amountMinor);
                          }),
                  ),
                ],
                if (_mode == 'new') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('purchase-account'),
                    initialValue: _account,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Счёт списания',
                    ),
                    items: s.accounts
                        .where((a) => !a.archived)
                        .map(
                          (a) => DropdownMenuItem(
                            value: a.id,
                            child: Text(a.name),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _account = v),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('purchase-amount'),
                  controller: _amount,
                  enabled: !_busy,
                  readOnly: _mode == 'existing',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Стоимость, ${s.currency}',
                  ),
                ),
                const SizedBox(height: 12),
                _dateField('Дата покупки', _date, (d) => _date = d, null),
                _dateField(
                  'Возврат до',
                  _returnBy,
                  (d) => _returnBy = d,
                  () => setState(() => _returnBy = null),
                ),
                _dateField(
                  'Гарантия до',
                  _warranty,
                  (d) => _warranty = d,
                  () => setState(() => _warranty = null),
                ),
                const Text(
                  'Укажите сроки из условий продавца. Напоминания за 7 дней и в день срока включаются в Настройках на Android/macOS.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _store,
                  enabled: !_busy,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'Магазин'),
                ),
                TextFormField(
                  controller: _serial,
                  enabled: !_busy,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Серийный номер',
                  ),
                ),
                TextFormField(
                  controller: _note,
                  enabled: !_busy,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Заметка'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _archived,
                  title: const Text('В архиве'),
                  subtitle: const Text('Хранить карточку без напоминаний'),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _archived = v),
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
            key: const Key('save-purchase'),
            onPressed: _busy ? null : _save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}
