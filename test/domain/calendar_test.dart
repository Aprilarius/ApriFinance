import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  test('calendar days ignore 23/25 hour days and time of day', () {
    tzdata.initializeTimeZones();
    final zone = tz.getLocation('America/New_York');
    final spring = tz.TZDateTime(zone, 2026, 3, 8);
    final tomorrow = tz.TZDateTime(zone, 2026, 3, 9);
    expect(tomorrow.difference(spring).inHours, 23);
    expect(calendarDaysBetween(spring, tomorrow), 1);
    expect(calendarDaysBetween(tomorrow, spring), -1);
    expect(
      calendarDaysBetween(
        tz.TZDateTime(zone, 2026, 11, 1),
        tz.TZDateTime(zone, 2026, 11, 2),
      ),
      1,
    );
    expect(
      calendarDaysBetween(
        DateTime(2026, 11, 14, 23),
        DateTime(2026, 11, 15, 1),
      ),
      1,
    );
  });
}
