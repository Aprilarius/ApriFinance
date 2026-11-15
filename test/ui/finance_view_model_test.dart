import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

class DelayedLoads extends FinanceRepository {
  DelayedLoads(super.db);
  final loads = <Completer<LedgerSnapshot>>[];
  @override
  Future<LedgerSnapshot> load() {
    final request = Completer<LedgerSnapshot>();
    loads.add(request);
    return request.future;
  }
}

LedgerSnapshot snapshot(int balance) => LedgerSnapshot(
  accounts: [
    Account(id: 'qa', name: 'QA', kind: 'Карта', openingMinor: balance),
  ],
  entries: [],
  currency: 'USD',
);

void main() {
  late LedgerDatabase db;
  late DelayedLoads repo;
  setUp(() {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = DelayedLoads(db);
  });
  tearDown(() => db.close());

  test('late older refresh cannot overwrite newer ledger', () async {
    final vm = FinanceViewModel(repo);
    addTearDown(vm.dispose);
    final old = vm.refresh();
    final recent = vm.refresh();
    repo.loads[1].complete(snapshot(200));
    await recent;
    repo.loads[0].complete(snapshot(100));
    await old;
    expect(vm.totalBalance, 200);
    expect(vm.error, isNull);
    expect(vm.loading, isFalse);
  });

  test('older failure cannot hide successful newer refresh', () async {
    final vm = FinanceViewModel(repo);
    addTearDown(vm.dispose);
    final old = vm.refresh();
    final recent = vm.refresh();
    repo.loads[1].complete(snapshot(200));
    await recent;
    repo.loads[0].completeError(StateError('fictional stale read failure'));
    await old;
    expect(vm.error, isNull);
    expect(vm.totalBalance, 200);
  });

  test('completing load after disposal does not notify or throw', () async {
    final vm = FinanceViewModel(repo);
    var notifications = 0;
    vm.addListener(() => notifications++);
    final load = vm.refresh();
    final before = notifications;
    vm.dispose();
    repo.loads.single.complete(snapshot(100));
    await expectLater(load, completes);
    expect(notifications, before);
    expect(vm.snapshot, isNull);
  });
}
