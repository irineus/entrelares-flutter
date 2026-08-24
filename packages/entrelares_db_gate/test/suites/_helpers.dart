import 'dart:math';

import 'package:test/test.dart';

/// Asserts that [action] is REJECTED by the database, optionally naming a
/// fragment of the message the user would see.
///
/// The C# suite spelled this `AssertRejectedAsync`, and it is worth keeping the
/// message check: several of these rules exist to produce a specific PT-BR
/// sentence the client turns into a screen, and a rule that fires with the
/// wrong reason is a different bug from one that does not fire at all.
///
/// It deliberately catches ANY error rather than `PostgrestException` alone: a
/// rejection can arrive from PostgREST (RLS, a trigger's RAISE) or from the RPC
/// layer, and which one it is is not part of the rule under test.
Future<void> expectRejected(
  Future<void> Function() action, {
  String? contains,
  bool caseInsensitive = false,
}) async {
  Object? caught;
  try {
    await action();
  } catch (error) {
    caught = error;
  }
  expect(caught, isNotNull, reason: 'the operation was NOT rejected');
  if (contains != null) {
    final message = caught.toString();
    final haystack = caseInsensitive ? message.toLowerCase() : message;
    final needle = caseInsensitive ? contains.toLowerCase() : contains;
    expect(haystack, stringContainsInOrder([needle]),
        reason: 'rejected, but not for the expected reason: $message');
  }
}

/// A per-assertion marker, so a row this run wrote can be told apart from
/// everything the shared QA project has ever accumulated.
String uniqueMarker() {
  final rng = Random.secure();
  return List.generate(16, (_) => rng.nextInt(16).toRadixString(16)).join();
}
