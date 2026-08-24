import 'dart:convert';

import 'package:http/http.dart' as http;

import 'test_env.dart';

/// Thin GoTrue Admin API wrapper (service_role) — the Dart twin of the C#
/// suite's `AdminApi`.
///
/// It creates PRE-CONFIRMED users, which is the whole point: the insert into
/// `auth.users` fires the REAL `handle_new_user` trigger (founder onboarding
/// from the metadata, invitee onboarding from `invite_token`) without any test
/// depending on a confirmation e-mail arriving. And it removes them at
/// teardown — `profiles.user_id` has no cascade, so users are deleted AFTER
/// `purge_e2e_family` has removed the public-schema rows.
///
/// Hand-built rather than driven through the SDK's `auth.admin`, for one
/// reason: these requests must control their own HEADER SHAPE (S-16 — see
/// [TestEnv.keyHeaders]), and a key format that has to be sent one way is
/// exactly the kind of thing a convenience wrapper decides for you.
class AdminApi {
  final http.Client _http = http.Client();

  Uri _uri(String path) => Uri.parse('${TestEnv.supabaseUrl}$path');

  Map<String, String> get _headers => {
        ...TestEnv.keyHeaders(TestEnv.serviceRoleKey),
        'Content-Type': 'application/json',
      };

  /// Returns the new user's id.
  Future<String> createConfirmedUser(
    String email,
    String password,
    Map<String, dynamic> metadata,
  ) async {
    final response = await _http.post(
      _uri('/auth/v1/admin/users'),
      headers: _headers,
      body: jsonEncode({
        'email': email,
        'password': password,
        'email_confirm': true,
        'user_metadata': metadata,
      }),
    );
    if (response.statusCode >= 300) {
      throw StateError("Admin create user '$email' failed "
          '(${response.statusCode}): ${response.body}');
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String;
  }

  /// F-16 tests: changes a user's e-mail as GoTrue itself would after the
  /// confirmation link — exercising the `profiles.email` sync trigger without a
  /// mailbox round-trip.
  Future<void> updateUserEmail(String userId, String newEmail) async {
    final response = await _http.put(
      _uri('/auth/v1/admin/users/$userId'),
      headers: _headers,
      body: jsonEncode({'email': newEmail, 'email_confirm': true}),
    );
    if (response.statusCode >= 300) {
      throw StateError('Admin update e-mail for $userId failed '
          '(${response.statusCode}): ${response.body}');
    }
  }

  /// Idempotent: a user already removed (404) is not an error.
  Future<void> deleteUser(String userId) async {
    final response =
        await _http.delete(_uri('/auth/v1/admin/users/$userId'), headers: _headers);
    if (response.statusCode >= 300 && response.statusCode != 404) {
      throw StateError(
          'Admin delete user $userId failed (${response.statusCode}).');
    }
  }

  void close() => _http.close();
}
