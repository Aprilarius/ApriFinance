import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/data/document_files.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/ui/finance_view_model.dart';
import 'package:personal_finance/ui/purchases_screen.dart';
import 'package:personal_finance/ui/theme.dart';

class FakeFiles implements DocumentFiles {
  final bytes = Uint8List.fromList(
    utf8.encode('%PDF-1.7\nfictional receipt\n%%EOF'),
  );
  Uint8List? saved;
  @override
  Future<PickedDocument?> pick() async => PickedDocument('Чек.pdf', bytes);
  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saved = bytes;
    return true;
  }
}

void main() {
  late LedgerDatabase db;
  late FinanceRepository repo;
  late FinanceViewModel vm;
  late FakeFiles files;
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    db = LedgerDatabase(NativeDatabase.memory());
    repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
    await repo.setCurrency('USD');
    vm = FinanceViewModel(repo);
    await vm.refresh();
    files = FakeFiles();
  });
  tearDown(() async {
    vm.dispose();
    await db.close();
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
    home: PurchasesScreen(vm: vm, files: files),
  );
  Future<void> wait(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'search and archive distinguish empty results and allow clearing query',
    (tester) async {
      await repo.savePurchase(
        Purchase(
          id: 'qa-search',
          name: 'Наушники',
          date: DateTime(2026, 11, 14),
          amountMinor: 3000,
        ),
      );
      await vm.refresh();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('purchase-search')),
        'неизвестный товар',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Ничего не найдено'), findsOneWidget);
      expect(find.textContaining('Активных покупок пока нет'), findsNothing);
      await tester.tap(find.byTooltip('Очистить поиск'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('purchase-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('Наушники'), findsOneWidget);
      await tester.tap(find.text('Архив'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Архив пуст'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('purchase form validates and creates card with no expense', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('new-purchase')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('purchase-name')), 'Наушники');
    await tester.enterText(find.byKey(const Key('purchase-amount')), '0');
    await tester.tap(find.byKey(const Key('save-purchase')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Проверьте название, стоимость и описание покупки'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.text('Проверьте название, стоимость и описание покупки'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('purchase-amount')));
    await tester.enterText(find.byKey(const Key('purchase-amount')), '30');
    await tester.tap(find.byKey(const Key('save-purchase')));
    await wait(tester);
    expect(vm.snapshot!.purchases.single.amountMinor, 3000);
    expect(vm.snapshot!.entries, isEmpty);
    expect(find.text('Наушники'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit new expense mode creates one expense with the purchase',
    (tester) async {
      await repo.saveAccount(name: 'Карта', kind: 'Карта', openingMinor: 10000);
      await vm.refresh();
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.tap(find.byKey(const Key('new-purchase')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('purchase-name')),
        'Наушники',
      );
      await tester.tap(find.byKey(const Key('purchase-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Связать с расходом').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('purchase-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать новый расход').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('purchase-amount')), '30');
      await tester.tap(find.byKey(const Key('save-purchase')));
      await wait(tester);
      expect(vm.totalBalance, 7000);
      expect(vm.snapshot!.entries.length, 1);
      expect(
        vm.snapshot!.purchases.single.entryId,
        vm.snapshot!.entries.single.id,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('documents add, save and delete preserve purchase', (
    tester,
  ) async {
    await repo.savePurchase(
      Purchase(id: 'p', name: 'Наушники', date: vm.today, amountMinor: 3000),
    );
    await vm.refresh();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.tap(find.text('Документы · 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-document')));
    await wait(tester);
    expect(vm.snapshot!.documents.single.name, 'Чек.pdf');
    await tester.tap(find.text('Сохранить файл'));
    await wait(tester);
    expect(files.saved, files.bytes);
    await tester.tap(find.byTooltip('Удалить документ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await wait(tester);
    expect(vm.snapshot!.documents, isEmpty);
    expect(vm.snapshot!.purchases.length, 1);
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, scale) in [
    ('purchases_desktop', const Size(1100, 900), 1.0),
    ('purchases_phone', const Size(390, 844), 1.5),
  ]) {
    testWidgets('$name layout', (tester) async {
      await repo.savePurchase(
        Purchase(
          id: 'p',
          name: 'Наушники',
          date: vm.today,
          amountMinor: 3000,
          store: 'Магазин техники',
          returnBy: DateTime(2026, 11, 21),
          warrantyUntil: DateTime(2027, 11, 14),
        ),
      );
      await vm.refresh();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(scale: scale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/$name.png'),
      );
      if (name == 'purchases_phone') {
        await tester.tap(find.byKey(const Key('new-purchase')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('../goldens/purchase_form_phone.png'),
        );
      }
    });
  }
}
