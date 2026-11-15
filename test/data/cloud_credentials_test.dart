import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/cloud_credentials.dart';
import 'package:personal_finance/data/cloud_session.dart';
import 'package:personal_finance/data/cloud_transport.dart';

void main() {
  CloudCredentials fixture() => CloudCredentials(
    config: CloudConfig(
      'https://project.supabase.co',
      'sb_publishable_fictional_test_key',
    ),
    userId: '11111111-1111-4111-8111-111111111111',
    email: 'fixture@example.invalid',
    session: CloudSession(
      userId: '11111111-1111-4111-8111-111111111111',
      email: 'fixture@example.invalid',
      accessToken: 'fixture-access',
      refreshToken: 'fixture-refresh',
      expiresAt: DateTime.utc(2026, 11, 16),
    ),
    copyPassword: 'fictional-copy-password',
  );
  test('protected record round trips and never needs the account password', () {
    final record = fixture();
    final restored = CloudCredentials.decode(record.encode());
    expect(restored.encode(), record.encode());
    expect(restored.copyPassword, 'fictional-copy-password');
    expect(jsonDecode(record.encode()) as Map, isNot(contains('password')));
    expect(
      record.withAutomatic(false).session!.refreshToken,
      'fixture-refresh',
    );
    expect(record.withSession(null).copyPassword, record.copyPassword);
  });
  test(
    'corrupt owner, unsupported version and administrative key are rejected',
    () {
      final source = jsonDecode(fixture().encode()) as Map<String, dynamic>;
      for (final change in [
        {'version': 2},
        {'userId': '22222222-2222-4222-8222-222222222222'},
        {'key': 'sb_secret_not_for_apps'},
        {'copyPassword': 'short'},
      ]) {
        expect(
          () => CloudCredentials.decode(jsonEncode({...source, ...change})),
          throwsA(anything),
        );
      }
      expect(() => CloudCredentials.decode('x' * 65537), throwsA(anything));
    },
  );
  test('tokens without refresh information cannot be remembered', () {
    final source = jsonDecode(fixture().encode()) as Map<String, dynamic>;
    (source['session'] as Map)['refreshToken'] = null;
    expect(
      () => CloudCredentials.decode(jsonEncode(source)),
      throwsA(anything),
    );
  });
}
