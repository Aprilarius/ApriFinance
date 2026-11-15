import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_finance/ui/theme.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  return ((first > second ? first : second) + 0.05) /
      ((first < second ? first : second) + 0.05);
}

void main() {
  test('normal and semantic text stays readable on working surfaces', () {
    for (final ink in [
      LedgerColors.ink,
      LedgerColors.muted,
      LedgerColors.green,
      LedgerColors.expense,
      const Color(0xFF916500),
    ]) {
      for (final surface in [Colors.white, LedgerColors.paper]) {
        expect(contrast(ink, surface), greaterThanOrEqualTo(4.5));
      }
    }
  });
  test('primary button label contrast meets normal text threshold', () {
    final colors = ledgerTheme().colorScheme;
    expect(
      contrast(colors.onPrimary, colors.primary),
      greaterThanOrEqualTo(4.5),
    );
  });
}
