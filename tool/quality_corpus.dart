import 'dart:convert';
import 'dart:io';

import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/insights/insight.dart';
import 'package:personal_finance/domain/insights/insight_engine.dart';

Map<String, Object> qualityCorpus() {
  final cases =
      <({String name, String rule, bool expected, List<LedgerEntry> rows})>[];
  List<LedgerEntry> rows(List<DateTime> dates, {List<int>? amounts}) => [
    for (var n = 0; n < dates.length; n++)
      LedgerEntry(
        id: 'e-$n',
        kind: EntryKind.expense,
        amountMinor: amounts?[n] ?? 2000,
        date: dates[n],
        accountId: 'a',
        category: 'Тест',
        note: 'Тестовый сервис',
      ),
  ];
  for (final offset in [0, 1, 2]) {
    cases.add((
      name: 'monthly-$offset',
      rule: 'G1',
      expected: true,
      rows: rows([
        for (final m in [9, 10, 11]) DateTime(2026, m, 5 + offset),
      ]),
    ));
    cases.add((
      name: 'irregular-monthly-$offset',
      rule: 'G1',
      expected: false,
      rows: rows([
        DateTime(2026, 9, 3),
        DateTime(2026, 10, 20),
        DateTime(2026, 11, 4 + offset),
      ]),
    ));
    cases.add((
      name: 'weekly-$offset',
      rule: 'G2',
      expected: true,
      rows: rows([
        for (var n = 0; n < 4; n++) DateTime(2026, 10, 21 + offset + n * 7),
      ]),
    ));
    cases.add((
      name: 'irregular-weekly-$offset',
      rule: 'G2',
      expected: false,
      rows: rows([
        for (var n = 0; n < 4; n++) DateTime(2026, 10, 10 + offset + n * 10),
      ]),
    ));
    cases.add((
      name: 'identical-candidate-$offset',
      rule: 'H4',
      expected: true,
      rows: rows([
        DateTime(2026, 11, 2 + offset),
        DateTime(2026, 11, 2 + offset),
      ]),
    ));
    cases.add((
      name: 'different-amount-$offset',
      rule: 'H4',
      expected: false,
      rows: rows(
        [DateTime(2026, 11, 2), DateTime(2026, 11, 2)],
        amounts: [2000, 2100 + offset],
      ),
    ));
    for (final spike in [true, false]) {
      final amounts = [
        for (var n = 0; n < 30; n++) n % 5 == 0 ? 4000 : 100,
        spike ? 20000 : 4000,
      ];
      cases.add((
        name: 'bimodal-${spike ? 'spike' : 'routine'}-$offset',
        rule: 'H1',
        expected: spike,
        rows: rows([
          for (var n = 0; n < 30; n++) DateTime(2026, 10, n + 1),
          DateTime(2026, 11, 5 + offset),
        ], amounts: amounts),
      ));
    }
  }
  final metrics = <String, Map<String, int>>{},
      details = <Map<String, Object>>[];
  for (final c in cases) {
    final s = LedgerSnapshot(
      currency: 'AZN',
      accounts: const [
        Account(id: 'a', name: 'Synthetic', kind: 'Карта', openingMinor: 0),
      ],
      entries: c.rows,
    );
    final detected = InsightEngine()
        .analyze(
          s,
          DateTime(2026, 11),
          DateTime(2026, 11, 14),
          AnalysisPolicy(),
        )
        .any((i) => i.rule == c.rule);
    final m = metrics.putIfAbsent(
      c.rule,
      () => {'tp': 0, 'fp': 0, 'tn': 0, 'fn': 0},
    );
    final key = c.expected
        ? (detected ? 'tp' : 'fn')
        : (detected ? 'fp' : 'tn');
    m[key] = m[key]! + 1;
    details.add({
      'name': c.name,
      'rule': c.rule,
      'expected_candidate': c.expected,
      'detected': detected,
    });
  }
  return {
    'synthetic_only': true,
    'case_count': cases.length,
    'scope': 'Hand-labelled candidate patterns G1/G2/H1/H4, not real-world accuracy or automatic transaction judgement',
    'metrics': {
      for (final e in metrics.entries)
        e.key: {
          ...e.value,
          'precision': e.value['tp']! / (e.value['tp']! + e.value['fp']!),
          'recall': e.value['tp']! / (e.value['tp']! + e.value['fn']!),
        },
    },
    'cases': details,
  };
}

void main() {
  stdout.writeln(jsonEncode(qualityCorpus()));
}
