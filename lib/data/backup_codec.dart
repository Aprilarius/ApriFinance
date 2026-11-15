import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/backup_data.dart';
import '../domain/models.dart';

abstract final class BackupCodec {
  static const maxFileBytes = 48 * 1024 * 1024;
  static const _maxPlainBytes = 32 * 1024 * 1024;
  static const _iterations = 600000;
  static const _aad = 'my-finances:1:pbkdf2-sha256:600000:aes-256-gcm';
  static final _aes = AesGcm.with256bits();

  static Future<SecretKey> _key(String password, List<int> salt) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Uint8List> encrypt(BackupData data, String password) async {
    if (password.length < 10 || password.length > 256) {
      throw const DomainError(
        'Пароль копии должен содержать от 10 до 256 символов',
      );
    }
    final plain = utf8.encode(jsonEncode(data.toJson()));
    if (plain.length > _maxPlainBytes) {
      throw const DomainError(
        'Данные слишком велики для этой версии резервного копирования',
      );
    }
    final random = Random.secure();
    final salt = List.generate(16, (_) => random.nextInt(256));
    final key = await _key(password, salt);
    final box = await _aes.encrypt(
      plain,
      secretKey: key,
      aad: utf8.encode(_aad),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'my-finances-encrypted',
          'version': 1,
          'kdf': 'pbkdf2-sha256',
          'iterations': _iterations,
          'cipher': 'aes-256-gcm',
          'salt': base64Encode(salt),
          'nonce': base64Encode(box.nonce),
          'tag': base64Encode(box.mac.bytes),
          'data': base64Encode(box.cipherText),
        }),
      ),
    );
  }

  static Future<BackupData> decrypt(Uint8List bytes, String password) async {
    if (bytes.length > maxFileBytes || bytes.isEmpty) {
      throw const DomainError('Недопустимый размер файла копии');
    }
    if (password.isEmpty || password.length > 256) {
      throw const DomainError('Введите пароль копии');
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map ||
          value['format'] != 'my-finances-encrypted' ||
          value['version'] != 1 ||
          value['kdf'] != 'pbkdf2-sha256' ||
          value['iterations'] != _iterations ||
          value['cipher'] != 'aes-256-gcm') {
        throw const DomainError('Формат копии не поддерживается');
      }
      final salt = base64Decode(value['salt'] as String);
      final nonce = base64Decode(value['nonce'] as String);
      final tag = base64Decode(value['tag'] as String);
      final cipher = base64Decode(value['data'] as String);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          tag.length != 16 ||
          cipher.length > _maxPlainBytes) {
        throw const DomainError('Файл копии повреждён');
      }
      final key = await _key(password, salt);
      final plain = await _aes.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
        aad: utf8.encode(_aad),
      );
      return BackupData.fromJson(jsonDecode(utf8.decode(plain)));
    } on DomainError {
      rethrow;
    } catch (_) {
      throw const DomainError('Неверный пароль или файл копии повреждён');
    }
  }
}
