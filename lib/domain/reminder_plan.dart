import 'models.dart';
import 'schedule_math.dart';

class ReminderItem {
  const ReminderItem(
    this.key,
    this.fireAt,
    this.trial, {
    this.purchase = false,
  });
  final bool purchase;
  final String key;
  final DateTime fireAt;
  final bool trial;
}

List<ReminderItem> reminderPlan(
  LedgerSnapshot snapshot,
  DateTime now, {
  int hour = 9,
}) {
  final today = dayOnly(now);
  final end = DateTime(today.year, today.month, today.day + 366, 23, 59, 59);
  final result = <ReminderItem>[];
  final dates = <String>{};
  for (final o in snapshot.obligations.where((o) => o.active)) {
    void add(DateTime date, String key, bool trial) {
      for (final offset in {o.reminderDays, 0}) {
        final at = DateTime(date.year, date.month, date.day - offset, hour);
        if (!at.isAfter(now) || at.isAfter(end)) continue;
        if (dates.add('${o.id}:${calendarDate(at)}')) {
          result.add(ReminderItem('$key:$offset', at, trial));
        }
      }
    }

    if (o.trialEnd != null) add(o.trialEnd!, '${o.id}:trial', true);
    for (final occurrence in occurrences(
      o,
      today,
      DateTime(end.year, end.month, end.day + 7),
    )) {
      add(occurrence.date, occurrence.key, false);
    }
  }
  for (final p in snapshot.purchases.where((p) => !p.archived)) {
    for (final deadline in [p.returnBy, p.warrantyUntil].nonNulls) {
      for (final offset in {7, 0}) {
        final at = DateTime(
          deadline.year,
          deadline.month,
          deadline.day - offset,
          hour,
        );
        if (!at.isAfter(now) || at.isAfter(end)) continue;
        final key = 'purchase:${p.id}:${calendarDate(at)}';
        if (dates.add(key)) {
          result.add(ReminderItem(key, at, false, purchase: true));
        }
      }
    }
  }
  result.sort((a, b) => a.fireAt.compareTo(b.fireAt));
  return result;
}
