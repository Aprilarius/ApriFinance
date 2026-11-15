import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'money.dart';

Uint8List exportOperationsCsv(LedgerSnapshot snapshot) {
  String cell(String text) {
    // Spreadsheet programs can execute formulas even inside quoted CSV fields.
    if (RegExp(r'^\s*[=+\-@]').hasMatch(text)) text = "'$text";
    return '"${text.replaceAll('"', '""')}"';
  }

  final accounts = {for (final a in snapshot.accounts) a.id: a.name};
  final rows = <List<String>>[
    [
      'Дата',
      'Тип',
      'Сумма',
      'Валюта',
      'Счёт',
      'Счёт получателя',
      'Категория',
      'Комментарий',
    ],
    ...(snapshot.entries.toList()..sort((a, b) => a.date.compareTo(b.date)))
        .map(
          (e) => [
            calendarDate(e.date),
            e.kind.label,
            editableMoney(e.amountMinor),
            snapshot.currency ?? '',
            accounts[e.accountId] ?? '',
            accounts[e.targetAccountId] ?? '',
            e.category,
            e.note,
          ],
        ),
  ];
  return Uint8List.fromList(
    utf8.encode(
      '\uFEFF${rows.map((r) => r.map(cell).join(';')).join('\r\n')}\r\n',
    ),
  );
}
