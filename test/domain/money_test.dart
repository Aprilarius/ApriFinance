import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/money.dart';

void main() {
  test('decimal commas, dots and spaces parse without floating point', () {
    expect(parseMoney('1 250,5'), 125050);
    expect(parseMoney('0.01') + parseMoney('0,09'), 10);
    expect(parseMoney('-10,25', allowNegative: true), -1025);
    expect(formatMoney(-125050, 'USD'), '−1\u00a0250,50 USD');
  });
  test('invalid and ambiguous amounts are rejected', () {
    for (final value in [
      '',
      '-1',
      '1,234',
      '1.2.3',
      'NaN',
      '1e3',
      '99999999999999999999',
    ]) {
      expect(() => parseMoney(value), throwsFormatException, reason: value);
    }
  });
}
