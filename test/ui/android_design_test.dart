import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/ui/backup_panel.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/purchases_screen.dart';
import 'package:personal_finance/ui/theme.dart';

import 'budget_backup_test.dart' show FakeBackup, FakeFiles;
import 'design_audit_test.dart' show capture;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  late LedgerDatabase db;
  late FinanceViewModel vm;
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db);
    await repo.setCurrency('USD');
    await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
    vm = FinanceViewModel(repo, backup: FakeBackup(repo));
    await vm.refresh();
  });
  tearDown(() async {
    vm.dispose();
    await db.close();
  });

  testWidgets('switching mobile tabs resets scroll and releases search focus', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FinanceApp(viewModel: vm));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('finance-content'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    await tester.drag(scrollable, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    await tester.tap(find.byKey(const Key('nav-1')));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
    final search = find
        .descendant(of: list, matching: find.byType(TextField))
        .first;
    await tester.tap(search);
    await tester.pumpAndSettle();
    final input = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(input.focusNode.hasFocus, isTrue);
    await tester.tap(find.byKey(const Key('nav-2')));
    await tester.pumpAndSettle();
    expect(input.focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final kind in ['backup', 'documents']) {
    testWidgets(
      '$kind dialog keeps content reachable with Android large text',
      (tester) async {
        const size = Size(320, 568);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await vm.repository.savePurchase(
          Purchase(
            id: 'android-ui',
            name: 'Беспроводные наушники с очень длинным названием модели',
            date: DateTime(2026, 11, 14),
            amountMinor: 12000,
          ),
        );
        await vm.refresh();
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('audit-preview'),
            child: MaterialApp(
              theme: ledgerTheme(),
              debugShowCheckedModeBanner: false,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              supportedLocales: const [Locale('ru')],
              locale: const Locale('ru'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: size,
                  textScaler: TextScaler.linear(2),
                  viewInsets: EdgeInsets.only(
                    bottom: kind == 'backup' ? 240 : 0,
                  ),
                ),
                child: child!,
              ),
              home: kind == 'backup'
                  ? Scaffold(
                      body: SingleChildScrollView(
                        child: BackupPanel(vm: vm, files: FakeFiles()),
                      ),
                    )
                  : PurchasesScreen(vm: vm),
            ),
          ),
        );
        final open = kind == 'backup'
            ? find.byKey(const Key('create-backup'))
            : find.widgetWithText(OutlinedButton, 'Документы · 0');
        if (kind == 'documents') {
          await tester.scrollUntilVisible(
            open,
            240,
            scrollable: find.byType(Scrollable).first,
          );
        } else {
          await tester.ensureVisible(open);
        }
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scrollable = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first;
        expect(
          tester.state<ScrollableState>(scrollable).position.viewportDimension,
          greaterThan(40),
        );
        await capture(tester, 'android_${kind}_dialog');
        if (kind == 'backup') {
          await tester.ensureVisible(find.byKey(const Key('backup-confirm')));
          await tester.enterText(
            find.byKey(const Key('backup-confirm')),
            'test-password',
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.drag(scrollable, const Offset(0, -500));
        await tester.pumpAndSettle();
        await capture(tester, 'android_${kind}_dialog_scrolled');
        await tester.tap(find.text(kind == 'backup' ? 'Отмена' : 'Закрыть'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
