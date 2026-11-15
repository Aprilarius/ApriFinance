import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:personal_finance/data/backup_service.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/ledger_math.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';

// Only an explicitly supplied, new fixture directory. Never uses path_provider
// or the real application's support directory. Contains fictional records.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Supply a new QA fixture directory');
  }
  final directory = Directory(args.single).absolute;
  if (await directory.exists()) {
    throw StateError('Fixture directory must be new');
  }
  await directory.create(recursive: true);
  final file = File('${directory.path}/finance.sqlite');
  final db = LedgerDatabase(NativeDatabase(file));
  final repo = FinanceRepository(db);
  try {
    await repo.setCurrency('USD');
    await repo.saveAccount(
      name: 'QA fictional',
      kind: 'Карта',
      openingMinor: 10000,
    );
    final account = (await repo.load()).accounts.single.id;
    final expense = await repo.saveEntry(
      kind: EntryKind.expense,
      amountMinor: 2500,
      date: DateTime(2026, 11, 14),
      accountId: account,
      category: 'Покупки',
    );
    await repo.saveEntry(
      kind: EntryKind.income,
      amountMinor: 1000,
      date: DateTime(2026, 11, 14),
      accountId: account,
      category: 'Другое',
    );
    await repo.savePurchase(
      Purchase(
        id: 'installer-qa-purchase',
        name: 'Fictional headphones',
        amountMinor: 2500,
        date: DateTime(2026, 11, 14),
        entryId: expense,
        warrantyUntil: DateTime(2027, 11, 14),
      ),
    );
    final pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.7\nfictional QA receipt\n%%EOF'),
    );
    await repo.addDocument('installer-qa-purchase', 'receipt.pdf', pdf);
    await File('${directory.path}/receipt.pdf').writeAsBytes(pdf, flush: true);
    final backup = BackupService(repo, Directory('${directory.path}/recovery'));
    const password = 'fictional-installer-qa-password';
    final encrypted = await backup.create(password);
    await File('${directory.path}/copy.mfin')
        .writeAsBytes(encrypted, flush: true);
    final restored = await backup.inspect(encrypted, password);
    if (restored.tables['entries']!.length != 2 ||
        accountBalances(await repo.load())[account] != 8500) {
      throw StateError('Invalid fictional fixture');
    }
  } finally {
    await db.close();
  }
  final reopened = LedgerDatabase(NativeDatabase(file));
  try {
    final state = await FinanceRepository(reopened).load();
    if (state.entries.length != 2 ||
        state.documents.length != 1 ||
        state.purchases.length != 1) {
      throw StateError('Fixture reopen failed');
    }
  } finally {
    await reopened.close();
  }
  stdout.writeln(
    'Fictional SQLite, receipt and encrypted backup created and verified.',
  );
}
