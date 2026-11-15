import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cloud_credentials.dart';

class NativeCloudCredentialStore implements CloudCredentialStore {
  const NativeCloudCredentialStore({
    this.key = 'aprifinance.cloud.credentials.v1',
  });
  final String key;
  // This application does not share keys with other apps. The macOS login
  // Keychain also works for ad hoc builds without a provisioning profile.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(
      usesDataProtectionKeychain: false,
      accountName: 'com.bahadur.personalFinance.cloud',
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );
  @override
  Future<String?> read() => _storage.read(key: key);
  @override
  Future<void> write(String value) async {
    await _storage.write(key: key, value: value);
    if (await _storage.read(key: key) != value) {
      throw StateError('Protected storage did not retain the connection');
    }
  }

  @override
  Future<void> delete() async {
    await _storage.delete(key: key);
    if (await _storage.read(key: key) != null) {
      throw StateError('Protected storage did not remove the connection');
    }
  }
}
