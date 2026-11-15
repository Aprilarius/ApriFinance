import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/reminders_service.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/domain/reminder_plan.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  const timezone = MethodChannel('flutter_timezone');
  final calls = <MethodCall>[];
  var initializeOk = true, appGranted = true, hasChannel = true;
  var channelImportance = 3;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    initializeOk = true;
    appGranted = true;
    hasChannel = true;
    channelImportance = 3;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(timezone, (_) async => 'Asia/Baku');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifications, (call) async {
          calls.add(call);
          return switch (call.method) {
            'initialize' => initializeOk,
            'requestNotificationsPermission' ||
            'areNotificationsEnabled' => appGranted,
            'getNotificationChannels' =>
              hasChannel
                  ? [
                      <String, Object?>{
                        'id': 'payment_reminders',
                        'name': 'Платежи и сроки',
                        'importance': channelImportance,
                        'showBadge': true,
                        'bypassDnd': false,
                        'playSound': true,
                        'enableLights': false,
                        'enableVibration': true,
                        'ledColor': 0,
                        'audioAttributesUsage': 5,
                      },
                    ]
                  : <Map<String, Object?>>[],
            _ => null,
          };
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifications, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(timezone, null);
  });
  test('Android initialization failure is not reported as ready', () async {
    initializeOk = false;
    await expectLater(
      NativeReminderBackend().initialize(),
      throwsA(isA<DomainError>()),
    );
  });
  test(
    'disabled reminder channel is denied even when app permission is granted',
    () async {
      final backend = NativeReminderBackend();
      await backend.initialize();
      channelImportance = 0;
      expect(await backend.permission(), isFalse);
      expect(await backend.permission(request: true), isFalse);
    },
  );
  test(
    'Android schedule keeps private content and inexact idle mode',
    () async {
      final backend = NativeReminderBackend();
      await backend.initialize();
      expect(
        calls.any((c) => c.method == 'requestNotificationsPermission'),
        isFalse,
      );
      expect(backend.supported, isTrue);
      expect(await backend.permission(), isTrue);
      final day = DateTime.now().add(const Duration(days: 2));
      final result = await backend.schedule([
        ReminderItem(
          'fictional-key',
          DateTime(day.year, day.month, day.day, 9),
          false,
        ),
      ]);
      expect(result, 1);
      final payload =
          calls.singleWhere((c) => c.method == 'zonedSchedule').arguments
              as Map<Object?, Object?>;
      expect(
        payload['body'],
        'Откройте «ApriFinance», чтобы посмотреть сроки.',
      );
      expect(payload['timeZoneName'], 'Asia/Baku');
      final android = payload['platformSpecifics'] as Map<Object?, Object?>;
      expect(
        android['scheduleMode'],
        AndroidScheduleMode.inexactAllowWhileIdle.name,
      );
      expect(
        calls.any((c) => c.method == 'requestExactAlarmsPermission'),
        isFalse,
      );
    },
  );
  test(
    'first launch or pre-channel Android can grant app-level permission',
    () async {
      hasChannel = false;
      final backend = NativeReminderBackend();
      await backend.initialize();
      expect(await backend.permission(), isTrue);
    },
  );
  test(
    'app-level denial does not attempt to use notification channels',
    () async {
      appGranted = false;
      final backend = NativeReminderBackend();
      await backend.initialize();
      expect(await backend.permission(request: true), isFalse);
      expect(calls.any((c) => c.method == 'getNotificationChannels'), isFalse);
    },
  );
}
