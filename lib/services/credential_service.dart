import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Securely stores and retrieves user credentials.
/// Uses the platform keychain (iOS) / keystore (Android).
class CredentialService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _keyUsername = 'cosmiq_username';
  static const _keyPassword = 'cosmiq_password';
  static const _keySessionId = 'cosmiq_session_id';

  /// Save login credentials
  static Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    await _storage.write(key: _keyUsername, value: username);
    await _storage.write(key: _keyPassword, value: password);
  }

  /// Get saved username
  static Future<String?> getUsername() async {
    return _storage.read(key: _keyUsername);
  }

  /// Get saved password
  static Future<String?> getPassword() async {
    return _storage.read(key: _keyPassword);
  }

  /// Check if credentials exist
  static Future<bool> hasCredentials() async {
    final username = await getUsername();
    final password = await getPassword();
    return username != null &&
        username.isNotEmpty &&
        password != null &&
        password.isNotEmpty;
  }

  /// Save PortaBilling session ID
  static Future<void> saveSessionId(String sessionId) async {
    await _storage.write(key: _keySessionId, value: sessionId);
  }

  /// Get saved session ID
  static Future<String?> getSessionId() async {
    return _storage.read(key: _keySessionId);
  }

  /// Clear all stored credentials (sign out)
  static Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
