import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'ui/finance_screen.dart';
import 'ui/finance_view_model.dart';
import 'ui/theme.dart';

class FinanceApp extends StatelessWidget {
  const FinanceApp({super.key, required this.viewModel});
  final FinanceViewModel viewModel;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ApriFinance',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ledgerTheme(),
    builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: LedgerColors.paper,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: child!,
    ),
    home: FinanceScreen(vm: viewModel),
  );
}
