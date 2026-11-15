import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/cloud_transport.dart';
import '../data/finance_repository.dart';
import '../data/sync_service.dart';
import '../data/cloud_credentials.dart';
import '../data/cloud_defaults.dart';
import '../domain/models.dart';
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
    this.credentials,
    CloudConfig? configuredCloud,
    ScheduleSync? schedule,
  }) : _schedule = schedule ?? _scheduleTimer {
    final config = configuredCloud ?? defaultCloudConfig();
    url = config.endpoint.toString();
    publicKey = config.publicKey;
    vm.addListener(_financeChanged);
    vm.insights.addListener(_analysisChanged);
  }
  final FinanceViewModel vm;
  final File? preferences;
  final CloudTransport? transport;
  final CloudCredentialStore? credentials;
  CloudCredentials? _record;
  Future<void> _vaultWrites = Future.value();
  int _identityEpoch = 0;
  String email = '';
  bool get remembersConnection => credentials != null;
  bool get hasSavedCopy => _record?.copyPassword != null;
  bool _copyInvalid = false;
  bool get needsCopyPassword => !hasSavedCopy || _copyInvalid;
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

  Future<void> setAutomatic(bool enabled) async {
    if (busy || _disposed) return;
    _cancelAuto();
    automaticEnabled = enabled && signedIn;
    _automaticBlocked = false;
    _autoAgain = false;
    _failures = 0;
    if (!automaticEnabled && credentials == null) _sessionPassword = null;
    if (automaticEnabled && hasSavedCopy) {
      _sessionPassword = _record!.copyPassword;
    }
    status = automaticEnabled
        ? hasSavedCopy
              ? 'Автоматическая синхронизация включена.'
              : 'Откройте копию один раз, чтобы включить автоматический обмен.'
        : 'Автоматический обмен выключен. Доступен ручной обмен.';
    notifyListeners();
    if (automaticReady) _queueAuto(const Duration(seconds: 1));
    if (_record != null) {
      try {
        await _mutateRecord((r) => r?.withAutomatic(automaticEnabled));
      } catch (e) {
        status = userError(e);
        if (!_disposed) notifyListeners();
      }
    }
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
  Future<void> _saveRecord(CloudCredentials? value) =>
      _mutateRecord((_) => value);
  Future<void> _mutateRecord(
    CloudCredentials? Function(CloudCredentials?) update,
  ) async {
    if (credentials == null) return;
    final epoch = _identityEpoch;
    final work = _vaultWrites.then((_) async {
      if (epoch != _identityEpoch) return;
      final value = update(_record);
      final encoded = value?.encode();
      try {
        if (encoded == null) {
          await credentials!.delete();
        } else {
          await credentials!.write(encoded);
        }
      } catch (_) {
        throw const DomainError(
          'Не удалось обновить защищённое хранилище подключения. Повторите действие.',
        );
      }
      if (epoch == _identityEpoch && !_disposed) _record = value;
    });
    _vaultWrites = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await work;
  }

  SupabaseSnapshotRemote _makeRemote(CloudConfig config) {
    late final SupabaseSnapshotRemote remote;
    remote = SupabaseSnapshotRemote(
      config,
      transport: transport,
      onSessionChanged: (session) async {
        if (_disposed || !identical(_remote, remote) || _record == null) return;
        await _mutateRecord((r) => r?.withSession(session));
      },
    );
    return remote;
  }

  Future<void> initialize() async {
    final epoch = _identityEpoch;
    try {
      final last = await vm.repository.lastSyncAt();
      if (_disposed || epoch != _identityEpoch) return;
      lastSuccess = last;
      if (preferences != null && await preferences!.exists()) {
        final body = jsonDecode(await preferences!.readAsString());
        if (_disposed || epoch != _identityEpoch) return;
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
      if (_disposed || epoch != _identityEpoch) return;
      status = 'Прежние параметры подключения не прочитаны. Доступен встроенный проект.';
    }
    if (credentials != null) {
      try {
        final value = await credentials!.read();
        if (_disposed || epoch != _identityEpoch || value == null) return;
        final record = CloudCredentials.decode(value);
        _record = record;
        url = record.config.endpoint.toString();
        publicKey = record.config.publicKey;
        email = record.email;
        if (record.session == null) {
          status = 'Войдите снова, чтобы продолжить синхронизацию.';
          return;
        }
        final remote = _makeRemote(record.config)
          ..restoreSession(record.session!);
        _remote = remote;
        _sync = SyncService(vm.repository, vm.backup!, remote);
        automaticEnabled = record.automatic;
        _sessionPassword = record.copyPassword;
        status = hasSavedCopy
            ? 'Подключение восстановлено. Проверяем изменения.'
            : 'Вход сохранён. Откройте зашифрованную копию один раз.';
        if (automaticReady) _queueAuto(const Duration(seconds: 1));
      } catch (_) {
        if (_disposed || epoch != _identityEpoch) return;
        status = 'Не удалось открыть защищённое хранилище. Войдите снова или повторите после разблокировки устройства.';
      }
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
      _copyInvalid = true;
      if (_record != null && _record!.copyPassword != null) {
        try {
          await _mutateRecord((r) => r?.withCopyPassword(null));
        } catch (_) {
          /* Keep the mode paused even when the OS vault is locked. */
        }
      }
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
    _identityEpoch++;
    _sessionPassword = null;
    automaticEnabled = false;
    _automaticBlocked = false;
    _remote?.lock();
    _remote = null;
    _sync = null;
    preview = null;
    _password = null;
    final config = CloudConfig(endpoint, key);
    final remote = _makeRemote(config);
    await remote.signIn(email, password);
    if (_disposed) {
      remote.lock();
      return;
    }
    final session = remote.session!;
    final previous = _record;
    final sameOwner =
        previous != null &&
        previous.userId == session.userId &&
        previous.config.endpoint == config.endpoint;
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
    if (credentials != null) {
      if (!session.canRemember) {
        remote.lock();
        throw const DomainError(
          'Облако не вернуло сохраняемую сессию. Проверьте настройки входа.',
        );
      }
      try {
        await _saveRecord(
          CloudCredentials(
            config: config,
            userId: session.userId,
            email: session.email,
            session: session,
            copyPassword: sameOwner ? previous.copyPassword : null,
            automatic: sameOwner ? previous.automatic : true,
          ),
        );
      } catch (_) {
        remote.lock();
        rethrow;
      }
    }
    if (_disposed) {
      remote.lock();
      return;
    }
    _remote?.lock();
    _remote = remote;
    _sync = SyncService(vm.repository, vm.backup!, remote);
    url = config.endpoint.toString();
    publicKey = config.publicKey;
    this.email = session.email;
    _copyInvalid = false;
    preview = null;
    _password = null;
    if (credentials != null) {
      automaticEnabled = _record!.automatic;
      _sessionPassword = _record!.copyPassword;
    }
    status = hasSavedCopy
        ? 'Вход выполнен. Подключение восстановлено.'
        : 'Вход выполнен. Откройте зашифрованную копию один раз.';
    if (hasSavedCopy) _autoAgain = true;
  });

  Future<void> connectCopy(String password) async {
    if (password.length < 10 || password.length > 256 || busy || !signedIn) {
      return;
    }
    await check(password);
    if (!_disposed && preview != null && !preview!.needsChoice) await commit();
  }

  Future<void> synchronizeNow() async {
    final password = _record?.copyPassword ?? _sessionPassword;
    if (password == null || busy || !signedIn) return;
    await connectCopy(password);
  }

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
    if (_record != null) {
      await _mutateRecord(
        (r) => r?.withCopyPassword(password).withAutomatic(automaticEnabled),
      );
      _sessionPassword = password;
    }
    _copyInvalid = false;
    _automaticBlocked = false;
    if (automaticEnabled) {
      _sessionPassword = password;
      _automaticBlocked = false;
    }
    await vm.refresh();
    lastSuccess = await vm.repository.lastSyncAt();
    status = 'Всё синхронизировано.';
  });
  Future<void> signOut() => _run(() async {
    _sessionPassword = null;
    automaticEnabled = false;
    _automaticBlocked = false;
    preview = null;
    _password = null;
    _identityEpoch++;
    final remote = _remote;
    _remote = null;
    _sync = null;
    _record = null;
    email = '';
    try {
      await _saveRecord(null);
      await remote?.signOut();
      email = '';
      status = 'Вы вышли. Сохранённый вход удалён с устройства; финансовые записи сохранены.';
    } finally {
      remote?.lock();
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
    _identityEpoch++;
    _cancelAuto();
    vm.removeListener(_financeChanged);
    vm.insights.removeListener(_analysisChanged);
    _remote?.lock();
    _password = null;
    _sessionPassword = null;
    super.dispose();
  }
}
