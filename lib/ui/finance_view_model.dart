import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/finance_repository.dart';
import '../domain/ledger_math.dart';
import '../domain/money.dart';
import '../domain/models.dart';
import '../domain/budget_math.dart';
import '../data/backup_service.dart';
import '../data/reminders_service.dart';
import '../domain/schedule_math.dart';
import '../domain/purchase_deadlines.dart' as purchases_calendar;
import '../data/insights_preferences_repository.dart';
import 'insights/insights_view_model.dart';

class FinanceViewModel extends ChangeNotifier {
  FinanceViewModel(
    this.repository, {
    this.backup,
    this.reminders,
    this.cloudPreferences,
    InsightsPreferences? insightsPreferences,
  }) : insights = InsightsViewModel(preferences: insightsPreferences) {
    insights.addListener(_analysisChanged);
  }
  void _analysisChanged() {
    if (!_disposed) notifyListeners();
  }

  final InsightsViewModel insights;
  final FinanceRepository repository;
  final BackupService? backup;
  final File? cloudPreferences;
  final RemindersService? reminders;
  LedgerSnapshot? snapshot;
  bool loading = true;
  String? error;
  int _refreshGeneration = 0;
  bool _disposed = false;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  String query = '';
  EntryKind? filterKind;
  String? filterAccount;

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_refreshGeneration;
    bool current() => !_disposed && generation == _refreshGeneration;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final loaded = await repository.load();
      if (!current()) return;
      final currentBalances = accountBalances(loaded, through: today);
      final total = sumMoneyTotals(currentBalances.values);
      monthTotals(loaded.entries, month, through: today);
      forecast30Days(loaded, today).after(total);
      snapshot = loaded;
      final analysis = insights.update(loaded, month, today);
      if (loaded.entries.length < 1000) await analysis;
      if (!current()) return;
      notifyListeners();
      if (current() && reminders != null) await reminders!.synchronize(loaded);
    } catch (e) {
      if (current()) {
        error = e is DomainError ? e.message : 'Не удалось прочитать данные. Попробуйте ещё раз. База не изменена.';
      }
    } finally {
      if (current()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshGeneration++;
    insights.removeListener(_analysisChanged);
    insights.dispose();
    super.dispose();
  }

  LedgerSnapshot? _balanceSource;
  DateTime? _balanceDay;
  Map<String, int> _cachedBalances = const {};
  Map<String, int> get balances {
    final loaded = snapshot, date = today;
    if (loaded == null) return const {};
    if (!identical(loaded, _balanceSource) || date != _balanceDay) {
      _cachedBalances = Map.unmodifiable(
        accountBalances(loaded, through: date),
      );
      _balanceSource = loaded;
      _balanceDay = date;
    }
    return _cachedBalances;
  }

  int get totalBalance => sumMoneyTotals(balances.values);
  PeriodTotals get totals =>
      monthTotals(snapshot?.entries ?? [], month, through: today);
  String get currency => snapshot?.currency ?? '';
  DateTime get today => dayOnly(repository.clock());
  CashForecast get forecast => snapshot == null
      ? const CashForecast(0, 0, 0)
      : forecast30Days(snapshot!, today);
  List<PlannedOccurrence> get calendar => snapshot == null
      ? []
      : plannedBetween(
          snapshot!,
          month,
          DateTime(month.year, month.month + 1, 0),
        );
  List<BudgetProgress> get budgets => snapshot == null
      ? []
      : budgetProgress(
          snapshot!,
          month,
          through: today,
          canonical: insights.policy.profile.category,
        );
  List<purchases_calendar.PurchaseDeadline> get purchaseDeadlines =>
      purchases_calendar.purchaseDeadlines(snapshot?.purchases ?? [], month);

  List<LedgerEntry> get monthEntries =>
      (snapshot?.entries ?? <LedgerEntry>[])
          .where(
            (e) => e.date.year == month.year && e.date.month == month.month,
          )
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  List<LedgerEntry> get filteredEntries {
    final text = query.trim().toLowerCase();
    final accounts = {
      for (final a in snapshot?.accounts ?? <Account>[]) a.id: a.name,
    };
    return monthEntries.where((e) {
      if (filterKind != null && e.kind != filterKind) return false;
      if (filterAccount != null &&
          e.accountId != filterAccount &&
          e.targetAccountId != filterAccount) {
        return false;
      }
      return text.isEmpty ||
          '${e.category} ${e.note} ${e.kind.label} ${accounts[e.accountId]} ${accounts[e.targetAccountId] ?? ''}'
              .toLowerCase()
              .contains(text);
    }).toList()..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
  }

  void changeMonth(int offset) {
    final next = DateTime(month.year, month.month + offset);
    try {
      monthTotals(snapshot?.entries ?? [], next, through: today);
      month = next;
      error = null;
      if (snapshot != null) insights.update(snapshot!, month, today);
    } on DomainError catch (e) {
      error = e.message;
    }
    notifyListeners();
  }

  void setFilters({
    String? search,
    EntryKind? kind,
    String? account,
    bool clear = false,
  }) {
    if (search != null) query = search;
    if (clear) {
      query = '';
      filterKind = null;
      filterAccount = null;
    } else if (search == null) {
      filterKind = kind;
      filterAccount = account;
    }
    notifyListeners();
  }
}
