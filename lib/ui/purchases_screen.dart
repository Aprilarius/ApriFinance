import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../data/document_files.dart';
import '../data/finance_repository.dart';
import '../domain/purchases.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'dialogs.dart';
import 'finance_view_model.dart';
import 'form_dialog.dart';
import 'purchase_dialog.dart';
import 'theme.dart';

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    ) ??
    false;

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({
    super.key,
    required this.vm,
    this.files = const DeviceDocumentFiles(),
  });
  final FinanceViewModel vm;
  final DocumentFiles files;
  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _archive = false, _busy = false;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit([Purchase? purchase]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PurchaseDialog(vm: widget.vm, purchase: purchase),
    );
    if (changed == true) await widget.vm.refresh();
  }

  Future<void> _delete(Purchase p) async {
    if (!await _confirm(
      context,
      'Удалить покупку и документы?',
      'Связанный расход и баланс сохранятся. Вложения будут удалены.',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await widget.vm.repository.deletePurchase(p);
      await widget.vm.refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _deadline(String label, DateTime date) {
    final days = calendarDaysBetween(widget.vm.today, date);
    final status = days < 0
        ? 'срок прошёл'
        : days == 0
        ? 'сегодня'
        : 'осталось $days дн.';
    return '$label: ${DateFormat('dd.MM.yyyy').format(date)} · $status';
  }

  Widget _card(Purchase p) {
    final docs = widget.vm.snapshot!.documents
        .where((d) => d.purchaseId == p.id)
        .length;
    final next = [
      p.returnBy,
      p.warrantyUntil,
    ].nonNulls.where((d) => !d.isBefore(widget.vm.today)).toList()..sort();
    final urgent =
        !p.archived &&
        next.isNotEmpty &&
        calendarDaysBetween(widget.vm.today, next.first) <= 7;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LedgerColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            '${formatMoney(p.amountMinor, widget.vm.currency)} · ${DateFormat('dd.MM.yyyy').format(p.date)}',
          ),
          if (p.store.isNotEmpty)
            Text(p.store, style: const TextStyle(color: LedgerColors.muted)),
          const SizedBox(height: 12),
          Text(
            p.entryId == null
                ? 'Карточка без списания денег'
                : 'Связана с расходом · учтён один раз',
            style: const TextStyle(color: LedgerColors.muted),
          ),
          if (p.returnBy != null)
            Text(
              _deadline('Возврат до', p.returnBy!),
              style: TextStyle(
                color: urgent ? LedgerColors.expense : LedgerColors.ink,
              ),
            ),
          if (p.warrantyUntil != null)
            Text(_deadline('Гарантия до', p.warrantyUntil!)),
          if (p.serial.isNotEmpty) Text('Серийный номер: ${p.serial}'),
          if (p.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(p.note),
            ),
          if (p.archived)
            const Text(
              'В архиве · напоминания выключены',
              style: TextStyle(color: LedgerColors.muted),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: _busy || widget.vm.loading
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => _DocumentsDialog(
                          vm: widget.vm,
                          purchase: p,
                          files: widget.files,
                        ),
                      ),
                icon: const Icon(Icons.attach_file),
                label: Text('Документы · $docs'),
              ),
              TextButton(
                onPressed: _busy || widget.vm.loading ? null : () => _edit(p),
                child: const Text('Изменить'),
              ),
              IconButton(
                tooltip: 'Удалить покупку',
                onPressed: _busy || widget.vm.loading ? null : () => _delete(p),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.vm,
    builder: (context, _) {
      final items = widget.vm.snapshot!.purchases
          .where(
            (p) =>
                p.archived == _archive &&
                '${p.name} ${p.store} ${p.serial} ${p.note}'
                    .toLowerCase()
                    .contains(_query.trim().toLowerCase()),
          )
          .toList();
      DateTime next(Purchase p) {
        final dates = [
          p.returnBy,
          p.warrantyUntil,
        ].nonNulls.where((d) => !d.isBefore(widget.vm.today)).toList()..sort();
        return dates.firstOrNull ?? DateTime(2200);
      }

      items.sort((a, b) {
        final c = next(a).compareTo(next(b));
        return c == 0 ? b.date.compareTo(a.date) : c;
      });
      final children = <Widget>[
        Wrap(
          spacing: 20,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Покупки и гарантии',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Чеки рядом, сроки под рукой',
                  style: TextStyle(color: LedgerColors.muted),
                ),
              ],
            ),
            FilledButton.icon(
              key: const Key('new-purchase'),
              onPressed: _busy || widget.vm.loading ? null : _edit,
              icon: const Icon(Icons.add),
              label: const Text('Добавить покупку'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('purchase-search'),
          controller: _search,
          decoration: InputDecoration(
            labelText: 'Поиск покупок',
            hintText: 'Название, магазин, номер',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Очистить поиск',
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                    }),
                    icon: const Icon(Icons.close),
                  ),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Активные'),
              selected: !_archive,
              onSelected: (_) => setState(() => _archive = false),
            ),
            ChoiceChip(
              label: const Text('Архив'),
              selected: _archive,
              onSelected: (_) => setState(() => _archive = true),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_busy || widget.vm.loading) const LinearProgressIndicator(),
        if (widget.vm.error != null)
          Text(
            widget.vm.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (items.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text(
              _query.trim().isNotEmpty
                  ? 'Ничего не найдено. Измените запрос или проверьте другой список.'
                  : _archive
                  ? 'Архив пуст. Здесь появятся покупки, перенесённые в архив.'
                  : 'Активных покупок пока нет. Добавьте карточку и сохраните чек.',
            ),
          ),
        ...items.map(_card),
        const SizedBox(height: 32),
      ];
      return Scaffold(
        appBar: AppBar(title: const Text('ApriFinance')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView.builder(
                padding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width >= 760 ? 32 : 16,
                ),
                itemCount: children.length,
                itemBuilder: (_, i) => children[i],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _DocumentsDialog extends StatefulWidget {
  const _DocumentsDialog({
    required this.vm,
    required this.purchase,
    required this.files,
  });
  final FinanceViewModel vm;
  final Purchase purchase;
  final DocumentFiles files;
  @override
  State<_DocumentsDialog> createState() => _DocumentsDialogState();
}

class _DocumentsDialogState extends State<_DocumentsDialog> {
  bool _busy = false;
  String? _message;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = userError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() => _run(() async {
    final file = await widget.files.pick();
    if (file == null) return;
    await widget.vm.repository.addDocument(
      widget.purchase.id,
      file.name,
      file.bytes,
    );
    await widget.vm.refresh();
  });
  Future<void> _save(PurchaseDocument d) => _run(() async {
    final bytes = await widget.vm.repository.readDocument(d);
    // Always suggest a safe extension even for old/imported display names.
    final name = 'Документ-${d.id}.${documentExtension(d.mime)}';
    final saved = await widget.files.save(bytes, name);
    if (mounted) {
      setState(
        () => _message = saved ? 'Документ сохранён' : 'Сохранение отменено',
      );
    }
  });
  Future<void> _view(PurchaseDocument d) => _run(() async {
    final bytes = await widget.vm.repository.readDocument(d);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(d.name),
        content: SizedBox(
          width: 680,
          height: 480,
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4,
            child: Image.memory(
              bytes,
              cacheWidth: 1600,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Center(
                child: Text(
                  'Изображение не удалось прочитать. Можно сохранить оригинал.',
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  });
  Future<void> _delete(PurchaseDocument d) async {
    if (!await _confirm(
      context,
      'Удалить документ?',
      'Сохраните оригинал, если он ещё нужен.',
    )) {
      return;
    }
    await _run(() async {
      await widget.vm.repository.deleteDocument(d);
      await widget.vm.refresh();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.vm,
    builder: (context, _) {
      final docs = widget.vm.snapshot!.documents
          .where((d) => d.purchaseId == widget.purchase.id)
          .toList();
      return PopScope(
        canPop: !_busy,
        child: LedgerFormDialog(
          title: const Text('Документы'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.purchase.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'JPEG, PNG или PDF до 2 МБ. Всего до 8 МБ в базе. Вложения входят в защищённую резервную копию.',
                ),
                const SizedBox(height: 16),
                if (docs.isEmpty)
                  const Text(
                    'Добавьте чек, гарантийный талон или условия возврата.',
                  ),
                ...docs.map(
                  (d) => Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${(d.size / 1024).ceil()} КБ · ${d.mime == 'application/pdf' ? 'PDF · сохраните для просмотра' : 'Изображение'}',
                        ),
                        Wrap(
                          children: [
                            if (d.mime != 'application/pdf')
                              TextButton(
                                onPressed: _busy ? null : () => _view(d),
                                child: const Text('Просмотр'),
                              ),
                            TextButton(
                              onPressed: _busy ? null : () => _save(d),
                              child: const Text('Сохранить файл'),
                            ),
                            IconButton(
                              tooltip: 'Удалить документ',
                              onPressed: _busy ? null : () => _delete(d),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (_message != null) Text(_message!),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
            FilledButton.icon(
              key: const Key('add-document'),
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.attach_file),
              label: const Text('Добавить'),
            ),
          ],
        ),
      );
    },
  );
}
