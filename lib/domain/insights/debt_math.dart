import 'analysis_profile.dart';
import 'analysis_facts.dart';

class DebtMonth {
  const DebtMonth(
    this.date,
    this.paymentMinor,
    this.interestMinor,
    this.feeMinor,
    this.remainingMinor,
  );
  final DateTime date;
  final int paymentMinor, interestMinor, feeMinor, remainingMinor;
}

class DebtSchedule {
  const DebtSchedule(this.months, this.amortizes, this.capped);
  final List<DebtMonth> months;
  final bool amortizes, capped;
}

DebtSchedule debtSchedule(DebtPlan debt) {
  var principal = BigInt.from(debt.principalMinor);
  final months = <DebtMonth>[];
  for (var n = 0; n < 600 && principal > BigInt.zero; n++) {
    final interest =
        (principal * BigInt.from(debt.annualRateBp) + BigInt.from(119999)) ~/
        BigInt.from(120000);
    final fee = BigInt.from(debt.monthlyFeeMinor),
        planned = BigInt.from(debt.monthlyPaymentMinor);
    if (planned <= interest + fee) {
      return DebtSchedule(List.unmodifiable(months), false, false);
    }
    final due = principal + interest + fee;
    final paid = planned < due ? planned : due;
    principal -= paid - interest - fee;
    final first = DateTime(debt.firstDue.year, debt.firstDue.month + n),
        lastDay = DateTime(first.year, first.month + 1, 0).day;
    months.add(
      DebtMonth(
        DateTime(
          first.year,
          first.month,
          debt.firstDue.day > lastDay ? lastDay : debt.firstDue.day,
        ),
        checked(paid),
        checked(interest),
        debt.monthlyFeeMinor,
        checked(principal),
      ),
    );
  }
  return DebtSchedule(List.unmodifiable(months), true, principal > BigInt.zero);
}
