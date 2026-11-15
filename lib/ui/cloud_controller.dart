import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/cloud_transport.dart';
import '../data/finance_repository.dart';
import '../data/sync_service.dart';
import 'finance_view_model.dart';
import 'dialogs.dart';

typedef CancelScheduledSync = void Function();
typedef ScheduleSync = CancelScheduledSync Function(
  Duration delay,
  void Function() task,
);

CancelScheduledSync _scheduleTimer(Duration delay, void Function() task) {
  final timer = Timer(delay, task);
  return timer.cancel;
}

class CloudController extends ChangeNotifier {
  CloudController(
    this.vm, {
    this.preferences,
    this.transport,
    ScheduleSync? schedule,
  }) : _schedule = schedule ?? _scheduleTimer {
    vm.addListener(_financeChanged);
    vm.insights.addListener(_analysisChanged);
  }
  final FinanceViewModel vm;
  final File? preferences;
  final CloudTransport? transport;
  final ScheduleSync _schedule;
  CancelScheduledSync? _cancelScheduled;
  bool automaticEnabled = false;
  bool _foreground = true, _disposed = false, _automaticBlocked = false;
  bool _autoAgain = false;
  int _failures = 0;
  int? _observedPending;
  String? _sessionPassword;
  bool get automaticReady =>
      automaticEnabled &&
      signedIn &&
      _sessionPassword != null &&
      !_automaticBlocked &&
      preview == null &&
      !_disposed;
  bool get needsAttention => _automaticBlocked;

  void setAutomatic(bool enabled) {
    if (busy || _disposed) return;
    _cancelAuto();
    automaticEnabled = enabled && signedIn;
    _automaticBlocked = false;
    _autoAgain = false;
    _failures = 0;
    if (!automaticEnabled) _sessionPassword = null;
    status = automaticEnabled
        ? 'Выполните ручной обмен, чтобы разблокировать автоматический режим на эту сессию.'
        : 'Автоматический обмен выключен. Доступен ручной обмен.';
    notifyListeners();
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _cancelAuto();
    if (foreground && automaticReady) _queueAuto(const Duration(seconds: 1));
  }

  void _cancelAuto() {
    _cancelScheduled?.call();
    _cancelScheduled = null;
  }

  void _queueAuto(Duration delay) {
    if (!automaticReady || !_foreground) return;
    _cancelAuto();
    _cancelScheduled = _schedule(delay, () {
      _cancelScheduled = null;
      unawaited(exchangeAutomatically());
    });
  }

  int _analysisRevision = 0;
  void _analysisChanged() {
    final current = vm.insights.localChangeRevision;
    if (current == _analysisRevision) return;
    _analysisRevision = current;
    if (!automaticReady) return;
    if (busy) {
      _autoAgain = true;
      return;
    }
    _queueAuto(const Duration(seconds: 2));
  }

  void _financeChanged() {
    if (vm.loading) return;
    final pending = vm.snapshot?.pendingChanges ?? 0;
    final changed = pending != _observedPending;
    _observedPending = pending;
    if (!automaticReady || !changed || pending == 0) return;
    if (busy) {
      _autoAgain = true;
      return;
    }
    _queueAuto(const Duration(seconds: 2));
  }

  Future<void> exchangeAutomatically() async {
    if (!automaticReady || !_foreground) return;
    if (busy) {
      _autoAgain = true;
      return;
    }
    if (vm.loading) {
      _queueAuto(const Duration(seconds: 1));
      return;
    }
    _cancelAuto();
    final password = _sessionPassword!;
    status = 'Автоматический обмен: проверка изменений…';
    await _run(() async {
      final plan = await _sync!.preview(password);
      if (!automaticReady || !_foreground || _sessionPassword != password) {
        return;
      }
      if (plan.needsChoice) {
        preview = plan;
        _password = password;
        _sessionPassword = null;
        _automaticBlocked = true;
        status = 'Автоматический обмен остановлен: нужен выбор версии.';
        return;
      }
      await _sync!.commit(plan, password);
      if (_disposed) return;
      await vm.refresh();
      lastSuccess = await vm.repository.lastSyncAt();
      status = 'Автоматический обмен завершён.';
    }, automatic: true);
  }

  SupabaseSnapshotRemote? _remote;
  SyncService? _sync;
  bool busy = false;
  String status = 'Обмен не подключён';
  String url = '', publicKey = '';
  String? lastSuccess;
  SyncPreview? preview;
  String? _password;
  bool get signedIn => _remote?.signedIn ?? false;
  Future<void> initialize() async {
    try {
      lastSuccess = await vm.repository.lastSyncAt();
      if (preferences != null && await preferences!.exists()) {
        final body = jsonDecode(await preferences!.readAsString());
        if (body is Map) {
          final config = CloudConfig(
            body['url']! as String,
            body['key']! as String,
          );
          url = config.endpoint.toString();
          publicKey = config.publicKey;
        }
      }
    } catch (_) {
      status = 'Настройки облака не прочитаны. Введите их заново.';
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool automatic = false,
  }) async {
    if (busy || _disposed) return;
    _cancelAuto();
    busy = true;
    notifyListeners();
    var failed = false;
    try {
      await action();
    } on SyncUnlockError catch (e) {
      failed = true;
      preview = null;
      _password = null;
      _sessionPassword = null;
      if (automaticEnabled) _automaticBlocked = true;
      status = userError(e);
    } on CloudChanged {
      failed = true;
      preview = null;
      _password = null;
      status = 'Облако изменилось на другом устройстве. Повторите проверку.';
    } catch (e) {
      failed = true;
      status = userError(e);
    } finally {
      busy = false;
      if (!_disposed) {
        if (!signedIn) {
          _sessionPassword = null;
          if (automaticEnabled) _automaticBlocked = true;
        }
        if (failed && automatic) {
          _failures++;
          const delays = [5, 15, 60, 300];
          final seconds = delays[(_failures - 1).clamp(0, delays.length - 1)];
          if (automaticReady) {
            status =
                '$status Повтор через $seconds сек., пока приложение открыто.';
            _queueAuto(Duration(seconds: seconds));
          }
        } else if (automaticReady) {
          _failures = 0;
          _queueAuto(
            _autoAgain
                ? const Duration(seconds: 2)
                : const Duration(seconds: 60),
          );
        }
        _autoAgain = false;
        notifyListeners();
      }
    }
  }

  Future<void> signIn(
    String endpoint,
    String key,
    String email,
    String password,
  ) => _run(() async {
    _sessionPassword = null;
    automaticEnabled = false;
    _automaticBlocked = false;
    final config = CloudConfig(endpoint, key);
    final remote = SupabaseSnapshotRemote(config, transport: transport);
    await remote.signIn(email, password);
    if (_disposed) {
      remote.lock();
      return;
    }
    if (preferences != null) {
      final temporary = File('${preferences!.path}.tmp');
      try {
        await temporary.writeAsString(
          jsonEncode({
            'url': config.endpoint.toString(),
            'key': config.publicKey,
          }),
          flush: true,
        );
        await temporary.rename(preferences!.path);
      } catch (_) {
        remote.lock();
        rethrow;
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    _remote?.lock();
    _remote = remote;
    _sync = SyncService(vm.repository, vm.backup!, remote);
    url = config.endpoint.toString();
    publicKey = config.publicKey;
    preview = null;
    _password = null;
    status = 'Вход выполнен. Проверьте данные перед обменом.';
  });
  Future<void> check(String password) => _run(() async {
    preview = null;
    _password = null;
    final plan = await _sync!.preview(password);
    if (_disposed) return;
    preview = plan;
    _password = password;
    status = plan.needsChoice
        ? 'Нужен выбор версии. Обмен остановлен.'
        : 'Проверка завершена. Можно выполнить обмен.';
  });
  Future<void> commit({SyncChoice? choice}) => _run(() async {
    final plan = preview;
    final password = _password;
    if (plan == null || password == null) return;
    // A stale preview must be checked again even when the error is not a CAS race.
    preview = null;
    _password = null;
    await _sync!.commit(plan, password, choice: choice);
    if (_disposed) return;
    if (automaticEnabled) {
      _sessionPassword = password;
      _automaticBlocked = false;
    }
    await vm.refresh();
    lastSuccess = await vm.repository.lastSyncAt();
    status = 'Обмен завершён. Локальные данные и облачная копия согласованы.';
  });
  Future<void> signOut() => _run(() async {
    _sessionPassword = null;
    automaticEnabled = false;
    _automaticBlocked = false;
    preview = null;
    _password = null;
    try {
      await _remote?.signOut();
    } finally {
      _remote = null;
      _sync = null;
      status = 'Вы вышли. Данные остаются на устройстве.';
    }
  });
  void forgetPreview() {
    preview = null;
    _password = null;
    if (!busy && automaticReady) _queueAuto(const Duration(seconds: 60));
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAuto();
    vm.removeListener(_financeChanged);
    vm.insights.removeListener(_analysisChanged);
    _remote?.lock();
    _password = null;
    _sessionPassword = null;
    super.dispose();
  }
}
