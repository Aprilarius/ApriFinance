import 'purchases.dart';

enum EntryKind { expense, income, transfer, refund }

const supportedCurrencies = ['AZN', 'RUB', 'USD', 'EUR', 'TRY', 'GBP'];
const accountKinds = ['Карта', 'Наличные', 'Накопления', 'Другое'];

class CategoryBudget {
  const CategoryBudget({
    required this.id,
    required this.month,
    required this.category,
    required this.limitMinor,
    this.version = 1,
  });
  final String id;
  final String month;
  final String category;
  final int limitMinor;
  final int version;
}

extension EntryKindLabel on EntryKind {
  String get label => switch (this) {
    EntryKind.expense => 'Расход',
    EntryKind.income => 'Доход',
    EntryKind.transfer => 'Перевод',
    EntryKind.refund => 'Возврат',
  };
}

class Account {
  const Account({
    required this.id,
    required this.name,
    required this.kind,
    required this.openingMinor,
    this.archived = false,
    this.version = 1,
  });
  final String id;
  final String name;
  final String kind;
  final int openingMinor;
  final bool archived;
  final int version;
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.kind,
    required this.amountMinor,
    required this.date,
    required this.accountId,
    this.targetAccountId,
    this.category = '',
    this.note = '',
    this.refundOf,
    this.version = 1,
  });
  final String id;
  final EntryKind kind;
  final int amountMinor;
  final DateTime date;
  final String accountId;
  final String? targetAccountId;
  final String category;
  final String note;
  final String? refundOf;
  final int version;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'amountMinor': amountMinor,
    'date': calendarDate(date),
    'accountId': accountId,
    'targetAccountId': targetAccountId,
    'category': category,
    'note': note,
    'refundOf': refundOf,
    'version': version,
  };

  factory LedgerEntry.fromJson(Map<String, Object?> json) => LedgerEntry(
    id: json['id']! as String,
    kind: EntryKind.values.byName(json['kind']! as String),
    amountMinor: json['amountMinor']! as int,
    date: DateTime.parse(json['date']! as String),
    accountId: json['accountId']! as String,
    targetAccountId: json['targetAccountId'] as String?,
    category: json['category']! as String,
    note: json['note']! as String,
    refundOf: json['refundOf'] as String?,
    version: json['version']! as int,
  );
}

String calendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Civil dates are not elapsed 24-hour periods across daylight-saving changes.
int calendarDaysBetween(DateTime from, DateTime through) => DateTime.utc(
  through.year,
  through.month,
  through.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

class LedgerSnapshot {
  LedgerSnapshot({
    required Iterable<Account> accounts,
    required Iterable<LedgerEntry> entries,
    required this.currency,
    this.pendingChanges = 0,
    Iterable<CategoryBudget> budgets = const [],
    Iterable<Obligation> obligations = const [],
    Iterable<Settlement> settlements = const [],
    Iterable<Purchase> purchases = const [],
    Iterable<PurchaseDocument> documents = const [],
  }) : accounts = List.unmodifiable(accounts),
       entries = List.unmodifiable(entries),
       budgets = List.unmodifiable(budgets),
       obligations = List.unmodifiable(obligations),
       settlements = List.unmodifiable(settlements),
       purchases = List.unmodifiable(purchases),
       documents = List.unmodifiable(documents);
  final List<Account> accounts;
  final List<LedgerEntry> entries;
  final String? currency;
  final int pendingChanges;
  final List<CategoryBudget> budgets;
  final List<Obligation> obligations;
  final List<Settlement> settlements;
  final List<Purchase> purchases;
  final List<PurchaseDocument> documents;
}

enum RepeatRule { once, weekly, monthly, yearly }

extension RepeatRuleLabel on RepeatRule {
  String get label => switch (this) {
    RepeatRule.once => 'Один раз',
    RepeatRule.weekly => 'Каждую неделю',
    RepeatRule.monthly => 'Каждый месяц',
    RepeatRule.yearly => 'Каждый год',
  };
}

class Obligation {
  const Obligation({
    required this.id,
    required this.name,
    required this.kind,
    required this.amountMinor,
    required this.category,
    required this.anchor,
    required this.repeat,
    this.accountId,
    this.nextIndex = 0,
    this.paused = false,
    this.trialEnd,
    this.reminderDays = 3,
    this.manageUrl = '',
    this.version = 1,
  });
  final String id, name, category, manageUrl;
  final EntryKind kind;
  final int amountMinor, nextIndex, reminderDays, version;
  final DateTime anchor;
  final RepeatRule repeat;
  final String? accountId;
  final bool paused;
  final DateTime? trialEnd;
  bool get complete => repeat == RepeatRule.once && nextIndex > 0;
  bool get active => !paused && !complete;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'amountMinor': amountMinor,
    'category': category,
    'anchor': calendarDate(anchor),
    'repeat': repeat.name,
    'accountId': accountId,
    'nextIndex': nextIndex,
    'paused': paused,
    'trialEnd': trialEnd == null ? null : calendarDate(trialEnd!),
    'reminderDays': reminderDays,
    'manageUrl': manageUrl,
    'version': version,
  };
  factory Obligation.fromJson(Map<String, Object?> j) => Obligation(
    id: j['id']! as String,
    name: j['name']! as String,
    kind: EntryKind.values.byName(j['kind']! as String),
    amountMinor: j['amountMinor']! as int,
    category: j['category']! as String,
    anchor: parseCalendarDate(j['anchor']! as String),
    repeat: RepeatRule.values.byName(j['repeat']! as String),
    accountId: j['accountId'] as String?,
    nextIndex: j['nextIndex']! as int,
    paused: j['paused']! as bool,
    trialEnd: j['trialEnd'] == null
        ? null
        : parseCalendarDate(j['trialEnd']! as String),
    reminderDays: j['reminderDays']! as int,
    manageUrl: j['manageUrl']! as String,
    version: j['version']! as int,
  );
}

class Settlement {
  const Settlement({
    required this.id,
    required this.obligationId,
    required this.periodIndex,
    required this.dueDate,
    required this.entryId,
    required this.skipped,
    required this.version,
  });
  final String id, obligationId;
  final int periodIndex, version;
  final DateTime dueDate;
  final String? entryId;
  final bool skipped;
}

DateTime parseCalendarDate(String value) {
  final date = DateTime.parse(value);
  if (value != calendarDate(date)) {
    throw const FormatException('Неверная календарная дата');
  }
  return date;
}

class DomainError implements Exception {
  const DomainError(this.message);
  final String message;
  @override
  String toString() => message;
}
