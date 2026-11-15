import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/data/cloud_session.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/domain/models.dart';

import 'cloud_transport_test.dart' show FakeCloudTransport, testKey, testUser;

void main() {
  final now = DateTime.utc(2026, 11, 15, 10);
  CloudSession original({bool expired = true}) => CloudSession(
    userId: testUser,
    email: 'fictional@example.invalid',
    accessToken: 'old-token',
    refreshToken: 'old-refresh',
    expiresAt: now.add(Duration(minutes: expired ? -5 : 50)),
  );
  CloudReply refreshed({String user = testUser}) => CloudReply(200, {
    'access_token': 'new-token',
    'refresh_token': 'new-refresh',
    'expires_in': 3600,
    'user': {'id': user, 'email': 'fictional@example.invalid'},
  });
  SupabaseSnapshotRemote remote(
    FakeCloudTransport t, {
    Future<void> Function(CloudSession?)? save,
    bool expired = true,
  }) => SupabaseSnapshotRemote(
    CloudConfig('https://project.supabase.co', testKey),
    transport: t,
    clock: () => now,
    onSessionChanged: save,
  )..restoreSession(original(expired: expired));

  test('expired remembered login rotates and saves refresh token before reading finance', () async {
    final t = FakeCloudTransport()
      ..replies.addAll([refreshed(), const CloudReply(200, [])]);
    final saved = <CloudSession?>[];
    final r = remote(
      t,
      save: (s) async {
        saved.add(s);
      },
    );
    expect(await r.read(), isNull);
    expect(t.requests.first.uri.queryParameters['grant_type'], 'refresh_token');
    expect(t.requests.first.body, {'refresh_token': 'old-refresh'});
    expect(saved.single!.refreshToken, 'new-refresh');
    expect(t.requests.last.headers['Authorization'], 'Bearer new-token');
    expect(r.session!.expiresAt, now.add(const Duration(hours: 1)));
  });
  test(
    'parallel callers coalesce refresh and wait for protected storage',
    () async {
      final t = FakeCloudTransport()
        ..replies.addAll([
          refreshed(),
          const CloudReply(200, []),
          const CloudReply(200, []),
        ]);
      final saved = Completer<void>();
      var saves = 0;
      final r = remote(
        t,
        save: (_) async {
          saves++;
          await saved.future;
        },
      );
      final a = r.read(), b = r.read();
      await Future<void>.delayed(Duration.zero);
      expect(t.requests.length, 1);
      expect(saves, 1);
      saved.complete();
      await Future.wait([a, b]);
      expect(
        t.requests.where((x) => x.uri.path == '/auth/v1/token'),
        hasLength(1),
      );
      expect(
        t.requests
            .skip(1)
            .every((x) => x.headers['Authorization'] == 'Bearer new-token'),
        isTrue,
      );
    },
  );
  test('401 refreshes once and retries using a fresh access token', () async {
    final t = FakeCloudTransport()
      ..replies.addAll([
        const CloudReply(401, null),
        refreshed(),
        const CloudReply(200, []),
      ]);
    final r = remote(t, expired: false);
    expect(await r.read(), isNull);
    expect(t.requests, hasLength(3));
    expect(t.requests.last.headers['Authorization'], 'Bearer new-token');
  });
  test('second 401 invalidates saved session without looping', () async {
    final t = FakeCloudTransport()
      ..replies.addAll([
        const CloudReply(401, null),
        refreshed(),
        const CloudReply(401, null),
      ]);
    final saved = <CloudSession?>[];
    final r = remote(
      t,
      expired: false,
      save: (s) async {
        saved.add(s);
      },
    );
    await expectLater(r.read(), throwsA(isA<DomainError>()));
    expect(r.signedIn, isFalse);
    expect(saved.last, isNull);
    expect(t.requests, hasLength(3));
  });
  test(
    'temporary refresh failure preserves credentials for an offline retry',
    () async {
      final t = FakeCloudTransport()
        ..replies.addAll([
          const CloudReply(503, null),
          refreshed(),
          const CloudReply(200, []),
        ]);
      final saved = <CloudSession?>[];
      final r = remote(
        t,
        save: (s) async {
          saved.add(s);
        },
      );
      await expectLater(r.read(), throwsA(isA<DomainError>()));
      expect(r.session!.refreshToken, 'old-refresh');
      expect(saved, isEmpty);
      expect(await r.read(), isNull);
      expect(r.session!.refreshToken, 'new-refresh');
    },
  );
  test(
    'rejected refresh or a different owner cannot restore a session',
    () async {
      for (final reply in [
        const CloudReply(400, {'message': 'private detail'}),
        refreshed(user: '44444444-4444-4444-8444-444444444444'),
      ]) {
        final t = FakeCloudTransport()..replies.add(reply);
        final saved = <CloudSession?>[];
        final r = remote(
          t,
          save: (s) async {
            saved.add(s);
          },
        );
        await expectLater(r.read(), throwsA(isA<DomainError>()));
        expect(r.signedIn, isFalse);
        expect(saved, [null]);
        expect(t.requests, hasLength(1));
      }
    },
  );
  test('rotated token survives a failed vault save and is retried before any data request', () async {
    final t = FakeCloudTransport()
      ..replies.addAll([refreshed(), const CloudReply(200, [])]);
    var attempts = 0;
    final r = remote(
      t,
      save: (s) async {
        if (s != null && ++attempts == 1) {
          throw StateError('fictional vault locked');
        }
      },
    );
    await expectLater(r.read(), throwsStateError);
    expect(t.requests, hasLength(1));
    expect(await r.read(), isNull);
    expect(attempts, 2);
    expect(
      t.requests.where((x) => x.uri.path == '/auth/v1/token'),
      hasLength(1),
    );
    expect(r.session!.refreshToken, 'new-refresh');
  });
  test(
    'lock during token persistence cannot resurrect authentication',
    () async {
      final t = FakeCloudTransport()..replies.add(refreshed());
      final held = Completer<void>();
      final r = remote(t, save: (_) => held.future);
      final work = r.read();
      await Future<void>.delayed(Duration.zero);
      r.lock();
      held.complete();
      await expectLater(work, throwsA(isA<DomainError>()));
      expect(r.signedIn, isFalse);
      expect(t.requests, hasLength(1));
    },
  );
  test(
    'malformed refresh response expires auth without exposing server contents',
    () async {
      final t = FakeCloudTransport()
        ..replies.add(
          const CloudReply(200, {'access_token': 'private-token-fragment'}),
        );
      final r = remote(t);
      await expectLater(
        r.read(),
        throwsA(
          isA<DomainError>().having(
            (e) => e.message,
            'safe error',
            isNot(contains('private-token-fragment')),
          ),
        ),
      );
      expect(r.signedIn, isFalse);
    },
  );
}
