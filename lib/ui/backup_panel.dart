import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../data/backup_service.dart';

import '../data/backup_files.dart';
import '../domain/backup_data.dart';
import '../domain/csv_export.dart';
import 'dialogs.dart';
import 'finance_view_model.dart';
import 'form_dialog.dart';

Future<void> openRestoreDialog(
  BuildContext context,
  FinanceViewModel vm, {
  BackupFiles files = const DeviceBackupFiles(),
}) async {
  try {
    final bytes = await files.open();
    if (bytes == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BackupDialog(vm: vm, files: files, restoreBytes: bytes),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(userError(e))));
    }
  }
}

class BackupPanel extends StatefulWidget {
  const BackupPanel({
    super.key,
    required this.vm,
    this.files = const DeviceBackupFiles(),
  });
  final FinanceViewModel vm;
  final BackupFiles files;
  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> {
  bool _busy = false;
  Future<void> _export({bool recovery = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = recovery
          ? await widget.vm.backup!.latestRecovery()
          : exportOperationsCsv(widget.vm.snapshot!);
      if (!mounted) return;
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Защитных копий пока нет: они создаются перед восстановлением',
            ),
          ),
        );
        return;
      }
      final saved = await widget.files.save(
        bytes,
        recovery ? 'finances-before-restore.mfin' : 'finances-operations.csv',
      );
      if (saved && recovery) await widget.vm.insights.confirmBackupExport();
      if (saved && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Файл сохранён')));
      }
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Резервные копии', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      const Text(
        'Сохраните зашифрованный файл с паролем. Он содержит финансовые данные, цели, долги и сохранённые в базе настройки анализа. Без пароля открыть копию нельзя.',
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            key: const Key('create-backup'),
            icon: const Icon(Icons.lock_outline),
            onPressed: _busy || widget.vm.backup == null
                ? null
                : () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) =>
                        _BackupDialog(vm: widget.vm, files: widget.files),
                  ),
            label: const Text('Создать копию'),
          ),
          OutlinedButton.icon(
            key: const Key('restore-backup'),
            icon: const Icon(Icons.restore),
            onPressed: _busy || widget.vm.backup == null
                ? null
                : () => openRestoreDialog(
                    context,
                    widget.vm,
                    files: widget.files,
                  ),
            label: const Text('Восстановить'),
          ),
          OutlinedButton.icon(
            key: const Key('export-csv'),
            icon: const Icon(Icons.table_view_outlined),
            onPressed: _busy ? null : () => _export(),
            label: const Text('Операции в CSV'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        'CSV предназначен для просмотра в таблицах. Для восстановления нужен файл .mfin.',
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy || widget.vm.backup == null
            ? null
            : () => _export(recovery: true),
        child: const Text('Сохранить последнюю защитную копию'),
      ),
      TextButton.icon(
        key: const Key('recovery-history'),
        icon: const Icon(Icons.history),
        onPressed: _busy || widget.vm.backup == null
            ? null
            : () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => _RecoveryDialog(
                  service: widget.vm.backup!,
                  files: widget.files,
                ),
              ),
        label: const Text('Все защитные копии'),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(),
        ),
    ],
  );
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({required this.service, required this.files});
  final BackupService service;
  final BackupFiles files;
  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  List<RecoveryCopy> _copies = const [];
  bool _busy = true;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _copies = await widget.service.recoveryCopies();
    } catch (e) {
      _message = userError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(RecoveryCopy copy) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await widget.service.readRecovery(copy.name);
      final saved = await widget.files.save(bytes, copy.name);
      _message = saved
          ? 'Копия сохранена. Для восстановления откройте её через «Восстановить».'
          : 'Сохранение отменено';
    } catch (e) {
      _message = userError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Защитные копии'),
      content: SizedBox(
        width: 560,
        height: 400,
        child: ListView.builder(
          itemCount: _copies.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Создаются перед восстановлением и заменой версий при обмене. Для открытия нужен пароль, действовавший при создании копии.',
                  ),
                  const SizedBox(height: 12),
                  if (_busy) const LinearProgressIndicator(),
                  if (_message != null) Text(_message!),
                  if (!_busy && _copies.isEmpty)
                    const Text('Защитных копий пока нет.'),
                ],
              );
            }
            final copy = _copies[i - 1];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                DateFormat('dd.MM.yyyy HH:mm:ss.SSS')
                    .format(copy.modified.toLocal()),
              ),
              subtitle: Text('${(copy.size / 1024).ceil()} КБ'),
              trailing: IconButton(
                key: Key('export-recovery-${i - 1}'),
                tooltip: 'Сохранить копию',
                onPressed: _busy ? null : () => _save(copy),
                icon: const Icon(Icons.download_outlined),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({
    required this.vm,
    required this.files,
    this.restoreBytes,
  });
  final FinanceViewModel vm;
  final BackupFiles files;
  final Uint8List? restoreBytes;
  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _accepted = false;
  String? _error;
  BackupData? _preview;
  bool get _restore => widget.restoreBytes != null;
  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _act() async {
    if (_busy) return;
    final password = _password.text;
    if (!_restore &&
        (password.length < 10 ||
            password.length > 256 ||
            password != _confirm.text)) {
      setState(
        () => _error =
            'Пароль: от 10 до 256 символов. Повтор пароля должен совпадать.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = widget.vm.backup!;
      if (_restore && _preview == null) {
        final preview = await service.inspect(widget.restoreBytes!, password);
        if (mounted) setState(() => _preview = preview);
      } else if (_restore) {
        if (!_accepted) return;
        await service.restore(_preview!, password);
        await widget.vm.refresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Данные восстановлены. Защитная копия доступна в настройках.',
              ),
            ),
          );
          Navigator.pop(context);
        }
      } else {
        final bytes = await service.create(password);
        final name =
            'finances-${DateTime.now().toIso8601String().replaceAll(':', '-')}.mfin';
        final saved = await widget.files.save(bytes, name);
        if (saved) await widget.vm.insights.confirmBackupExport();
        if (saved && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Зашифрованная копия сохранена')),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = userError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: LedgerFormDialog(
      title: Text(_restore ? 'Восстановить копию' : 'Создать копию'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_preview == null) ...[
              Text(
                _restore ? 'Введите пароль выбранного файла.' : 'Придумайте отдельный пароль и сохраните его. Восстановить забытый пароль нельзя.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('backup-password'),
                controller: _password,
                obscureText: true,
                enabled: !_busy,
                maxLength: 256,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Пароль'),
              ),
              if (!_restore)
                TextField(
                  key: const Key('backup-confirm'),
                  controller: _confirm,
                  obscureText: true,
                  enabled: !_busy,
                  maxLength: 256,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Повтор пароля'),
                ),
            ] else ...[
              Text(
                'Валюта: ${_preview!.currency ?? 'не выбрана'}\nСчетов: ${_preview!.accountCount}\nОпераций: ${_preview!.entryCount}\nЛимитов: ${_preview!.budgetCount}\nПлатежей: ${_preview!.obligationCount}\nПокупок: ${_preview!.purchaseCount}\nДокументов: ${_preview!.documentCount}',
                style: const TextStyle(height: 1.8),
              ),
              const SizedBox(height: 16),
              const Text(
                'Текущие данные будут заменены данными из файла. Перед заменой приложение сохранит их в защитную копию с тем же паролем. Её можно выгрузить из настроек.',
              ),
              CheckboxListTile(
                key: const Key('restore-confirmation'),
                value: _accepted,
                contentPadding: EdgeInsets.zero,
                title: const Text('Подтверждаю замену текущих данных'),
                onChanged: _busy ? null : (v) => setState(() => _accepted = v!),
              ),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
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
          key: const Key('backup-action'),
          onPressed: _busy || (_preview != null && !_accepted) ? null : _act,
          child: Text(
            _busy
                ? 'Обработка…'
                : _restore
                ? _preview == null
                      ? 'Проверить копию'
                      : 'Заменить данные'
                : 'Сохранить файл',
          ),
        ),
      ],
    ),
  );
}
