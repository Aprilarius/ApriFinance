import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import '../domain/reminder_plan.dart';

abstract interface class ReminderBackend {
  bool get supported;
  String get zone;
  Future<void> initialize();
  Future<bool> permission({bool request = false});
  Future<void> cancel();
  Future<int> schedule(List<ReminderItem> items);
}

class NativeReminderBackend implements ReminderBackend {
  late final _plugin = FlutterLocalNotificationsPlugin();
  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);
  @override
  String zone = '';
  Future<void> _timezone() async {
    final current = await FlutterTimezone.getLocalTimezone();
    zone = current.identifier;
    tz.setLocalLocation(tz.getLocation(zone));
  }

  @override
  Future<void> initialize() async {
    if (!supported) return;
    tzdata.initializeTimeZones();
    await _timezone();
    final initialized = await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
    );
    // macOS returns the permission result here; false is expected when no
    // permission was requested. Android uses this result for initialization.
    if (defaultTargetPlatform == TargetPlatform.android &&
        initialized != true) {
      throw const DomainError('Android не смог подготовить уведомления');
    }
  }

  @override
  Future<bool> permission({bool request = false}) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()!;
      final granted =
          (request
              ? await android.requestNotificationsPermission()
              : await android.areNotificationsEnabled()) ??
          false;
      if (!granted) return false;
      // Android can allow the app but block only this notification channel.
      final channels = await android.getNotificationChannels();
      final reminders = channels
          ?.where((c) => c.id == 'payment_reminders')
          .firstOrNull;
      return reminders == null || reminders.importance != Importance.none;
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final mac = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()!;
      return request
          ? await mac.requestPermissions(
                  alert: true,
                  badge: false,
                  sound: true,
                ) ??
                false
          : (await mac.checkPermissions())?.isEnabled ?? false;
    }
    return false;
  }

  @override
  Future<void> cancel() async {
    if (supported) await _plugin.cancelAllPendingNotifications();
  }

  @override
  Future<int> schedule(List<ReminderItem> items) async {
    await _timezone();
    var count = 0;
    for (final item in items) {
      final d = item.fireAt;
      final at = tz.TZDateTime(tz.local, d.year, d.month, d.day, d.hour);
      if (!at.isAfter(tz.TZDateTime.now(tz.local))) continue;
      await _plugin.zonedSchedule(
        id: ++count,
        scheduledDate: at,
        title: item.purchase
            ? 'Проверьте сроки покупки'
            : item.trial
            ? 'Проверьте пробный период'
            : 'Проверьте запланированные платежи',
        body: 'Откройте «ApriFinance», чтобы посмотреть сроки.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'payment_reminders',
            'Платежи и сроки',
            channelDescription: 'Напоминания о платежах, возвратах и гарантиях',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            visibility: NotificationVisibility.private,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
    return count;
  }
}

class RemindersService {
  RemindersService(this.backend, this.preferences, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final ReminderBackend backend;
  final File preferences;
  final DateTime Function() clock;
  bool enabled = false;
  int hour = 9;
  int scheduled = 0;
  String status = 'Напоминания выключены';
  bool _ready = false;
  Future<void> _queue = Future.value();

  Future<void> initialize() async {
    try {
      await backend.initialize();
      _ready = true;
      if (await preferences.exists()) {
        final j = jsonDecode(await preferences.readAsString()) as Map;
        enabled = j['enabled'] == true;
        final h = j['hour'];
        if (h is int && h >= 0 && h < 24) hour = h;
      }
      if (!backend.supported) {
        enabled = false;
        status = 'В Windows ZIP-версии и EXE-установке сроки доступны внутри приложения. Фоновые уведомления потребуют версии MSIX.';
      }
    } catch (_) {
      status = 'Не удалось подготовить уведомления. Учёт и календарь продолжают работать.';
    }
  }

  Future<void> _save() async {
    await preferences.parent.create(recursive: true);
    final tmp = File('${preferences.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'enabled': enabled, 'hour': hour}),
      flush: true,
    );
    await tmp.rename(preferences.path);
  }

  Future<void> configure(
    LedgerSnapshot snapshot, {
    required bool turnOn,
    int? atHour,
  }) => _enqueue(() async {
    if (!_ready) await initialize();
    if (!backend.supported) return;
    if (!_ready) {
      throw const DomainError(
        'Не удалось подготовить уведомления. Учёт и календарь продолжают работать.',
      );
    }
    final previousHour = hour;
    final previousEnabled = enabled;
    final granted = !turnOn || await backend.permission(request: true);
    if (atHour != null && atHour >= 0 && atHour < 24) hour = atHour;
    enabled = turnOn && granted;
    try {
      await _save();
    } catch (_) {
      hour = previousHour;
      enabled = previousEnabled;
      rethrow;
    }
    await _synchronize(snapshot);
    if (!granted) {
      status = 'Уведомления не разрешены в системе. Сроки остаются в разделе «Платежи».';
    }
  });

  // Configuration, file writes and OS scheduling share one queue. A failed
  // operation reaches its caller but must not poison later operations.
  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _queue.then((_) => action());
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> synchronize(LedgerSnapshot snapshot) =>
      _enqueue(() => _synchronize(snapshot));

  Future<void> _synchronize(LedgerSnapshot snapshot) async {
    if (!_ready || !backend.supported) return;
    try {
      await backend.cancel();
      scheduled = 0;
      if (!enabled) {
        status = 'Напоминания выключены';
        return;
      }
      if (!await backend.permission()) {
        status = 'Уведомления отключены в системе. Проверьте разрешения.';
        return;
      }
      final plan = reminderPlan(snapshot, clock(), hour: hour);
      scheduled = await backend.schedule(plan.take(60).toList());
      status =
          'Запланировано уведомлений: $scheduled · ${backend.zone}. '
          '${plan.length > 60 ? 'Выбраны 60 ближайших. ' : ''}Обновите расписание, открыв приложение после изменения часового пояса.';
    } catch (_) {
      scheduled = 0;
      try {
        await backend.cancel();
      } catch (_) {
        /* Keep finance independent. */
      }
      status = 'Не удалось перепланировать уведомления. Откройте приложение повторно; сроки доступны в календаре.';
    }
  }
}
