import 'dart:convert';

import '../domain/models.dart';
import 'cloud_session.dart';
import 'cloud_transport.dart';

abstract interface class CloudCredentialStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class CloudCredentials {
  CloudCredentials({
    required this.config,
    required this.userId,
    required this.email,
    this.session,
    this.copyPassword,
    this.automatic = true,
  });
  final CloudConfig config;
  final String userId, email;
  final CloudSession? session;
  final String? copyPassword;
  final bool automatic;

  CloudCredentials withSession(CloudSession? value) => CloudCredentials(
    config: config,
    userId: userId,
    email: email,
    session: value,
    copyPassword: copyPassword,
    automatic: automatic,
  );
  CloudCredentials withCopyPassword(String? value) => CloudCredentials(
    config: config,
    userId: userId,
    email: email,
    session: session,
    copyPassword: value,
    automatic: automatic,
  );
  CloudCredentials withAutomatic(bool value) => CloudCredentials(
    config: config,
    userId: userId,
    email: email,
    session: session,
    copyPassword: copyPassword,
    automatic: value,
  );

  String encode() => jsonEncode({
    'version': 1,
    'url': config.endpoint.toString(),
    'key': config.publicKey,
    'userId': userId,
    'email': email,
    'session': session?.toJson(),
    'copyPassword': copyPassword,
    'automatic': automatic,
  });
  factory CloudCredentials.decode(String value) {
    if (utf8.encode(value).length > 65536) {
      throw const DomainError('Сохранённое подключение повреждено');
    }
    final j = jsonDecode(value) as Map<String, dynamic>;
    final id = j['userId'], email = j['email'], password = j['copyPassword'];
    final session = j['session'] == null
        ? null
        : CloudSession.fromJson(Map<String, dynamic>.from(j['session'] as Map));
    if (j['version'] != 1 ||
        id is! String ||
        !CloudSession.validId(id) ||
        email is! String ||
        email.length > 320 ||
        j['automatic'] is! bool ||
        (password != null &&
            (password is! String ||
                password.length < 10 ||
                password.length > 256)) ||
        (session != null && (!session.canRemember || session.userId != id))) {
      throw const DomainError('Сохранённое подключение повреждено');
    }
    return CloudCredentials(
      config: CloudConfig(j['url'] as String, j['key'] as String),
      userId: id,
      email: email,
      session: session,
      copyPassword: password as String?,
      automatic: j['automatic'] as bool,
    );
  }
}
