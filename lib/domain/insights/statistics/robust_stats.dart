import '../analysis_facts.dart';

BigInt medianTwice(Iterable<BigInt> input) {
  final sorted = input.toList()..sort();
  if (sorted.isEmpty) throw ArgumentError('Empty statistical sample');
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle] * BigInt.two
      : sorted[middle - 1] + sorted[middle];
}

class RobustStats {
  RobustStats(Iterable<int> values) {
    final data = values.map(BigInt.from).toList()..sort();
    count = data.length;
    center2 = medianTwice(data);
    mad4 = medianTwice(data.map((v) => (v * BigInt.two - center2).abs()));
    upperReference = data[(count * 9 + 9) ~/ 10 - 1];
  }
  late final int count;
  late final BigInt center2, mad4;
  late final BigInt upperReference;
  int get medianFloor => checked(center2 ~/ BigInt.two);
  bool high(int value, {required int minimumDifference}) {
    final delta2 = BigInt.from(value) * BigInt.two - center2;
    if (delta2 <= BigInt.zero ||
        delta2 < BigInt.from(minimumDifference) * BigInt.two) {
      return false;
    }
    if (mad4 == BigInt.zero) {
      return BigInt.from(value) > upperReference &&
          BigInt.from(value) * BigInt.two >= center2 * BigInt.from(3);
    }
    // Modified z > 3.5, using half-unit median and quarter-unit MAD.
    return delta2 * BigInt.from(13490) > mad4 * BigInt.from(35000);
  }
}
