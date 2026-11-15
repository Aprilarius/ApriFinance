import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/domain/models.dart';

class FakeCloudTransport implements CloudTransport {
  final requests =
      <({Uri uri, String method, Map<String, String> headers, Object? body})>[];
  final replies = <CloudReply>[];
  @override
  Future<CloudReply> request(
    Uri uri,
    String method,
    Map<String, String> headers,
    Object? body,
  ) async {
    requests.add((uri: uri, method: method, headers: headers, body: body));
    return replies.removeAt(0);
  }
}

const testKey = 'sb_publishable_fictional_key_123456';
const testUser = '12345678-1234-1234-1234-123456789abc';
CloudReply loginReply() => const CloudReply(200, {
  'access_token': 'fictional-session',
  'user': {'id': testUser},
});

void main() {
  test('configuration rejects insecure endpoints and administrative keys', () {
    for (final url in [
      'http://project.supabase.co',
      'https://project.supabase.co.evil.com',
      'https://user:pass@project.supabase.co',
      'https://project.supabase.co/path',
      'https://project.supabase.co?x=y',
      'https://localhost',
    ]) {
      expect(() => CloudConfig(url, testKey), throwsA(isA<DomainError>()));
    }
    for (final key in [
      'sb_secret_fictional_key',
      'random',
      'head.${base64Url.encode(utf8.encode('{"role":"service_role"}'))}.signature',
    ]) {
      expect(
        () => CloudConfig('https://project.supabase.co', key),
        throwsA(isA<DomainError>()),
      );
    }
    expect(
      CloudConfig('https://project.supabase.co/', testKey).endpoint.toString(),
      'https://project.supabase.co',
    );
    final anon =
        'head.${base64Url.encode(utf8.encode('{"role":"anon"}'))}.signature';
    expect(CloudConfig('https://project.supabase.co', anon).publicKey, anon);
  });
  test('login and REST/RPC requests use verified session, server revision and expected contract', () async {
    final transport = FakeCloudTransport()
      ..replies.addAll([
        loginReply(),
        const CloudReply(200, [
          {'revision': 3, 'payload': 'encrypted'},
        ]),
        const CloudReply(200, 4),
      ]);
    final remote = SupabaseSnapshotRemote(
      CloudConfig('https://project.supabase.co', testKey),
      transport: transport,
    );
    await remote.signIn('owner@example.invalid', 'fictional-password');
    expect(transport.requests.first.uri.path, '/auth/v1/token');
    expect(
      transport.requests.first.headers.containsKey('Authorization'),
      isFalse,
    );
    expect(transport.requests.first.headers['apikey'], testKey);
    expect(remote.scope, contains(testUser));
    expect((await remote.read())!.revision, 3);
    expect(await remote.write(3, 'ciphertext'), 4);
    expect(transport.requests.last.body, {
      'expected_revision': 3,
      'encrypted_payload': 'ciphertext',
    });
    expect(
      transport.requests.last.headers['Authorization'],
      'Bearer fictional-session',
    );
    remote.lock();
    await expectLater(remote.read(), throwsA(isA<DomainError>()));
  });
  test('CAS conflict, expired session, malformed responses and auth errors are not mistaken for success', () async {
    final t = FakeCloudTransport()
      ..replies.addAll([
        loginReply(),
        const CloudReply(400, {'message': 'SYNC_CONFLICT'}),
        const CloudReply(401, null),
      ]);
    final remote = SupabaseSnapshotRemote(
      CloudConfig('https://project.supabase.co', testKey),
      transport: t,
    );
    await remote.signIn('a@example.invalid', 'fictional');
    await expectLater(
      remote.write(1, 'encrypted'),
      throwsA(isA<CloudChanged>()),
    );
    await expectLater(remote.read(), throwsA(isA<DomainError>()));
    expect(remote.signedIn, isFalse);
    t.replies.add(const CloudReply(400, {'message': 'private server detail'}));
    await expectLater(
      remote.signIn('a@example.invalid', 'bad'),
      throwsA(
        isA<DomainError>().having(
          (e) => e.message,
          'message',
          isNot(contains('private server detail')),
        ),
      ),
    );
    t.replies.addAll([
      loginReply(),
      const CloudReply(200, [
        {'revision': -1, 'payload': 'bad'},
      ]),
    ]);
    await remote.signIn('a@example.invalid', 'fictional');
    await expectLater(remote.read(), throwsA(isA<DomainError>()));
  });
  test(
    'sign out clears in-memory session even when network logout fails',
    () async {
      final t = FakeCloudTransport()
        ..replies.addAll([loginReply(), const CloudReply(503, null)]);
      final remote = SupabaseSnapshotRemote(
        CloudConfig('https://project.supabase.co', testKey),
        transport: t,
      );
      await remote.signIn('a@example.invalid', 'fictional');
      await remote.signOut();
      expect(remote.signedIn, isFalse);
      expect(() => remote.scope, throwsA(isA<DomainError>()));
    },
  );
}
