import 'dart:async';

import 'package:personal_finance/data/cloud_credentials.dart';
import 'package:personal_finance/data/cloud_transport.dart';
import 'package:personal_finance/domain/models.dart';
import 'package:personal_finance/ui/cloud_controller.dart';

const fixtureCloudUser = '12345678-1234-4234-8234-123456789abc';
const fixtureCloudKey = 'sb_publishable_fictional_key_123456';
CloudConfig fixtureCloudConfig() =>
    CloudConfig('https://project.supabase.co', fixtureCloudKey);

class MemoryCredentials implements CloudCredentialStore {
  String? value;
  bool failRead = false, failWrite = false, failDelete = false;
  final writes = <String>[];
  Completer<void>? holdWrite;
  Completer<void>? holdRead;
  @override
  Future<String?> read() async {
    final captured = value;
    final hold = holdRead;
    holdRead = null;
    if (hold != null) await hold.future;
    if (failRead) throw StateError('fictional protected store locked');
    return captured;
  }

  @override
  Future<void> write(String value) async {
    final hold = holdWrite;
    holdWrite = null;
    if (hold != null) await hold.future;
    if (failWrite) throw StateError('fictional protected store locked');
    writes.add(value);
    this.value = value;
  }

  @override
  Future<void> delete() async {
    if (failDelete) throw StateError('fictional delete denied');
    value = null;
  }
}

class RememberedCloud implements CloudTransport {
  String userId = fixtureCloudUser;
  bool offline = false, rejectLogin = false, rejectAccess = false;
  String? payload;
  int revision = 0, logins = 0, refreshes = 0, reads = 0, writes = 0;
  @override
  Future<CloudReply> request(
    Uri uri,
    String method,
    Map<String, String> headers,
    Object? body,
  ) async {
    if (offline) throw const DomainError('Нет сети');
    if (uri.path == '/auth/v1/token') {
      final refresh = uri.queryParameters['grant_type'] == 'refresh_token';
      if (refresh) {
        refreshes++;
      } else {
        logins++;
      }
      if (rejectLogin) {
        return const CloudReply(400, {'message': 'fictional auth denied'});
      }
      return CloudReply(200, {
        'access_token': 'fictional-access-$refreshes',
        'refresh_token': 'fictional-refresh-$refreshes',
        'expires_in': 3600,
        'user': {'id': userId, 'email': 'owner@example.invalid'},
      });
    }
    if (uri.path == '/auth/v1/logout') return const CloudReply(204, null);
    if (rejectAccess) return const CloudReply(401, null);
    if (method == 'GET') {
      reads++;
      return CloudReply(
        200,
        payload == null
            ? <Object?>[]
            : [
                {'revision': revision, 'payload': payload},
              ],
      );
    }
    if (uri.path == '/rest/v1/rpc/put_finance_snapshot_v2') {
      final input = body! as Map;
      if (input['expected_revision'] != revision) {
        return const CloudReply(400, {'message': 'SYNC_CONFLICT'});
      }
      payload = input['encrypted_payload']! as String;
      writes++;
      return CloudReply(200, ++revision);
    }
    throw StateError('Unexpected fictional endpoint');
  }
}

class RememberedSchedule {
  Duration? delay;
  void Function()? task;
  CancelScheduledSync schedule(Duration delay, void Function() task) {
    this.delay = delay;
    this.task = task;
    return () {
      if (identical(this.task, task)) {
        this.task = null;
        this.delay = null;
      }
    };
  }

  void fire() {
    final action = task!;
    task = null;
    delay = null;
    action();
  }
}
