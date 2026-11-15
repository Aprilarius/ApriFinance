import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../domain/models.dart';
import '../domain/money.dart';
import 'dialogs.dart';
import 'finance_view_model.dart';
import 'theme.dart';
import 'money_text.dart';
import 'budget_dialog.dart';
import 'backup_panel.dart';
import 'payment_dialogs.dart';
import 'payments_content.dart';
import 'reminders_panel.dart';
import 'purchases_screen.dart';
import 'purchase_dialog.dart';
import '../domain/purchases.dart';
import 'cloud_controller.dart';
import 'cloud_screen.dart';
import 'cloud_status_banner.dart';
import '../data/finance_repository.dart';
import 'insights/insights_screen.dart';

class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key, required this.vm});
  final FinanceViewModel vm;
  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen>
    with WidgetsBindingObserver {
  int _page = 0;
  CloudController? _cloud;
  bool _cloudReady = false;
  String? _currency;
  bool _savingCurrency = false;
  final _search = TextEditingController();
  final _contentScroll = ScrollController();
  FinanceViewModel get vm => widget.vm;
  static const _titles = ['Обзор', 'Операции', 'Счета', 'Платежи', 'Настройки'];
  static const _compactTitles = ['Обзор', 'Журнал', 'Счета', 'Сроки', 'Ещё'];
  static const _icons = [
    Icons.space_dashboard_outlined,
    Icons.receipt_long_outlined,
    Icons.account_balance_wallet_outlined,
    Icons.event_note_outlined,
    Icons.tune,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (vm.backup != null) {
      _cloud = CloudController(
        vm,
        preferences: vm.cloudPreferences,
        credentials: vm.cloudCredentials,
      );
      _cloud!.initialize().then((_) {
        if (mounted) setState(() => _cloudReady = true);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _cloud?.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed && !vm.loading) vm.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    _contentScroll.dispose();
    _cloud?.dispose();
    super.dispose();
  }

  void _selectPage(int page) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_contentScroll.hasClients) _contentScroll.jumpTo(0);
    setState(() => _page = page);
  }

  Future<void> _payment([Obligation? obligation]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ObligationDialog(vm: vm, obligation: obligation),
    );
    if (changed == true) await vm.refresh();
  }

  Future<void> _purchase(Purchase purchase) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PurchaseDialog(vm: vm, purchase: purchase),
    );
    if (changed == true) await vm.refresh();
  }

  Future<void> _openCloud() async {
    if (!_cloudReady || _cloud == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => CloudScreen(controller: _cloud!)),
    );
  }

  Future<void> _pay(Obligation o) async {
    if (!vm.snapshot!.accounts.any((a) => !a.archived)) await _account();
    if (!mounted || !vm.snapshot!.accounts.any((a) => !a.archived)) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SettleDialog(vm: vm, obligation: o),
    );
    if (changed == true) await vm.refresh();
  }

  Future<bool> _confirmPaymentAction(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Подтвердить'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _paymentAction(Obligation o, String action) async {
    if (action == 'skip' &&
        !await _confirmPaymentAction(
          'Пропустить период?',
          'Срок будет перенесён на следующий период без изменения денег.',
        )) {
      return;
    }
    try {
      if (action == 'skip') {
        await vm.repository.settleObligation(
          o.id,
          expectedVersion: o.version,
          periodIndex: o.nextIndex,
          paidOn: vm.today,
          skip: true,
        );
      } else {
        await vm.repository.saveObligation(
          Obligation.fromJson({...o.toJson(), 'paused': !o.paused}),
          expectedVersion: o.version,
        );
      }
      await vm.refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userError(e))));
      }
    }
  }

  Future<void> _undoSettlement(Settlement s) async {
    if (!await _confirmPaymentAction(
      'Отменить подтверждение?',
      'Связанная операция будет удалена, а период снова станет ожидающим.',
    )) {
      return;
    }
    try {
      await vm.repository.undoSettlement(s);
      await vm.refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userError(e))));
      }
    }
  }

  Future<void> _account([Account? account]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AccountDialog(vm: vm, account: account),
    );
    if (changed == true) await vm.refresh();
  }

  Future<void> _budget([CategoryBudget? budget]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BudgetDialog(vm: vm, budget: budget),
    );
    if (changed == true) await vm.refresh();
  }

  Future<void> _deleteBudget(CategoryBudget budget) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить лимит?'),
        content: Text('Операции категории «${budget.category}» сохранятся.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await vm.repository.deleteBudget(budget);
      await vm.refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userError(e))));
      }
    }
  }

  Future<void> _entry([LedgerEntry? entry]) async {
    if (!vm.snapshot!.accounts.any((a) => !a.archived)) {
      await _account();
      if (!mounted || !vm.snapshot!.accounts.any((a) => !a.archived)) return;
    }
    if (!mounted) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EntryDialog(vm: vm, entry: entry),
    );
    if (changed == true) await vm.refresh();
  }

  Future<void> _delete(LedgerEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить операцию?'),
        content: const Text(
          'Баланс и отчёты будут пересчитаны. Это действие нельзя отменить.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await vm.repository.deleteEntry(entry);
      await vm.refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(userError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vm,
    builder: (context, _) {
      if (vm.snapshot == null && vm.loading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (vm.error != null) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 16),
                  Text(vm.error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: vm.refresh,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      if (vm.snapshot!.currency == null) return _onboarding(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  if (wide) _sidebar(context),
                  Expanded(
                    child: Column(
                      children: [
                        if (_cloud != null)
                          CloudStatusBanner(
                            controller: _cloud!,
                            onOpen: _openCloud,
                          ),
                        if (vm.loading)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1280),
                              child: _content(context, wide),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _page,
                    onDestinationSelected: _selectPage,
                    destinations: List.generate(
                      5,
                      (i) => NavigationDestination(
                        key: Key('nav-$i'),
                        icon: Icon(_icons[i]),
                        label:
                            constraints.maxWidth < 360 ||
                                (constraints.maxWidth < 450 &&
                                    MediaQuery.textScalerOf(context).scale(14) >
                                        18)
                            ? _compactTitles[i]
                            : _titles[i],
                        tooltip: _titles[i],
                      ),
                    ),
                  ),
          );
        },
      );
    },
  );

  Widget _content(BuildContext context, bool wide) {
    final children = <Widget>[
      _header(context, wide),
      const SizedBox(height: 28),
      if (_page == 0) ..._overview(context),
      if (_page == 1) ..._journal(context),
      if (_page == 2) ..._accounts(context),
      if (_page == 3) ...[
        OutlinedButton.icon(
          key: const Key('open-purchases'),
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => PurchasesScreen(vm: vm)),
          ),
          icon: const Icon(Icons.inventory_2_outlined),
          label: const Text('Покупки и гарантии'),
        ),
        const SizedBox(height: 20),
        _monthPicker(),
        const SizedBox(height: 20),
        ...paymentsContent(
          context,
          vm,
          edit: _payment,
          pay: _pay,
          action: _paymentAction,
          undo: _undoSettlement,
          editPurchase: _purchase,
        ),
      ],
      if (_page == 4) ..._settings(context),
      const SizedBox(height: 48),
    ];
    return ListView.builder(
      key: const Key('finance-content'),
      controller: _contentScroll,
      padding: EdgeInsets.all(wide ? 32 : 16),
      itemCount: children.length,
      itemBuilder: (_, index) => children[index],
    );
  }

  Widget _sidebar(BuildContext context) => Container(
    width:
        212 + (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(0, 1) * 120,
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: LedgerColors.line)),
    ),
    padding: const EdgeInsets.fromLTRB(16, 32, 16, 20),
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Icon(
              Icons.account_balance_wallet_outlined,
              size: 30,
              color: LedgerColors.green,
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'ApriFinance',
              style: MediaQuery.textScalerOf(context).scale(1) > 1.3
                  ? Theme.of(context).textTheme.titleLarge
                  : Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 40),
          Expanded(
            child: ListView(
              key: const Key('finance-navigation'),
              primary: false,
              padding: EdgeInsets.zero,
              children: List.generate(
                5,
                (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    key: Key('nav-$i'),
                    selected: _page == i,
                    selectedTileColor: const Color(0xFFE5EDE3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    leading: Icon(_icons[i], size: 21),
                    title: Text(_titles[i]),
                    onTap: () => _selectPage(i),
                  ),
                ),
              ),
            ),
          ),
          if (constraints.maxHeight > 650)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Личный журнал\nДанные на устройстве',
                style: TextStyle(color: LedgerColors.muted, height: 1.6),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _header(BuildContext context, bool wide) => Wrap(
    spacing: 20,
    runSpacing: 16,
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _titles[_page],
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(switch (_page) {
            0 => 'Деньги под контролем',
            1 => 'Каждое поступление и списание',
            2 => 'Где находятся ваши деньги',
            3 => 'Сроки, подписки и ожидаемые поступления',
            _ => 'Ваш личный учёт',
          }, style: const TextStyle(color: LedgerColors.muted)),
        ],
      ),
      if (_page < 4)
        FilledButton.icon(
          key: Key(
            _page == 2
                ? 'new-account'
                : _page == 3
                ? 'new-payment'
                : 'new-entry',
          ),
          onPressed: vm.loading
              ? null
              : () => _page == 2
                    ? _account()
                    : _page == 3
                    ? _payment()
                    : _entry(),
          icon: const Icon(Icons.add, size: 20),
          label: Text(
            _page == 2
                ? 'Добавить счёт'
                : _page == 3
                ? 'Добавить платёж'
                : 'Добавить операцию',
          ),
        ),
    ],
  );

  Widget _monthPicker() => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      IconButton(
        tooltip: 'Предыдущий месяц',
        onPressed: () => vm.changeMonth(-1),
        icon: const Icon(Icons.chevron_left),
      ),
      Text(
        DateFormat('LLLL yyyy', 'ru').format(vm.month),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      IconButton(
        tooltip: 'Следующий месяц',
        onPressed: () => vm.changeMonth(1),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  List<Widget> _overview(BuildContext context) => [
    _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Общий баланс',
            style: TextStyle(color: LedgerColors.muted),
          ),
          const SizedBox(height: 8),
          MoneyText(
            formatMoney(vm.totalBalance, vm.currency),
            key: const Key('total-balance'),
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Остаток по всем счетам · на сегодня',
            style: TextStyle(color: LedgerColors.muted),
          ),
          const Divider(height: 36),
          _monthPicker(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 40,
            runSpacing: 24,
            children: [
              _metric('Пришло', vm.totals.income, LedgerColors.green),
              _metric('Ушло', vm.totals.expense, LedgerColors.expense),
              _metric('Разница', vm.totals.net, LedgerColors.ink),
            ],
          ),
        ],
      ),
    ),
    if (vm.snapshot!.obligations.any((o) => o.active) ||
        vm.forecast.income != 0 ||
        vm.forecast.expense != 0) ...[
      const SizedBox(height: 20),
      _surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Прогноз на 30 дней',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              formatMoney(vm.forecast.after(vm.totalBalance), vm.currency),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Известные поступления: ${formatMoney(vm.forecast.income, vm.currency)}\n'
              'Известные расходы: ${formatMoney(vm.forecast.expense, vm.currency)}\n'
              'Из них просрочено: ${formatMoney(vm.forecast.overdueExpense, vm.currency)}',
              style: const TextStyle(height: 1.6),
            ),
            const SizedBox(height: 8),
            const Text(
              'Остаток по будущим операциям и введённым планам. Возвраты включены в поступления, просроченные расходы учтены.',
            ),
            TextButton(
              onPressed: () => _selectPage(3),
              child: const Text('Открыть платежи'),
            ),
          ],
        ),
      ),
    ],
    const SizedBox(height: 28),
    _surface(child: InsightsPreview(vm: vm)),
    const SizedBox(height: 28),
    _sectionHeading(
      context,
      'Мои счета',
      action: TextButton(
        onPressed: () => _selectPage(2),
        child: const Text('Все счета'),
      ),
    ),
    const SizedBox(height: 12),
    if (vm.snapshot!.accounts.where((a) => !a.archived).isEmpty)
      _empty(
        'Добавьте первый счёт',
        'Укажите наличные или карту и остаток денег до начала учёта.',
        action: OutlinedButton.icon(
          onPressed: _account,
          icon: const Icon(Icons.add),
          label: const Text('Создать счёт'),
        ),
      )
    else
      ..._accountTiles(context, onlyActive: true),
    const SizedBox(height: 28),
    ..._budgets(context),
    const SizedBox(height: 28),
    _sectionHeading(context, 'Расходы по категориям'),
    const SizedBox(height: 12),
    _categories(),
    const SizedBox(height: 28),
    _sectionHeading(
      context,
      'Последние операции',
      action: TextButton(
        onPressed: () => setState(() => _page = 1),
        child: const Text('Весь журнал'),
      ),
    ),
    const SizedBox(height: 12),
    ..._entryTiles(context, vm.monthEntries.take(6).toList()),
  ];

  Widget _metric(String label, int amount, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: LedgerColors.muted)),
      const SizedBox(height: 6),
      Text(
        formatMoney(amount, vm.currency),
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ],
  );

  Widget _categories() {
    final sorted =
        vm.totals.byCategory.entries.where((e) => e.value != 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.isEmpty) {
      return _empty(
        'За этот месяц расходов пока нет',
        'Добавьте расход — здесь появится разбивка по категориям.',
      );
    }
    final max = sorted
        .map((e) => e.value.abs())
        .fold(1, (a, b) => a > b ? a : b);
    return _surface(
      child: Column(
        children: sorted
            .map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final amount = MoneyText(
                          formatMoney(e.value, vm.currency),
                        );
                        if (constraints.maxWidth /
                                MediaQuery.textScalerOf(context).scale(1) <
                            400) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(e.key),
                              const SizedBox(height: 8),
                              amount,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: Text(e.key)),
                            const SizedBox(width: 16),
                            Flexible(child: amount),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: e.value.abs() / max,
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(3),
                      backgroundColor: const Color(0xFFEBF0E8),
                      color: LedgerColors.green,
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  List<Widget> _journal(BuildContext context) => [
    _monthPicker(),
    const SizedBox(height: 16),
    TextField(
      controller: _search,
      onChanged: (v) => vm.setFilters(search: v),
      decoration: const InputDecoration(
        labelText: 'Поиск по категории, счёту или комментарию',
        prefixIcon: Icon(Icons.search),
      ),
    ),
    const SizedBox(height: 12),
    LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) <
            480;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: stacked ? constraints.maxWidth : 200,
              child: DropdownButtonFormField<EntryKind?>(
                key: ValueKey('kind-${vm.filterKind}'),
                initialValue: vm.filterKind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Тип'),
                items: [
                  const DropdownMenuItem<EntryKind?>(
                    value: null,
                    child: Text('Все операции'),
                  ),
                  ...EntryKind.values.map(
                    (k) => DropdownMenuItem<EntryKind?>(
                      value: k,
                      child: Text(k.label),
                    ),
                  ),
                ],
                onChanged: (v) =>
                    vm.setFilters(kind: v, account: vm.filterAccount),
              ),
            ),
            SizedBox(
              width: stacked ? constraints.maxWidth : 220,
              child: DropdownButtonFormField<String?>(
                key: ValueKey('account-${vm.filterAccount}'),
                initialValue: vm.filterAccount,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Счёт'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Все счета'),
                  ),
                  ...vm.snapshot!.accounts.map(
                    (a) => DropdownMenuItem<String?>(
                      value: a.id,
                      child: Text(a.name, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (v) =>
                    vm.setFilters(kind: vm.filterKind, account: v),
              ),
            ),
            TextButton(
              onPressed: () {
                _search.clear();
                vm.setFilters(clear: true);
              },
              child: const Text('Сбросить фильтры'),
            ),
          ],
        );
      },
    ),
    const SizedBox(height: 24),
    Text(
      'Операций: ${vm.filteredEntries.length}',
      style: const TextStyle(color: LedgerColors.muted),
    ),
    const SizedBox(height: 12),
    ..._entryTiles(context, vm.filteredEntries),
  ];

  List<Widget> _accounts(BuildContext context) => [
    ..._accountTiles(context),
    if (vm.snapshot!.accounts.isEmpty)
      _empty(
        'Здесь будут ваши счета',
        'Начните с карты или наличных. Баланс будет меняться после каждой операции.',
      ),
    const SizedBox(height: 20),
    const Text(
      'Начальные остатки не входят в доходы. Переводы между своими счетами не увеличивают расходы.',
      style: TextStyle(color: LedgerColors.muted, height: 1.5),
    ),
  ];

  List<Widget> _accountTiles(BuildContext context, {bool onlyActive = false}) =>
      vm.snapshot!.accounts
          .where((a) => !onlyActive || !a.archived)
          .map(
            (a) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _surface(
                padding: 4,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEBF0E8),
                    child: Icon(
                      a.kind == 'Наличные'
                          ? Icons.payments_outlined
                          : Icons.credit_card,
                      color: LedgerColors.green,
                    ),
                  ),
                  title: Text(
                    a.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${a.kind}${a.archived ? ' · В архиве' : ''}'),
                      const SizedBox(height: 6),
                      Text(
                        formatMoney(vm.balances[a.id]!, vm.currency),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: LedgerColors.ink,
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    tooltip: 'Изменить счёт',
                    onPressed: () => _account(a),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                  onTap: () => _account(a),
                ),
              ),
            ),
          )
          .toList();

  List<Widget> _entryTiles(BuildContext context, List<LedgerEntry> entries) {
    if (entries.isEmpty) {
      return [
        _empty(
          'Операции не найдены',
          'Добавьте операцию или выберите другой период и фильтры.',
        ),
      ];
    }
    final accounts = {for (final a in vm.snapshot!.accounts) a.id: a.name};
    return entries.map((e) {
      final color = e.kind == EntryKind.expense
          ? LedgerColors.expense
          : e.kind == EntryKind.transfer
          ? LedgerColors.muted
          : LedgerColors.green;
      final prefix = e.kind == EntryKind.expense
          ? '−'
          : e.kind == EntryKind.transfer
          ? ''
          : '+';
      final title = e.kind == EntryKind.transfer
          ? 'Перевод между счетами'
          : e.kind == EntryKind.refund
          ? 'Возврат · ${e.category}'
          : e.category;
      final route =
          '${accounts[e.accountId]}${e.targetAccountId == null ? '' : ' → ${accounts[e.targetAccountId]}'}';
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _surface(
          padding: 0,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _entry(e),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Row(
                children: [
                  Icon(
                    switch (e.kind) {
                      EntryKind.expense => Icons.north_east,
                      EntryKind.income => Icons.south_west,
                      EntryKind.transfer => Icons.swap_horiz,
                      EntryKind.refund => Icons.undo,
                    },
                    color: color,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${DateFormat('dd.MM.yyyy').format(e.date)} · $route',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (e.note.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              e.note,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: LedgerColors.muted),
                            ),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          '$prefix${formatMoney(e.amountMinor, vm.currency)}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Действия с операцией',
                    onSelected: (action) =>
                        action == 'edit' ? _entry(e) : _delete(e),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Изменить')),
                      PopupMenuItem(value: 'delete', child: Text('Удалить')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  List<Widget> _budgets(BuildContext context) => [
    _sectionHeading(
      context,
      'Лимиты на месяц',
      action: TextButton(
        key: const Key('new-budget'),
        onPressed: () => _budget(),
        child: const Text('Добавить лимит'),
      ),
    ),
    const SizedBox(height: 12),
    if (vm.budgets.isEmpty)
      _empty(
        'Задайте бюджет для категории',
        'Например, ограничьте расходы на кафе. Лимиты относятся к месяцу, выбранному выше.',
      )
    else
      ...vm.budgets.map((progress) {
        final budget = progress.budget;
        final color = progress.exceeded
            ? LedgerColors.expense
            : progress.nearLimit
            ? const Color(0xFF916500)
            : LedgerColors.green;
        final status = progress.exceeded
            ? 'Превышение: ${formatMoney(-progress.remainingMinor, vm.currency)}'
            : 'Осталось: ${formatMoney(progress.remainingMinor, vm.currency)}';
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        budget.category,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Действия с лимитом',
                      onSelected: (v) =>
                          v == 'edit' ? _budget(budget) : _deleteBudget(budget),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Изменить')),
                        PopupMenuItem(value: 'delete', child: Text('Удалить')),
                      ],
                    ),
                  ],
                ),
                Text(
                  '${formatMoney(progress.spentMinor, vm.currency)} из ${formatMoney(budget.limitMinor, vm.currency)}',
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: progress.fraction,
                  minHeight: 6,
                  color: color,
                  backgroundColor: const Color(0xFFEBF0E8),
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 10),
                Text(
                  status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (progress.nearLimit)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('Потрачено не меньше 80% лимита'),
                  ),
              ],
            ),
          ),
        );
      }),
  ];

  List<Widget> _settings(BuildContext context) => [
    _surface(child: RemindersPanel(vm: vm)),
    const SizedBox(height: 20),
    _surface(child: BackupPanel(vm: vm)),
    const SizedBox(height: 20),
    _surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Локальное хранение',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Данные сохраняются на этом устройстве. Учёт работает без интернета.',
          ),
          const Divider(height: 32),
          Text('Валюта учёта: ${vm.currency}'),
          const SizedBox(height: 8),
          const Text(
            'В этой версии валюта едина для всех счетов. После начала учёта она не меняется.',
          ),
          const Divider(height: 32),
          Text('Синхронизация', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            'Зашифрованный обмен через личный Supabase. Автоматический режим включается отдельно на текущую сессию.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('open-cloud'),
            onPressed: !_cloudReady || _cloud == null ? null : _openCloud,
            icon: const Icon(Icons.cloud_sync_outlined),
            label: const Text('Открыть облачный обмен'),
          ),
          if (_cloud != null)
            ListenableBuilder(
              listenable: _cloud!,
              builder: (_, _) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_cloud!.status),
              ),
            ),
          const Divider(height: 32),
          const Text(
            'Версия 1.0 · Учёт, покупки и сроки',
            style: TextStyle(color: LedgerColors.muted),
          ),
          const SizedBox(height: 8),
          const Text('Чеки и гарантийные сроки: Платежи → Покупки и гарантии.'),
        ],
      ),
    ),
  ];

  Widget _onboarding(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 52,
                  color: LedgerColors.green,
                ),
                const SizedBox(height: 28),
                Text(
                  'Ваши деньги.\nПонятная картина.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Доходы, расходы и остатки по счетам в одном месте. Начнём с валюты учёта.',
                  style: TextStyle(fontSize: 16, height: 1.5),
                ),
                const SizedBox(height: 28),
                DropdownButtonFormField<String>(
                  key: const Key('currency-picker'),
                  initialValue: _currency,
                  decoration: const InputDecoration(labelText: 'Валюта'),
                  items: supportedCurrencies
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: _savingCurrency
                      ? null
                      : (v) => setState(() => _currency = v),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Выберите валюту для всех счетов. После добавления счетов изменить её будет нельзя.',
                  style: TextStyle(color: LedgerColors.muted, height: 1.5),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _currency == null || _savingCurrency
                      ? null
                      : () async {
                          setState(() => _savingCurrency = true);
                          try {
                            await vm.repository.setCurrency(_currency!);
                            await vm.refresh();
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(userError(e))),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _savingCurrency = false);
                            }
                          }
                        },
                  child: Text(_savingCurrency ? 'Подготовка…' : 'Начать учёт'),
                ),
                if (vm.backup != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextButton(
                      onPressed: _savingCurrency
                          ? null
                          : () => openRestoreDialog(context, vm),
                      child: const Text('Восстановить из копии'),
                    ),
                  ),
                const SizedBox(height: 20),
                const Text(
                  'Без регистрации · Данные на устройстве',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: LedgerColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _sectionHeading(
    BuildContext context,
    String title, {
    Widget? action,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final heading = Text(
        title,
        style: Theme.of(context).textTheme.titleLarge,
      );
      if (action != null &&
          constraints.maxWidth / MediaQuery.textScalerOf(context).scale(1) <
              400) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [heading, const SizedBox(height: 8), action],
        );
      }
      return Row(
        children: [
          Expanded(child: heading),
          ?action,
        ],
      );
    },
  );

  Widget _surface({required Widget child, double padding = 20}) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: LedgerColors.line),
    ),
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );

  Widget _empty(String title, String detail, {Widget? action}) => _surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          style: const TextStyle(color: LedgerColors.muted, height: 1.5),
        ),
        if (action != null) ...[const SizedBox(height: 16), action],
      ],
    ),
  );
}
