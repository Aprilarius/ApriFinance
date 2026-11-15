import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/models.dart';
import 'backup_codec.dart';
import 'cloud_session.dart';

class CloudReply {
  const CloudReply(this.status, this.body);
  final int status;
  final Object? body;
}

abstract interface class CloudTransport {
  Future<CloudReply> request(
    Uri uri,
    String method,
    Map<String, String> headers,
    Object? body,
  );
}

/// Each request has a total deadline, a bounded body, and never follows redirects
/// carrying authentication headers. No request/response logging.
class IoCloudTransport implements CloudTransport {
  const IoCloudTransport();
  @override
  Future<CloudReply> request(
    Uri uri,
    String method,
    Map<String, String> headers,
    Object? body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final max = BackupCodec.maxFileBytes + 1024 * 1024;
        if (response.contentLength > max) {
          throw const DomainError('Ответ облака слишком большой');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > max) {
            throw const DomainError('Ответ облака слишком большой');
          }
          bytes.add(chunk);
        }
        final text = utf8.decode(bytes.takeBytes());
        return CloudReply(
          response.statusCode,
          text.isEmpty ? null : jsonDecode(text),
        );
      })().timeout(const Duration(seconds: 45));
    } on DomainError {
      rethrow;
    } catch (_) {
      throw const DomainError(
        'Облако недоступно. Проверьте подключение и повторите. Локальные данные сохранены.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class CloudConfig {
  CloudConfig(String url, String key)
    : endpoint = _endpoint(url),
      publicKey = _publicKey(key);
  final Uri endpoint;
  final String publicKey;
  static Uri _endpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['', '/'].contains(uri.path) ||
        !RegExp(r'^[a-z0-9-]+\.supabase\.co$').hasMatch(uri.host)) {
      throw const DomainError(
        'Укажите HTTPS URL проекта вида https://project.supabase.co',
      );
    }
    return uri.replace(path: '');
  }

  static String _publicKey(String input) {
    final key = input.trim();
    if (RegExp(r'^sb_publishable_[A-Za-z0-9_-]{10,200}$').hasMatch(key)) {
      return key;
    }
    try {
      final parts = key.split('.');
      if (parts.length == 3 &&
          key.length <= 4000 &&
          !RegExp(r'\s').hasMatch(key)) {
        final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (claims is Map && claims['role'] == 'anon') return key;
      }
    } catch (_) {
      /* Reject malformed keys without printing them. */
    }
    throw const DomainError(
      'Нужен publishable или anon ключ. Административные и secret ключи не допускаются.',
    );
  }
}

class RemoteSnapshot {
  const RemoteSnapshot(this.revision, this.payload);
  final int revision;
  final String payload;
}

abstract interface class SnapshotRemote {
  String get scope;
  Future<RemoteSnapshot?> read();
  Future<int> write(int expectedRevision, String payload);
}

class CloudChanged implements Exception {
  const CloudChanged();
}

class SupabaseSnapshotRemote implements SnapshotRemote {
  SupabaseSnapshotRemote(
    this.config, {
    CloudTransport? transport,
    DateTime Function()? clock,
    this.onSessionChanged,
  }) : transport = transport ?? const IoCloudTransport(),
       clock = clock ?? DateTime.now;
  final CloudConfig config;
  final CloudTransport transport;
  final DateTime Function() clock;
  final Future<void> Function(CloudSession? session)? onSessionChanged;
  CloudSession? _session;
  CloudSession? _pendingSession;
  Future<void>? _refreshing;
  int _generation = 0;
  CloudSession? get session => _session;
  bool get signedIn => _session != null;
  @override
  String get scope {
    if (_session == null) {
      throw const DomainError('Сначала войдите в облачный аккаунт');
    }
    return '${config.endpoint}|${_session!.userId}';
  }

  void restoreSession(CloudSession value) {
    if (!value.canRemember) {
      throw const DomainError('Сохранённый вход устарел. Войдите снова.');
    }
    lock();
    _session = CloudSession.fromJson(value.toJson());
  }

  Future<void> _invalidate() async {
    lock();
    await onSessionChanged?.call(null);
  }

  Future<void> _refresh() async {
    final existing = _refreshing;
    if (existing != null) return existing;
    final work = _performRefresh();
    _refreshing = work;
    try {
      await work;
    } finally {
      if (identical(_refreshing, work)) _refreshing = null;
    }
  }

  Future<void> _performRefresh() async {
    final pending = _pendingSession;
    if (pending != null) {
      final generation = _generation;
      await onSessionChanged?.call(pending);
      if (generation != _generation) {
        throw const DomainError('Подключение изменилось');
      }
      _session = pending;
      _pendingSession = null;
      return;
    }
    final previous = _session;
    if (previous?.refreshToken == null) {
      await _invalidate();
      throw const DomainError('Сессия истекла. Войдите снова.');
    }
    final generation = _generation;
    final reply = await _call(
      '/auth/v1/token?grant_type=refresh_token',
      'POST',
      authenticated: false,
      body: {'refresh_token': previous!.refreshToken},
    );
    if (generation != _generation) {
      throw const DomainError('Подключение изменилось');
    }
    if (reply.status == 400 || reply.status == 401) {
      await _invalidate();
      throw const DomainError(
        'Войдите в аккаунт снова. Локальные данные сохранены.',
      );
    }
    if (reply.status != 200) {
      throw const DomainError(
        'Не удалось обновить вход. Повторим при подключении к сети.',
      );
    }
    late final CloudSession next;
    try {
      next = CloudSession.fromAuth(reply.body, clock(), email: previous.email);
    } catch (_) {
      await _invalidate();
      throw const DomainError(
        'Облако вернуло некорректную сессию. Войдите снова.',
      );
    }
    if (!next.canRemember || next.userId != previous.userId) {
      await _invalidate();
      throw const DomainError('Облако вернуло некорректную сессию');
    }
    // Rotation must be saved before another authenticated operation starts.
    _pendingSession = next;
    await onSessionChanged?.call(next);
    if (generation != _generation) {
      throw const DomainError('Подключение изменилось');
    }
    _session = next;
    _pendingSession = null;
  }

  Future<CloudReply> _call(
    String path,
    String method, {
    Object? body,
    bool authenticated = true,
  }) async {
    if (authenticated && !signedIn) {
      throw const DomainError('Войдите в облачный аккаунт');
    }
    if (authenticated && _pendingSession != null) await _refresh();
    if (authenticated &&
        _session!.expiresAt != null &&
        !_session!.expiresAt!.isAfter(
          clock().toUtc().add(const Duration(seconds: 30)),
        )) {
      await _refresh();
    }
    final generation = _generation;
    Future<CloudReply> request() =>
        transport.request(config.endpoint.resolve(path), method, {
          'apikey': config.publicKey,
          if (authenticated) 'Authorization': 'Bearer ${_session!.accessToken}',
        }, body);
    var reply = await request();
    if (generation != _generation) {
      throw const DomainError('Подключение изменилось');
    }
    if (authenticated &&
        reply.status == 401 &&
        _session?.refreshToken != null) {
      await _refresh();
      reply = await request();
      if (generation != _generation) {
        throw const DomainError('Подключение изменилось');
      }
    }
    if (authenticated && reply.status == 401) {
      await _invalidate();
      throw const DomainError('Сессия истекла. Войдите снова.');
    }
    return reply;
  }

  Future<void> signIn(String email, String password) async {
    lock();
    final generation = _generation;
    final reply = await _call(
      '/auth/v1/token?grant_type=password',
      'POST',
      authenticated: false,
      body: {'email': email.trim(), 'password': password},
    );
    if (generation != _generation) {
      throw const DomainError('Подключение изменилось');
    }
    if (reply.status != 200) {
      throw const DomainError(
        'Не удалось войти. Проверьте аккаунт, пароль и настройки проекта.',
      );
    }
    _session = CloudSession.fromAuth(reply.body, clock(), email: email.trim());
  }

  void lock() {
    _generation++;
    _session = null;
    _pendingSession = null;
  }

  Future<void> signOut() async {
    final previous = _session;
    await _invalidate();
    if (previous == null) return;
    await transport.request(
      config.endpoint.resolve('/auth/v1/logout?scope=local'),
      'POST',
      {
        'apikey': config.publicKey,
        'Authorization': 'Bearer ${previous.accessToken}',
      },
      null,
    );
  }

  @override
  Future<RemoteSnapshot?> read() async {
    final reply = await _call(
      '/rest/v1/finance_snapshots?select=revision,payload&limit=1',
      'GET',
    );
    if (reply.status != 200 || reply.body is! List) {
      throw const DomainError(
        'Не удалось прочитать облако. Проверьте установку SQL и права доступа.',
      );
    }
    final rows = reply.body! as List;
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw const DomainError('Облако вернуло больше одной базы');
    }
    final row = rows.single;
    if (row is! Map ||
        row['revision'] is! int ||
        (row['revision']! as int) < 1 ||
        row['payload'] is! String ||
        (row['payload']! as String).length > BackupCodec.maxFileBytes) {
      throw const DomainError('Некорректный ответ облака');
    }
    return RemoteSnapshot(row['revision']! as int, row['payload']! as String);
  }

  @override
  Future<int> write(int expectedRevision, String payload) async {
    final reply = await _call(
      '/rest/v1/rpc/put_finance_snapshot_v2',
      'POST',
      body: {
        'expected_revision': expectedRevision,
        'encrypted_payload': payload,
      },
    );
    final body = reply.body;
    if (body is Map && body['message'] == 'SYNC_CONFLICT') {
      throw const CloudChanged();
    }
    if (body is Map && body['message'] == 'CLIENT_UPGRADE_REQUIRED') {
      throw const DomainError(
        'Обновите ApriFinance на всех устройствах до сборки 20 или новее.',
      );
    }
    if (body is Map && body['code'] == 'PGRST202') {
      throw const DomainError(
        'Установите актуальную SQL-схему синхронизации в проекте Supabase.',
      );
    }
    if (reply.status != 200 || body is! int || body != expectedRevision + 1) {
      throw const DomainError(
        'Отправка не подтверждена. Повторите проверку облака; данные на устройстве сохранены.',
      );
    }
    return body;
  }
}
