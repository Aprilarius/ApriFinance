import 'models.dart';

/// All arithmetic uses integer minor units. The first version supports only
/// currencies with two fraction digits, chosen once for the entire ledger.
const maxMoneyMinor = 900000000000000;

int parseMoney(String input, {bool allowNegative = false}) {
  final value = input.trim().replaceAll(RegExp(r'[\s\u00a0\u202f]'), '');
  final pattern = allowNegative
      ? RegExp(r'^-?\d{1,13}([.,]\d{1,2})?$')
      : RegExp(r'^\d{1,13}([.,]\d{1,2})?$');
  if (!pattern.hasMatch(value)) {
    throw const FormatException('Введите сумму: например, 1250,50');
  }
  final negative = value.startsWith('-');
  final parts = value.replaceFirst('-', '').split(RegExp('[.,]'));
  final whole = int.parse(parts[0]);
  final fraction = parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0;
  final result = (whole * 100 + fraction) * (negative ? -1 : 1);
  if (result.abs() > maxMoneyMinor) {
    throw const FormatException('Сумма слишком велика');
  }
  return result;
}

String editableMoney(int minor) =>
    '${minor < 0 ? '-' : ''}${minor.abs() ~/ 100},${(minor.abs() % 100).toString().padLeft(2, '0')}';

String formatMoney(int minor, String currency) {
  final whole = (minor.abs() ~/ 100).toString();
  final grouped = whole.replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]}\u00a0',
  );
  return '${minor < 0 ? '−' : ''}$grouped,${(minor.abs() % 100).toString().padLeft(2, '0')} $currency';
}

/// Checked aggregate, separate from the lower limit on an individual amount.
int checkedMoneyTotal(BigInt value) {
  if (value < BigInt.parse('-9223372036854775808') ||
      value > BigInt.parse('9223372036854775807')) {
    throw const DomainError('Итог слишком велик для безопасного расчёта');
  }
  return value.toInt();
}

int sumMoneyTotals(Iterable<int> values) =>
    checkedMoneyTotal(values.fold(BigInt.zero, (a, b) => a + BigInt.from(b)));
