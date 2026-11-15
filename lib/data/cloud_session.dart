import '../domain/models.dart';

class CloudSession {
  const CloudSession({
    required this.userId,
    required this.email,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });
  final String userId, email, accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  static bool validId(String id) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(id);
  bool get canRemember => refreshToken != null && expiresAt != null;
  Map<String, Object?> toJson() => {
    'userId': userId,
    'email': email,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
  };

  factory CloudSession.fromJson(Map<String, dynamic> json) {
    final id = json['userId'],
        email = json['email'],
        token = json['accessToken'],
        refresh = json['refreshToken'],
        expiry = json['expiresAt'];
    final at = expiry is String ? DateTime.tryParse(expiry) : null;
    final tokenCharacters = RegExp(r'^[A-Za-z0-9._~+/=-]+$');
    if (id is! String ||
        !validId(id) ||
        email is! String ||
        email.length > 320 ||
        token is! String ||
        token.isEmpty ||
        token.length > 32768 ||
        !tokenCharacters.hasMatch(token) ||
        (refresh != null &&
            (refresh is! String ||
                refresh.isEmpty ||
                refresh.length > 8192 ||
                !tokenCharacters.hasMatch(refresh))) ||
        (expiry != null && at == null)) {
      throw const DomainError('Сохранённый вход повреждён. Войдите снова.');
    }
    return CloudSession(
      userId: id,
      email: email,
      accessToken: token,
      refreshToken: refresh as String?,
      expiresAt: at,
    );
  }

  factory CloudSession.fromAuth(
    Object? body,
    DateTime now, {
    String email = '',
  }) {
    if (body is! Map || body['user'] is! Map) {
      throw const DomainError('Облако вернуло некорректную сессию');
    }
    final expiry = body['expires_at'], lifetime = body['expires_in'];
    DateTime? at;
    if (expiry is int && expiry > 0 && expiry < 253402300800) {
      at = DateTime.fromMillisecondsSinceEpoch(expiry * 1000, isUtc: true);
    } else if (lifetime is int && lifetime > 0 && lifetime <= 604800) {
      at = now.toUtc().add(Duration(seconds: lifetime));
    }
    return CloudSession.fromJson({
      'userId': (body['user'] as Map)['id'],
      'email': (body['user'] as Map)['email'] ?? email,
      'accessToken': body['access_token'],
      'refreshToken': body['refresh_token'],
      'expiresAt': at?.toIso8601String(),
    });
  }
}
