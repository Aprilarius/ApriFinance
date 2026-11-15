import 'package:flutter_test/flutter_test.dart';

import '../../tool/quality_corpus.dart';

void main() {
  test(
    'labelled synthetic candidate corpus has no false positives or misses',
    () {
      final result = qualityCorpus();
      expect(result['case_count'], 24);
      for (final metric in (result['metrics'] as Map).values) {
        expect(metric['fp'], 0);
        expect(metric['fn'], 0);
      }
    },
  );
}
