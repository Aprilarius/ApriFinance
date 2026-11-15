import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/models.dart';
import 'backup_codec.dart';

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
  SupabaseSnapshotRemote(this.config, {CloudTransport? transport})
    : transport = transport ?? const IoCloudTransport();
  final CloudConfig config;
  final CloudTransport transport;
  String? _token, _userId;
  bool get signedIn => _token != null;
  @override
  String get scope {
    if (_userId == null) {
      throw const DomainError('Сначала войдите в облачный аккаунт');
    }
    return '${config.endpoint}|$_userId';
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
    final reply = await transport.request(
      config.endpoint.resolve(path),
      method,
      {
        'apikey': config.publicKey,
        if (authenticated) 'Authorization': 'Bearer $_token',
      },
      body,
    );
    if (authenticated && reply.status == 401) {
      lock();
      throw const DomainError('Сессия истекла. Войдите снова.');
    }
    return reply;
  }

  Future<void> signIn(String email, String password) async {
    lock();
    final reply = await _call(
      '/auth/v1/token?grant_type=password',
      'POST',
      authenticated: false,
      body: {'email': email.trim(), 'password': password},
    );
    final body = reply.body;
    if (reply.status != 200 ||
        body is! Map ||
        body['access_token'] is! String ||
        body['user'] is! Map) {
      throw const DomainError(
        'Не удалось войти. Проверьте аккаунт, пароль и настройки проекта.',
      );
    }
    final id = (body['user'] as Map)['id'];
    if (id is! String ||
        !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) ||
        (body['access_token']! as String).isEmpty) {
      throw const DomainError('Облако вернуло некорректную сессию');
    }
    _userId = id;
    _token = body['access_token']! as String;
    // Passwords and refresh tokens are deliberately never persisted.
  }

  void lock() {
    _token = null;
    _userId = null;
  }

  Future<void> signOut() async {
    try {
      if (signedIn) await _call('/auth/v1/logout?scope=local', 'POST');
    } finally {
      lock();
    }
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
