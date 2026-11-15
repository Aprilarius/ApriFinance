import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/insights_preferences_repository.dart';
import 'package:personal_finance/domain/insights/insight.dart';

import '../domain/confirmed_series_test.dart'
    show acceptedPolicy, seriesFixture;

void main() {
  test('series reviews survive file reopen and oversized writes preserve prior settings', () async {
    final directory = await Directory.systemTemp.createTemp(
      'apri-series-test-',
    );
    final file = File('${directory.path}/insights.json');
    try {
      final store = FileInsightsPreferences(file), policy = acceptedPolicy();
      await store.write(policy);
      final reopened = await FileInsightsPreferences(file).read();
      expect(
        reopened.seriesReviews.values.single.validAt(
          seriesFixture(),
          DateTime(2026, 11, 14),
        ),
        isTrue,
      );
      final previous = await file.readAsBytes();
      await expectLater(
        store.write(policy.copyWith(hidden: {'я' * (1024 * 1024)})),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), previous);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    } finally {
      if (await file.exists()) await file.delete();
      await directory.delete();
    }
  });
  test('preferences survive reopen and preserve explicit coverage and hidden rules', () async {
    final directory = await Directory.systemTemp.createTemp(
      'apri-insights-test-',
    );
    try {
      final file = File('${directory.path}/insights.json');
      final store = FileInsightsPreferences(file);
      expect((await store.read()).disabled, isEmpty);
      final policy = AnalysisPolicy(
        disabled: {'A1'},
        hidden: {'C2:e:2026-11'},
        verifiedThrough: {'2026-11': '2026-11-14'},
      );
      await store.write(policy);
      expect(
        (await FileInsightsPreferences(file).read()).toJson(),
        policy.toJson(),
      );
      await store.write(policy.copyWith(changePercent: 30));
      expect((await store.read()).changePercent, 30);
      expect(await File('${file.path}.tmp').exists(), false);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test(
    'corrupt or future-version preferences are not silently overwritten',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'apri-insights-test-',
      );
      try {
        final file = File('${directory.path}/insights.json');
        await file.writeAsString('{bad-json');
        await expectLater(
          FileInsightsPreferences(file).read(),
          throwsFormatException,
        );
        expect(await file.readAsString(), '{bad-json');
        await file.writeAsString('{"version":99}');
        await expectLater(
          FileInsightsPreferences(file).read(),
          throwsFormatException,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
