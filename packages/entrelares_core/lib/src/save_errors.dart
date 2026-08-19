/// Client mirrors of the save/session error contracts — ported from
/// `entrelares-app` `CalendarHelpers.cs` (save-error translation, QA S-11 /
/// T-33 / T-35) plus the pilot's session-expiry mapping
/// (`entrelares-console` `lib/rules.dart`, F-58 QA lesson 1.2).
///
/// PostgREST wraps DB errors in a JSON body that used to be dumped raw at the
/// user. Known signatures get a meaningful PT-BR message; trigger-raised
/// messages (already PT-BR) pass through; anything else keeps the caller's
/// generic fallback. The substrings below are STABLE CONTRACTS with our own
/// triggers/constraints — change them only with the server.
library;

import 'dart:convert';

import 'localization/k_app.dart';
import 'localization/localization.dart';

/// True when the error is the UNIQUE(family, date) collision — another member
/// saved this day first (stale calendar race).
bool isUniqueDayConflict(String raw) =>
    raw.contains('23505') &&
    raw.contains('care_schedules_family_schedule_date_key');

/// T-33: true when the error is the optimistic-revision guard — a stale UPDATE
/// (the row changed since it was read). The message is our own trigger's, so
/// the substring is a stable contract.
bool isStaleDayConflict(String raw) => raw.contains('salvou este dia primeiro');

/// Any "someone got there first" day collision: the INSERT race (unique key)
/// or the UPDATE race (revision guard). Both recover the same way — reload,
/// rehydrate with the winner's version, explain.
bool isDayConflict(String raw) =>
    isUniqueDayConflict(raw) || isStaleDayConflict(raw);

/// T-35: true when the update was rejected for carrying NO concurrency echo —
/// the signature of a client build older than T-35. It must NOT be treated as
/// a day conflict: reloading the month cannot fix it, only reloading the APP
/// can, so the user gets that instruction instead of a retry loop.
bool isStaleClientBuild(String raw) => raw.contains('Recarregue o aplicativo');

/// F-58 QA lesson 1.2: without a valid session the client is `anon`, which in
/// this 100%-RLS product has no privilege at all (T-44) — `42501` reads like a
/// GRANT bug and is not. Map the signature to "sessão expirada" centrally.
bool isSessionExpired(String raw) =>
    raw.contains('42501') || raw.contains('permission denied');

/// U-13 port: the session-expired sentence now follows the reader's language.
String sessionExpiredMessage(Localization l) => l[KApp.sessionExpired];

const _accented = 'áâãàéêíóôõúçÁÂÃÉÊÍÓÔÕÚÇ';

/// Mirror of CalendarHelpers.TranslateSaveError. The two known-signature
/// messages come from the catalog since the U-13 port (the web helper never
/// extracted its literals — a residue frozen with the Blazor app); the
/// trigger-raised pass-through stays PT-BR-only because the SERVER writes
/// those sentences in PT-BR regardless of the reader.
String translateSaveError(String raw, String fallback, Localization l) {
  try {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start >= 0 && end > start) {
      final doc = jsonDecode(raw.substring(start, end + 1));
      if (doc is Map<String, dynamic>) {
        final code = doc['code'];
        final message = doc['message'];

        if (code == '23505') {
          if (message is String &&
              message.contains('swap_requests_one_pending_per_date')) {
            return l[KApp.errSwapPendingExists];
          }
          return l[KApp.errConcurrentSaveRetry];
        }

        // Trigger-raised messages arrive in PT-BR (accented) — show them.
        if (message is String &&
            message.isNotEmpty &&
            message.split('').any(_accented.contains)) {
          return message;
        }
      }
    }
  } on FormatException {
    // non-JSON body — fall through
  }
  return fallback;
}
