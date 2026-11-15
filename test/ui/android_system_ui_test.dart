import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/app.dart';
import 'package:personal_finance/data/finance_repository.dart';
import 'package:personal_finance/data/ledger_database.dart';
import 'package:personal_finance/ui/finance_view_model.dart';

void main() {
  testWidgets('light Android system bars and safe areas remain explicit', (
    tester,
  ) async {
    final db = LedgerDatabase(NativeDatabase.memory());
    final repo = FinanceRepository(db);
    await repo.setCurrency('USD');
    final vm = FinanceViewModel(repo);
    await vm.refresh();
    try {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 24, bottom: 32),
            viewPadding: EdgeInsets.only(top: 24, bottom: 32),
          ),
          child: FinanceApp(viewModel: vm),
        ),
      );
      await tester.pumpAndSettle();
      final style = tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .value;
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(
        tester.getTopLeft(find.byKey(const Key('new-entry'))).dy,
        greaterThanOrEqualTo(24),
      );
      expect(
        tester.getCenter(find.byKey(const Key('nav-0'))).dy,
        lessThan(844 - 32),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      await db.close();
    }
  });
}
