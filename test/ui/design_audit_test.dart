import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/purchases.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

const captureDirectory = String.fromEnvironment('UI_AUDIT_DIR');

Future<void> capture(WidgetTester tester, String name) async {
  if (captureDirectory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('audit-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(captureDirectory).create(recursive: true);
      await File('$captureDirectory/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final (label, size, scale) in [
    ('small', const Size(320, 568), 1.0),
    ('large_type', const Size(375, 812), 2.0),
    ('landscape', const Size(844, 390), 1.5),
    ('android_insets', const Size(390, 844), 1.0),
    ('android_landscape', const Size(844, 390), 1.5),
  ]) {
    for (var page = 0; page < 5; page++) {
      testWidgets('$label page $page remains usable with long data', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final db = LedgerDatabase(NativeDatabase.memory());
        final repo = FinanceRepository(db, clock: () => DateTime(2026, 11, 14));
        await repo.setCurrency('USD');
        await repo.saveAccount(
          name: 'Основная карта для повседневных покупок и накоплений',
          kind: 'Карта',
          openingMinor: 900000000000,
        );
        final id = (await repo.load()).accounts.single.id;
        await repo.saveEntry(
          kind: EntryKind.expense,
          amountMinor: 1234567890,
          date: DateTime(2026, 11, 14),
          accountId: id,
          category: 'Покупки для дома и повседневные хозяйственные расходы',
          note: 'Тестовая запись с длинным комментарием',
        );
        await repo.saveBudget(
          month: DateTime(2026, 11),
          category: 'Покупки для дома и повседневные хозяйственные расходы',
          limitMinor: 2000000000,
        );
        await repo.saveObligation(
          Obligation(
            id: 'qa-plan',
            name: 'Ежемесячная подписка с длинным названием для проверки',
            kind: EntryKind.expense,
            amountMinor: 12000,
            category: 'Подписки',
            anchor: DateTime(2026, 11, 20),
            repeat: RepeatRule.monthly,
          ),
        );
        await repo.savePurchase(
          Purchase(
            id: 'qa-purchase',
            name: 'Беспроводные наушники с длинным названием модели',
            date: DateTime(2026, 11, 14),
            amountMinor: 12000,
            warrantyUntil: DateTime(2027, 11, 14),
          ),
        );
        final vm = FinanceViewModel(repo)..month = DateTime(2026, 11);
        await vm.refresh();
        try {
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('audit-preview'),
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  padding: label == 'android_landscape'
                      ? const EdgeInsets.only(left: 48, right: 24, bottom: 24)
                      : label == 'android_insets'
                      ? const EdgeInsets.only(top: 24, bottom: 24)
                      : EdgeInsets.zero,
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: FinanceApp(viewModel: vm),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final errors = <Object>[];
          void collect() {
            Object? e;
            while ((e = tester.takeException()) != null) {
              errors.add(e!);
            }
          }

          collect();
          if (page > 0) {
            if (size.width >= 760) {
              await tester.scrollUntilVisible(
                find.byKey(Key('nav-$page')),
                100,
                scrollable: find
                    .descendant(
                      of: find.byKey(const Key('finance-navigation')),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
            } else {
              await tester.ensureVisible(find.byKey(Key('nav-$page')));
            }
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(Key('nav-$page')), warnIfMissed: true);
            await tester.pumpAndSettle();
            if (size.width >= 760) {
              expect(
                tester.widget<ListTile>(find.byKey(Key('nav-$page'))).selected,
                isTrue,
              );
            } else {
              expect(
                tester
                    .widget<NavigationBar>(find.byType(NavigationBar))
                    .selectedIndex,
                page,
              );
            }
            collect();
          }
          await capture(tester, '${label}_page_$page');
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          final scrollable = find
              .descendant(
                of: find.byKey(const Key('finance-content')),
                matching: find.byType(Scrollable),
              )
              .first;
          // Materialize the whole page, including category summaries and footer.
          for (var i = 0; i < 8; i++) {
            await tester.drag(scrollable, const Offset(0, -400));
            await tester.pumpAndSettle();
            collect();
          }
          await capture(tester, '${label}_page_${page}_bottom');
          expect(errors, isEmpty, reason: errors.join('\n'));
        } finally {
          semantics.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          vm.dispose();
          await db.close();
        }
      });
    }
  }
}
