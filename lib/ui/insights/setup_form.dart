import 'package:material_ui/material_ui.dart';

import '../../domain/models.dart';
import '../../domain/money.dart';
import '../form_dialog.dart';

enum SetupFieldType { text, money, integer, date, choice, toggle }

class SetupField {
  const SetupField(
    this.key,
    this.label, {
    this.type = SetupFieldType.text,
    this.optional = false,
    this.minimum = 0,
    this.maximum = 900000000000000,
    this.choices = const {},
  });
  final String key, label;
  final SetupFieldType type;
  final bool optional;
  final int minimum, maximum;
  final Map<String, String> choices;
}

class SetupForm extends StatefulWidget {
  const SetupForm({
    super.key,
    required this.title,
    required this.fields,
    required this.initial,
    required this.save,
    required this.errorText,
    this.help = '',
  });
  final String title, help;
  final List<SetupField> fields;
  final Map<String, Object?> initial;
  final Future<bool> Function(Map<String, Object?> values) save;
  final String? Function() errorText;
  @override
  State<SetupForm> createState() => _SetupFormState();
}

class _SetupFormState extends State<SetupForm> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers = {
    for (final f in widget.fields.where(
      (f) => f.type != SetupFieldType.toggle && f.type != SetupFieldType.choice,
    ))
      f.key: TextEditingController(
        text: widget.initial[f.key] == null
            ? ''
            : f.type == SetupFieldType.money
            ? editableMoney(widget.initial[f.key]! as int)
            : '${widget.initial[f.key]}',
      ),
  };
  late final _values = Map<String, Object?>.from(widget.initial);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    for (final f in widget.fields) {
      final text = _controllers[f.key]?.text.trim() ?? '';
      if (f.type == SetupFieldType.toggle || f.type == SetupFieldType.choice) {
        continue;
      }
      _values[f.key] = text.isEmpty && f.optional
          ? (f.type == SetupFieldType.text ? '' : null)
          : switch (f.type) {
              SetupFieldType.money => parseMoney(text),
              SetupFieldType.integer => int.parse(text),
              _ => text,
            };
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.save(Map<String, Object?>.from(_values));
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(
          () => _error =
              widget.errorText() ?? 'Не удалось сохранить. Повторите попытку.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Проверьте поля и повторите сохранение.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: LedgerFormDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.help.isNotEmpty) ...[
                Text(widget.help),
                const SizedBox(height: 12),
              ],
              for (final field in widget.fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _field(field),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
          key: const Key('save-analysis-data'),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Сохранение…' : 'Сохранить'),
        ),
      ],
    ),
  );
  Widget _field(SetupField f) {
    if (f.type == SetupFieldType.toggle) {
      return CheckboxListTile(
        key: Key('analysis-field-${f.key}'),
        contentPadding: EdgeInsets.zero,
        title: Text(f.label),
        value: (_values[f.key] as bool?) ?? false,
        onChanged: _busy
            ? null
            : (value) => setState(() => _values[f.key] = value ?? false),
      );
    }
    if (f.type == SetupFieldType.choice) {
      return DropdownButtonFormField<String>(
        key: Key('analysis-field-${f.key}'),
        initialValue: f.choices.containsKey(_values[f.key])
            ? _values[f.key] as String
            : null,
        isExpanded: true,
        itemHeight: null,
        menuMaxHeight: MediaQuery.sizeOf(context).height * .5,
        decoration: InputDecoration(labelText: f.label),
        items: [
          for (final e in f.choices.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(
                e.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _busy ? null : (value) => _values[f.key] = value,
        validator: (value) => value == null && !f.optional
            ? 'Выберите значение; при необходимости сначала создайте исходную запись'
            : null,
      );
    }
    return TextFormField(
      key: Key('analysis-field-${f.key}'),
      controller: _controllers[f.key],
      enabled: !_busy,
      maxLength: f.type == SetupFieldType.text ? 100 : null,
      keyboardType: f.type == SetupFieldType.money
          ? const TextInputType.numberWithOptions(decimal: true)
          : f.type == SetupFieldType.integer
          ? TextInputType.number
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: f.label,
        hintText: f.type == SetupFieldType.date ? 'ГГГГ-ММ-ДД' : null,
        suffixIcon: f.type != SetupFieldType.date
            ? null
            : IconButton(
                tooltip: 'Выбрать дату',
                onPressed: _busy
                    ? null
                    : () async {
                        final parsed = DateTime.tryParse(
                              _controllers[f.key]!.text,
                            ),
                            initial =
                                parsed != null &&
                                    parsed.year >= 2000 &&
                                    parsed.year <= 2100
                                ? parsed
                                : DateTime.now();
                        final date = await showDatePicker(
                          context: context,
                          initialDate: initial,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100, 12, 31),
                        );
                        if (date != null && mounted) {
                          _controllers[f.key]!.text = calendarDate(date);
                        }
                      },
                icon: const Icon(Icons.calendar_today),
              ),
      ),
      validator: (value) {
        final text = (value ?? '').trim();
        if (text.isEmpty) return f.optional ? null : 'Заполните поле';
        try {
          if (f.type == SetupFieldType.money ||
              f.type == SetupFieldType.integer) {
            final amount = f.type == SetupFieldType.money
                ? parseMoney(text)
                : int.parse(text);
            if (amount < f.minimum || amount > f.maximum) {
              return 'Значение вне допустимого диапазона';
            }
          }
          if (f.type == SetupFieldType.date) {
            final date = parseCalendarDate(text);
            if (date.year < 2000 || date.year > 2100) {
              return 'Год должен быть от 2000 до 2100';
            }
          }
        } catch (_) {
          return f.type == SetupFieldType.date
              ? 'Введите дату ГГГГ-ММ-ДД'
              : 'Введите корректное число';
        }
        return null;
      },
    );
  }
}
