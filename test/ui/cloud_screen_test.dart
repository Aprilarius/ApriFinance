import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/backup_data.dart';
import 'package:personal_finance/ui/cloud_controller.dart';
import 'package:personal_finance/ui/cloud_screen.dart';
import 'package:personal_finance/ui/cloud_status_banner.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/theme.dart';

import '../support/fast_sync_backup.dart';

class UiCloud implements CloudTransport {
  String? payload;
  int revision = 0, reads = 0;
  @override
  Future<CloudReply> request(
    Uri uri,
    String method,
    Map<String, String> headers,
    Object? body,
  ) async {
    if (uri.path == '/auth/v1/token') {
      return const CloudReply(200, {
        'access_token': 'fictional-token',
        'user': {'id': '12345678-1234-1234-1234-123456789abc'},
      });
    }
    if (method == 'GET') {
      reads++;
      return CloudReply(
        200,
        payload == null
            ? <Object?>[]
            : [
                {'revision': revision, 'payload': payload},
              ],
      );
    }
    if (uri.path == '/rest/v1/rpc/put_finance_snapshot_v2') {
      final request = body! as Map;
      if (request['expected_revision'] != revision) {
        return const CloudReply(400, {'message': 'SYNC_CONFLICT'});
      }
      payload = request['encrypted_payload']! as String;
      return CloudReply(200, ++revision);
    }
    return const CloudReply(204, null);
  }
}

void main() {
  late Directory directory;
  late LedgerDatabase db;
  late FinanceRepository repo;
  late FinanceViewModel vm;
  late CloudController controller;
  late UiCloud server;
  const password = 'fictional-cloud-password';
  const key = 'sb_publishable_fictional_key_123456';
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cloud-ui-');
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    vm = FinanceViewModel(
      repo,
      backup: FastSyncBackup(repo, Directory('${directory.path}/recovery')),
    );
    await vm.refresh();
    server = UiCloud();
    controller = CloudController(
      vm,
      preferences: File('${directory.path}/cloud.json'),
      transport: server,
      schedule: (_, _) => () {},
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    vm.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });
  Widget app({double scale = 1}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ledgerTheme(),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ru')],
    locale: const Locale('ru'),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: CloudScreen(controller: controller),
  );
  Future<void> wait(WidgetTester tester) async {
    for (var i = 0; i < 200 && controller.busy; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(controller.busy, isFalse, reason: controller.status);
    await tester.pumpAndSettle();
  }

  Future<void> login() => controller.signIn(
    'https://project.supabase.co',
    key,
    'owner@example.invalid',
    'fictional-account-password',
  );

  testWidgets(
    'login, password validation, preview and commit; preferences contain no session or password',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.tap(find.byKey(const Key('cloud-advanced')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cloud-url')),
        'https://project.supabase.co',
      );
      await tester.enterText(find.byKey(const Key('cloud-key')), key);
      await tester.enterText(
        find.byKey(const Key('cloud-email')),
        'owner@example.invalid',
      );
      await tester.enterText(
        find.byKey(const Key('cloud-login-password')),
        'fictional-account-password',
      );
      await tester.ensureVisible(find.byKey(const Key('cloud-login')));
      await tester.tap(find.byKey(const Key('cloud-login')));
      await wait(tester);
      expect(controller.signedIn, isTrue);
      final preferences = await tester.runAsync(
        () => File('${directory.path}/cloud.json').readAsString(),
      );
      expect(preferences, isNot(contains('fictional-token')));
      expect(preferences, isNot(contains('fictional-account-password')));
      await tester.enterText(find.byKey(const Key('cloud-password')), password);
      await tester.enterText(find.byKey(const Key('cloud-repeat')), 'wrong');
      await tester.ensureVisible(find.byKey(const Key('cloud-check')));
      await tester.tap(find.byKey(const Key('cloud-check')));
      await tester.pumpAndSettle();
      expect(server.reads, 0);
      ScaffoldMessenger.of(tester.element(find.byKey(const Key('cloud-check'))))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cloud-repeat')), password);
      await tester.tap(find.byKey(const Key('cloud-check')));
      await wait(tester);
      expect(controller.preview!.needsChoice, isFalse);
      await tester.ensureVisible(find.byKey(const Key('cloud-commit')));
      await tester.tap(find.byKey(const Key('cloud-commit')));
      await wait(tester);
      expect(server.revision, 1);
      expect((await repo.load()).pendingChanges, 0);
      expect(controller.lastSuccess, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> conflict() async {
    await login();
    await controller.check(password);
    await controller.commit();
    final before = (await repo.exportData()).toJson();
    final remote = (jsonDecode(jsonEncode(before)) as Map<String, dynamic>)
        .cast<String, Object?>();
    final row = (((remote['tables'] as Map)['accounts'] as List).single as Map);
    row['name'] = 'Карта Mac';
    row['version'] = 2;
    server.payload = utf8.decode(
      await vm.backup!.encode(BackupData.fromJson(remote), password),
    );
    server.revision = 2;
    final account = (await repo.load()).accounts.single;
    await repo.saveAccount(
      id: account.id,
      expectedVersion: 1,
      name: 'Личная карта',
      kind: account.kind,
      openingMinor: account.openingMinor,
    );
    await controller.check(password);
  }

  testWidgets(
    'conflict shows differences and replacement requires checkbox; losing data recoverable',
    (tester) async {
      await tester.runAsync(conflict);
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('cloud-choose-remote')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('cloud-choose-remote')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('На устройстве: Личная карта'),
        findsOneWidget,
      );
      expect(find.textContaining('В облаке: Карта Mac'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cloud-replace-check')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cloud-choose-remote')));
      await wait(tester);
      expect((await repo.load()).accounts.single.name, 'Карта Mac');
      final recovery = await tester.runAsync(
        () async =>
            vm.backup!.inspect((await vm.backup!.latestRecovery())!, password),
      );
      expect(recovery!.tables['accounts']!.single['name'], 'Личная карта');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new conflict preview requires a fresh replacement acknowledgement',
    (tester) async {
      await tester.runAsync(conflict);
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('cloud-replace-check')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('cloud-replace-check')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('cloud-replace-check')),
            )
            .value,
        isTrue,
      );
      await tester.runAsync(() => controller.check(password));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('cloud-replace-check')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('cloud-choose-remote')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic switch requires manual success then retains session when leaving preview',
    (tester) async {
      await tester.runAsync(login);
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cloud-auto')));
      await tester.tap(find.byKey(const Key('cloud-auto')));
      await tester.pumpAndSettle();
      expect(controller.automaticEnabled, isTrue);
      expect(controller.automaticReady, isFalse);
      await tester.enterText(find.byKey(const Key('cloud-password')), password);
      await tester.enterText(find.byKey(const Key('cloud-repeat')), password);
      await tester.ensureVisible(find.byKey(const Key('cloud-check')));
      await tester.tap(find.byKey(const Key('cloud-check')));
      await wait(tester);
      await tester.ensureVisible(find.byKey(const Key('cloud-commit')));
      await tester.tap(find.byKey(const Key('cloud-commit')));
      await wait(tester);
      expect(controller.automaticReady, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(controller.automaticReady, isTrue);
    },
  );

  testWidgets(
    'blocked automatic exchange shows actionable banner with large text',
    (tester) async {
      await tester.runAsync(() async {
        await login();
        controller.setAutomatic(true);
        await controller.check(password);
        await controller.commit();
        server.payload = 'corrupt-copy';
        server.revision++;
        await controller.exchangeAutomatically();
      });
      var opened = false;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ledgerTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: CloudStatusBanner(
                controller: controller,
                onOpen: () => opened = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('resolve-cloud-attention')), findsOneWidget);
      await tester.tap(find.byKey(const Key('resolve-cloud-attention')));
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('automatic controls fit a phone with enlarged text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await login();
      controller.setAutomatic(true);
      await controller.check(password);
      await controller.commit();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(scale: 1.5));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('cloud-auto')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/cloud_auto_phone.png'),
    );
  });

  for (final (name, size, scale) in [
    ('cloud_desktop', const Size(1100, 1000), 1.0),
    ('cloud_phone', const Size(390, 844), 1.5),
  ]) {
    testWidgets('$name layout', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(scale: scale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/$name.png'),
      );
      if (name == 'cloud_phone') {
        await tester.runAsync(conflict);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('cloud-replace-check')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('../goldens/cloud_conflict_phone.png'),
        );
      }
    });
  }
}
