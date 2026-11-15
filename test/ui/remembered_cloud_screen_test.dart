import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/ui/cloud_controller.dart';
import 'package:personal_finance/ui/cloud_screen.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/theme.dart';

import '../support/fast_sync_backup.dart';
import '../support/remembered_cloud.dart';

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late FinanceViewModel vm;
  late CloudController controller;
  late MemoryCredentials store;
  late RememberedCloud cloud;
  late Directory dir;
  CloudController create() => CloudController(
    vm,
    credentials: store,
    transport: cloud,
    configuredCloud: fixtureCloudConfig(),
    schedule: (_, _) => () {},
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('apri-simple-ui-');
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 15));
    await repo.setCurrency('AZN');
    await repo.saveAccount(
      name: 'Тестовый счёт',
      kind: 'Карта',
      openingMinor: 0,
    );
    vm = FinanceViewModel(repo, backup: FastSyncBackup(repo, dir));
    await vm.refresh();
    store = MemoryCredentials();
    cloud = RememberedCloud();
    controller = create();
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    vm.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });
  Widget app({
    double scale = 1,
    double keyboard = 0,
    String identity = 'first',
  }) => MaterialApp(
    theme: ledgerTheme(),
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        viewInsets: EdgeInsets.only(bottom: keyboard),
      ),
      child: child!,
    ),
    home: CloudScreen(key: ValueKey(identity), controller: controller),
  );
  Future<void> wait(WidgetTester t) async {
    for (var i = 0; i < 300 && controller.busy; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 10));
    }
    expect(controller.busy, isFalse, reason: controller.status);
    await t.pumpAndSettle();
  }

  testWidgets(
    'built-in connection asks only for login and remembers the first copy unlock',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app());
      expect(find.byKey(const Key('cloud-url')), findsNothing);
      expect(find.byKey(const Key('cloud-key')), findsNothing);
      await t.enterText(
        find.byKey(const Key('cloud-email')),
        'owner@example.invalid',
      );
      await t.enterText(
        find.byKey(const Key('cloud-login-password')),
        'fictional-account-password',
      );
      await t.tap(find.byKey(const Key('cloud-login')));
      await wait(t);
      expect(controller.signedIn, isTrue);
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-password')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await t.enterText(
        find.byKey(const Key('cloud-password')),
        'fictional-copy-password',
      );
      await t.enterText(
        find.byKey(const Key('cloud-repeat')),
        'fictional-copy-password',
      );
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-check')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const Key('cloud-check')));
      await wait(t);
      expect(controller.hasSavedCopy, isTrue);
      expect(cloud.revision, 1);
      controller.dispose();
      controller = create();
      await t.runAsync(controller.initialize);
      await t.pumpWidget(app(identity: 'reopened'));
      await t.pumpAndSettle();
      expect(controller.signedIn, isTrue);
      expect(find.byKey(const Key('cloud-password')), findsNothing);
      expect(find.byKey(const Key('cloud-login')), findsNothing);
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-sync-now')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('cloud-sync-now')), findsOneWidget);
      expect(cloud.logins, 1);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'logout clears an unsubmitted copy password before another login',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app());
      await t.enterText(
        find.byKey(const Key('cloud-email')),
        'owner@example.invalid',
      );
      await t.enterText(
        find.byKey(const Key('cloud-login-password')),
        'fictional-account-password',
      );
      await t.tap(find.byKey(const Key('cloud-login')));
      await wait(t);
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-password')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await t.enterText(
        find.byKey(const Key('cloud-password')),
        'unsubmitted-copy-password',
      );
      await t.enterText(
        find.byKey(const Key('cloud-repeat')),
        'unsubmitted-copy-password',
      );
      final logout = find.text('Выйти и забыть подключение');
      await t.scrollUntilVisible(
        logout,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(logout);
      await wait(t);
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-email')),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        t
            .widget<TextField>(find.byKey(const Key('cloud-email')))
            .controller!
            .text,
        isEmpty,
      );
      await t.enterText(
        find.byKey(const Key('cloud-email')),
        'second@example.invalid',
      );
      await t.enterText(
        find.byKey(const Key('cloud-login-password')),
        'fictional-account-password',
      );
      await t.tap(find.byKey(const Key('cloud-login')));
      await wait(t);
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-password')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        t
            .widget<TextField>(find.byKey(const Key('cloud-password')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        t
            .widget<TextField>(find.byKey(const Key('cloud-repeat')))
            .controller!
            .text,
        isEmpty,
      );
      expect(cloud.writes, 0);
    },
  );

  testWidgets(
    'small phone and enlarged text keep login reachable above a keyboard',
    (t) async {
      await t.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app(scale: 2, keyboard: 240));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.byKey(const Key('cloud-login')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byKey(const Key('cloud-url')), findsNothing);
    },
  );
  testWidgets(
    'technical settings are optional and can be expanded deliberately',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app());
      await t.tap(find.byKey(const Key('cloud-advanced')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('cloud-url')), findsOneWidget);
      expect(find.byKey(const Key('cloud-key')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
