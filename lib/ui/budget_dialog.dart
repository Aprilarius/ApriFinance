import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/finance_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'dialogs.dart';
import 'finance_view_model.dart';
import 'form_dialog.dart';

class BudgetDialog extends StatefulWidget {
  const BudgetDialog({super.key, required this.vm, this.budget});
  final FinanceViewModel vm;
  final CategoryBudget? budget;
  @override
  State<BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<BudgetDialog> {
  final _form = GlobalKey<FormState>();
  late final _category = TextEditingController(
    text: widget.budget?.category ?? '',
  );
  late final _amount = TextEditingController(
    text: widget.budget == null ? '' : editableMoney(widget.budget!.limitMinor),
  );
  late final _month = widget.vm.month;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _category.dispose();
    _amount.dispose();
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
      await widget.vm.repository.saveBudget(
        id: widget.budget?.id,
        expectedVersion: widget.budget?.version,
        month: _month,
        category: _category.text,
        limitMinor: parseMoney(_amount.text),
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
      title: Text(widget.budget == null ? 'Лимит категории' : 'Изменить лимит'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(DateFormat('LLLL yyyy', 'ru').format(_month)),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('budget-category'),
                controller: _category,
                enabled: !_saving,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Категория'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Укажите категорию' : null,
              ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children:
                    {
                          ...widget.vm.totals.byCategory.keys,
                          ...expenseCategories.take(5),
                        }
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
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('budget-amount'),
                controller: _amount,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Лимит на месяц',
                  suffixText: widget.vm.currency,
                ),
                validator: (v) {
                  try {
                    return parseMoney(v ?? '') > 0
                        ? null
                        : 'Лимит должен быть больше нуля';
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Лимит действует только в выбранном месяце. Возвраты уменьшают расход; переводы не учитываются.',
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
          key: const Key('save-budget'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Сохраняем…' : 'Сохранить'),
        ),
      ],
    ),
  );
}
