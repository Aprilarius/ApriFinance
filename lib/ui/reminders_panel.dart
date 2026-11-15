import 'package:material_ui/material_ui.dart';

import 'finance_view_model.dart';
import 'dialogs.dart';

class RemindersPanel extends StatefulWidget {
  const RemindersPanel({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  State<RemindersPanel> createState() => _RemindersPanelState();
}

class _RemindersPanelState extends State<RemindersPanel> {
  bool _busy = false;
  Future<void> _configure(bool enabled, {int? hour}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.vm.reminders!.configure(
        widget.vm.snapshot!,
        turnOn: enabled,
        atHour: hour,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.vm.reminders;
    if (r == null) {
      return const Text(
        'Настройка уведомлений доступна в установленном приложении.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Напоминания на этом устройстве',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Включить уведомления'),
          value: r.enabled,
          onChanged: _busy || !r.backend.supported
              ? null
              : (v) => _configure(v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: r.hour,
          decoration: const InputDecoration(labelText: 'Время напоминания'),
          items: List.generate(
            24,
            (h) => DropdownMenuItem(
              value: h,
              child: Text('${h.toString().padLeft(2, '0')}:00'),
            ),
          ),
          onChanged: _busy || !r.backend.supported
              ? null
              : (v) => _configure(r.enabled, hour: v),
        ),
        const SizedBox(height: 12),
        Text(r.status),
        const SizedBox(height: 12),
        const Text(
          'Уведомления не содержат названий покупок и сумм. Время доставки зависит от ОС. Включайте их на тех устройствах, где хотите получать напоминания.',
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}
