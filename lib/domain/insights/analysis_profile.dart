import '../models.dart';
import '../money.dart';
import 'series_review.dart';

String normalizedLabel(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String profileText(Object? value, {int max = 100, bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty)) {
    throw const FormatException('Проверьте текстовые поля анализа');
  }
  return value.trim();
}

int profileInt(Object? value, {int min = 0, int max = maxMoneyMinor}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Проверьте числовые поля анализа');
  }
  return value;
}

DateTime profileDate(Object? value) {
  final date = parseCalendarDate(value as String);
  if (date.year < 2000 || date.year > 2100) {
    throw const FormatException('Дата должна быть между 2000 и 2100 годом');
  }
  return date;
}

String _hash(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('Некорректная подпись исходных данных');
  }
  return value;
}

String annotationHash(LedgerEntry entry) => seriesDigest(entry.toJson());

enum ExpenseRole { unspecified, mandatory, flexible }

class EntryAnnotation {
  const EntryAnnotation({
    required this.entryId,
    required this.sourceHash,
    required this.reviewedOn,
    this.role = ExpenseRole.unspecified,
    this.counterparty = '',
    this.oneOff = false,
  });
  final String entryId, sourceHash, counterparty;
  final DateTime reviewedOn;
  final ExpenseRole role;
  final bool oneOff;
  bool valid(LedgerEntry entry) =>
      entry.id == entryId && annotationHash(entry) == sourceHash;
  Map<String, Object> toJson() => {
    'entryId': entryId,
    'sourceHash': sourceHash,
    'reviewedOn': calendarDate(reviewedOn),
    'role': role.name,
    'counterparty': counterparty,
    'oneOff': oneOff,
  };
  factory EntryAnnotation.fromJson(Map<String, dynamic> j) => EntryAnnotation(
    entryId: profileText(j['entryId'], max: 80),
    sourceHash: _hash(j['sourceHash']),
    reviewedOn: profileDate(j['reviewedOn']),
    role: ExpenseRole.values.byName(j['role'] as String),
    counterparty: profileText(j['counterparty'], empty: true),
    oneOff: j['oneOff'] as bool,
  );
}

class SavingsGoal {
  const SavingsGoal({
    required this.id,
    required this.name,
    required this.accountId,
    required this.targetMinor,
    required this.allocatedMinor,
    required this.start,
    required this.deadline,
    this.initialMinor = 0,
    this.monthlyMinor = 0,
  });
  final String id, name, accountId;
  final int targetMinor, allocatedMinor, initialMinor, monthlyMinor;
  final DateTime start, deadline;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'accountId': accountId,
    'targetMinor': targetMinor,
    'allocatedMinor': allocatedMinor,
    'initialMinor': initialMinor,
    'monthlyMinor': monthlyMinor,
    'start': calendarDate(start),
    'deadline': calendarDate(deadline),
  };
  factory SavingsGoal.fromJson(Map<String, dynamic> j) {
    final goal = SavingsGoal(
      id: profileText(j['id'], max: 80),
      name: profileText(j['name']),
      accountId: profileText(j['accountId'], max: 80),
      targetMinor: profileInt(j['targetMinor'], min: 1),
      allocatedMinor: profileInt(j['allocatedMinor']),
      initialMinor: profileInt(j['initialMinor']),
      monthlyMinor: profileInt(j['monthlyMinor']),
      start: profileDate(j['start']),
      deadline: profileDate(j['deadline']),
    );
    if (goal.deadline.isBefore(goal.start) ||
        goal.initialMinor > goal.targetMinor) {
      throw const FormatException('Проверьте срок и начальную сумму цели');
    }
    return goal;
  }
}

class DebtPlan {
  const DebtPlan({
    required this.id,
    required this.name,
    required this.principalMinor,
    required this.annualRateBp,
    required this.monthlyPaymentMinor,
    required this.monthlyFeeMinor,
    required this.firstDue,
  });
  final String id, name;
  final int principalMinor, annualRateBp, monthlyPaymentMinor, monthlyFeeMinor;
  final DateTime firstDue;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'principalMinor': principalMinor,
    'annualRateBp': annualRateBp,
    'monthlyPaymentMinor': monthlyPaymentMinor,
    'monthlyFeeMinor': monthlyFeeMinor,
    'firstDue': calendarDate(firstDue),
  };
  factory DebtPlan.fromJson(Map<String, dynamic> j) => DebtPlan(
    id: profileText(j['id'], max: 80),
    name: profileText(j['name']),
    principalMinor: profileInt(j['principalMinor'], min: 1),
    annualRateBp: profileInt(j['annualRateBp'], max: 100000),
    monthlyPaymentMinor: profileInt(j['monthlyPaymentMinor'], min: 1),
    monthlyFeeMinor: profileInt(j['monthlyFeeMinor']),
    firstDue: profileDate(j['firstDue']),
  );
}

class ExpectedRefund {
  const ExpectedRefund({
    required this.id,
    required this.purchaseId,
    required this.purchaseHash,
    required this.expectedMinor,
    required this.baselineRefundMinor,
    required this.due,
  });
  final String id, purchaseId, purchaseHash;
  final int expectedMinor, baselineRefundMinor;
  final DateTime due;
  Map<String, Object> toJson() => {
    'id': id,
    'purchaseId': purchaseId,
    'purchaseHash': purchaseHash,
    'expectedMinor': expectedMinor,
    'baselineRefundMinor': baselineRefundMinor,
    'due': calendarDate(due),
  };
  factory ExpectedRefund.fromJson(Map<String, dynamic> j) => ExpectedRefund(
    id: profileText(j['id'], max: 80),
    purchaseId: profileText(j['purchaseId'], max: 80),
    purchaseHash: _hash(j['purchaseHash']),
    expectedMinor: profileInt(j['expectedMinor'], min: 1),
    baselineRefundMinor: profileInt(j['baselineRefundMinor']),
    due: profileDate(j['due']),
  );
}

class TrackedAdvice {
  const TrackedAdvice({
    required this.id,
    required this.category,
    required this.baselineMonth,
    required this.baselineMinor,
    required this.targetMinor,
    required this.baselineHash,
  });
  final String id, category, baselineHash;
  final DateTime baselineMonth;
  final int baselineMinor, targetMinor;
  Map<String, Object> toJson() => {
    'id': id,
    'category': category,
    'baselineMonth': calendarDate(baselineMonth),
    'baselineMinor': baselineMinor,
    'targetMinor': targetMinor,
    'baselineHash': baselineHash,
  };
  factory TrackedAdvice.fromJson(Map<String, dynamic> j) {
    final item = TrackedAdvice(
      id: profileText(j['id'], max: 80),
      category: profileText(j['category'], max: 60),
      baselineMonth: profileDate(j['baselineMonth']),
      baselineMinor: profileInt(j['baselineMinor'], min: 1),
      targetMinor: profileInt(j['targetMinor']),
      baselineHash: _hash(j['baselineHash']),
    );
    if (item.baselineMonth.day != 1) {
      throw const FormatException('Выберите начало месяца');
    }
    return item;
  }
}

class AnalysisProfile {
  AnalysisProfile({
    this.trackingStart,
    this.lastBackupOn,
    this.backupEveryDays = 30,
    this.smallSkipCount = 0,
    this.touched = false,
    Map<String, EntryAnnotation> annotations = const {},
    Map<String, int> reserves = const {},
    Iterable<SavingsGoal> goals = const [],
    Iterable<DebtPlan> debts = const [],
    Iterable<ExpectedRefund> refunds = const [],
    Iterable<TrackedAdvice> tracked = const [],
    Map<String, String> categoryAliases = const {},
    Map<String, String> counterpartyAliases = const {},
    Map<String, int> flexibleCaps = const {},
    Iterable<String> scenarioCategories = const [],
    Iterable<String> pausePlanIds = const [],
    Map<String, int> ruleMinimums = const {},
    Map<String, int> categoryMinimums = const {},
    Map<String, int> priorities = const {},
  }) : annotations = Map.unmodifiable(annotations),
       reserves = Map.unmodifiable(reserves),
       goals = List.unmodifiable(goals),
       debts = List.unmodifiable(debts),
       refunds = List.unmodifiable(refunds),
       tracked = List.unmodifiable(tracked),
       categoryAliases = Map.unmodifiable(categoryAliases),
       counterpartyAliases = Map.unmodifiable(counterpartyAliases),
       flexibleCaps = Map.unmodifiable(flexibleCaps),
       scenarioCategories = Set.unmodifiable(scenarioCategories),
       pausePlanIds = Set.unmodifiable(pausePlanIds),
       ruleMinimums = Map.unmodifiable(ruleMinimums),
       categoryMinimums = Map.unmodifiable(categoryMinimums),
       priorities = Map.unmodifiable(priorities);
  final DateTime? trackingStart, lastBackupOn;
  final int backupEveryDays, smallSkipCount;
  final bool touched;
  final Map<String, EntryAnnotation> annotations;
  final Map<String, int> reserves,
      flexibleCaps,
      ruleMinimums,
      categoryMinimums,
      priorities;
  final List<SavingsGoal> goals;
  final List<DebtPlan> debts;
  final List<ExpectedRefund> refunds;
  final List<TrackedAdvice> tracked;
  final Map<String, String> categoryAliases, counterpartyAliases;
  final Set<String> scenarioCategories, pausePlanIds;
  bool get hasMonetaryInputs =>
      reserves.isNotEmpty ||
      goals.isNotEmpty ||
      debts.isNotEmpty ||
      refunds.isNotEmpty ||
      tracked.isNotEmpty ||
      flexibleCaps.isNotEmpty ||
      ruleMinimums.isNotEmpty ||
      categoryMinimums.isNotEmpty;
  String category(String value) => _resolve(value, categoryAliases);
  String counterparty(String value) => _resolve(value, counterpartyAliases);
  static String _resolve(String value, Map<String, String> aliases) {
    var key = normalizedLabel(value);
    final seen = <String>{};
    while (aliases.containsKey(key)) {
      if (!seen.add(key)) throw const FormatException('В алиасах есть цикл');
      key = normalizedLabel(aliases[key]!);
    }
    return key;
  }

  EntryAnnotation? annotation(LedgerEntry e, {DateTime? knownThrough}) {
    final tag = annotations[e.id];
    return tag != null &&
            tag.valid(e) &&
            (knownThrough == null || !tag.reviewedOn.isAfter(knownThrough))
        ? tag
        : null;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'trackingStart': trackingStart == null
        ? null
        : calendarDate(trackingStart!),
    'lastBackupOn': lastBackupOn == null ? null : calendarDate(lastBackupOn!),
    'backupEveryDays': backupEveryDays,
    'smallSkipCount': smallSkipCount,
    'touched': touched,
    'annotations': {
      for (final e in annotations.entries) e.key: e.value.toJson(),
    },
    'reserves': reserves,
    'goals': goals.map((e) => e.toJson()).toList(),
    'debts': debts.map((e) => e.toJson()).toList(),
    'refunds': refunds.map((e) => e.toJson()).toList(),
    'tracked': tracked.map((e) => e.toJson()).toList(),
    'categoryAliases': categoryAliases,
    'counterpartyAliases': counterpartyAliases,
    'flexibleCaps': flexibleCaps,
    'scenarioCategories': scenarioCategories.toList()..sort(),
    'pausePlanIds': pausePlanIds.toList()..sort(),
    'ruleMinimums': ruleMinimums,
    'categoryMinimums': categoryMinimums,
    'priorities': priorities,
  };
  AnalysisProfile patch(Map<String, Object?> changes) =>
      AnalysisProfile.fromJson({...toJson(), ...changes, 'touched': true});
  factory AnalysisProfile.fromJson(Map<String, dynamic> j) {
    if (j['version'] != 1) {
      throw const FormatException('Неизвестная версия профиля анализа');
    }
    Map<String, int> numbers(
      String key, {
      int max = maxMoneyMinor,
      int min = 0,
    }) {
      final map = j[key] as Map;
      if (map.length > 500) {
        throw const FormatException('Слишком много параметров');
      }
      return map.map(
        (k, v) => MapEntry(
          profileText(k, max: 100),
          profileInt(v, min: min, max: max),
        ),
      );
    }

    Map<String, String> aliases(String key) {
      final raw = j[key] as Map,
          result = raw.map(
            (k, v) => MapEntry(
              normalizedLabel(profileText(k)),
              normalizedLabel(profileText(v)),
            ),
          );
      if (result.length != raw.length) {
        throw const FormatException('Повтор названия алиаса');
      }
      return result;
    }

    List<T> records<T>(String key, T Function(Map<String, dynamic>) parse) {
      final rows = j[key] as List;
      if (rows.length > 200) {
        throw const FormatException('Слишком много записей профиля');
      }
      final ids = <String>{};
      return rows.map((e) {
        final row = Map<String, dynamic>.from(e as Map);
        if (!ids.add(profileText(row['id'], max: 80))) {
          throw const FormatException('Повтор идентификатора');
        }
        return parse(row);
      }).toList();
    }

    final tags = (j['annotations'] as Map).map(
      (k, v) => MapEntry(
        profileText(k, max: 80),
        EntryAnnotation.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    );
    if (tags.length > 10000 ||
        tags.entries.any((e) => e.key != e.value.entryId)) {
      throw const FormatException('Некорректные метки операций');
    }
    final profile = AnalysisProfile(
      trackingStart: j['trackingStart'] == null
          ? null
          : profileDate(j['trackingStart']),
      lastBackupOn: j['lastBackupOn'] == null
          ? null
          : profileDate(j['lastBackupOn']),
      backupEveryDays: profileInt(j['backupEveryDays'], min: 1, max: 365),
      smallSkipCount: profileInt(j['smallSkipCount'], max: 100),
      touched: j['touched'] as bool,
      annotations: tags,
      reserves: numbers('reserves'),
      goals: records('goals', SavingsGoal.fromJson),
      debts: records('debts', DebtPlan.fromJson),
      refunds: records('refunds', ExpectedRefund.fromJson),
      tracked: records('tracked', TrackedAdvice.fromJson),
      categoryAliases: aliases('categoryAliases'),
      counterpartyAliases: aliases('counterpartyAliases'),
      flexibleCaps: numbers('flexibleCaps'),
      scenarioCategories: (j['scenarioCategories'] as List).map(
        (e) => normalizedLabel(profileText(e, max: 60)),
      ),
      pausePlanIds: (j['pausePlanIds'] as List).map(
        (e) => profileText(e, max: 80),
      ),
      ruleMinimums: numbers('ruleMinimums', min: 1),
      categoryMinimums: numbers('categoryMinimums', min: 1),
      priorities: numbers('priorities', max: 100),
    );
    for (final alias in [
      profile.categoryAliases,
      profile.counterpartyAliases,
    ]) {
      if (alias.length > 500) {
        throw const FormatException('Слишком много алиасов');
      }
      for (final key in alias.keys) {
        _resolve(key, alias);
      }
    }
    if (profile.ruleMinimums.keys.any(
          (id) => !{'B1', 'B2', 'H1', 'C5'}.contains(id),
        ) ||
        profile.priorities.keys.any(
          (id) => !RegExp(r'^[A-O][1-6]$').hasMatch(id),
        )) {
      throw const FormatException('Неизвестное правило порога');
    }
    if (profile.scenarioCategories.length > 500 ||
        profile.pausePlanIds.length > 500 ||
        profile.flexibleCaps.keys.map(profile.category).toSet().length !=
            profile.flexibleCaps.length) {
      throw const FormatException(
        'Проверьте число сценариев и совпадающие потолки категорий',
      );
    }
    return profile;
  }
}
