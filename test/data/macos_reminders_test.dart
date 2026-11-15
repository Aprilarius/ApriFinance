import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/reminders_service.dart';
import 'package:personal_finance/domain/reminder_plan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const timezone = MethodChannel('flutter_timezone');
  final calls = <MethodCall>[];
  var granted = false;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    granted = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(timezone, (_) async => 'Asia/Baku');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => false,
        'requestPermissions' => granted,
        'checkPermissions' => {
          'isEnabled': granted,
          'isAlertEnabled': granted,
          'isBadgeEnabled': false,
          'isSoundEnabled': granted,
        },
        _ => null,
      };
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(timezone, null);
  });
  test('macOS initializes without prompting and requests permission only explicitly', () async {
    final backend = NativeReminderBackend();
    await backend.initialize();
    expect(backend.supported, isTrue);
    expect(calls.where((c) => c.method == 'requestPermissions'), isEmpty);
    expect(await backend.permission(), isFalse);
    expect(await backend.permission(request: true), isFalse);
    granted = true;
    expect(await backend.permission(request: true), isTrue);
    final request = calls.last.arguments as Map;
    expect(request['alert'], isTrue);
    expect(request['badge'], isFalse);
  });
  test('macOS schedules private text using the current time zone', () async {
    final backend = NativeReminderBackend();
    await backend.initialize();
    granted = true;
    final day = DateTime.now().add(const Duration(days: 2));
    expect(
      await backend.schedule([
        ReminderItem(
          'fictional',
          DateTime(day.year, day.month, day.day, 9),
          false,
        ),
      ]),
      1,
    );
    final payload =
        calls.singleWhere((c) => c.method == 'zonedSchedule').arguments as Map;
    expect(payload['timeZoneName'], 'Asia/Baku');
    expect(payload['body'], 'Откройте «ApriFinance», чтобы посмотреть сроки.');
  });
}
