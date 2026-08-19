/// U-13 — the language-selection rule, as a pure function so it is unit-tested
/// without a device, a session or a widget tree. Ported from
/// `entrelares-app` `Entrelares/Localization/LanguageResolver.cs`.
///
/// Precedence (decided 05/08/2026): a manual override beats the profile, which
/// beats device auto-detection. The override lives in local storage because it
/// must apply BEFORE any session exists — a recruited tester meets the login
/// screen before there is a profile row to read.
///
/// The profile column is not redundant with local storage: it is what the
/// SERVER-side senders (the two e-mail Edge Functions, the cron notifications)
/// read to address each recipient in their own language. Local storage is the
/// client's truth; `profiles.language` is the server's copy of it.
library;

import 'app_language.dart';

abstract final class LanguageResolver {
  /// Local-storage key holding the user's explicit choice — the same name the
  /// web app uses in localStorage, so the rule reads identically in both repos.
  static const String storageKey = 'app-language';

  /// Resolves the language for this session.
  ///
  /// [storedOverride] — locally persisted value, the user's explicit pick, or
  /// null. [profileLanguage] — `profiles.language` for the signed-in user, or
  /// null while anonymous. [deviceLanguage] — the platform locale tag, or null
  /// when unreadable.
  static AppLanguage resolve(
    String? storedOverride,
    String? profileLanguage,
    String? deviceLanguage,
  ) =>
      AppLanguage.tryParse(storedOverride) ??
      AppLanguage.tryParse(profileLanguage) ??
      AppLanguage.tryParse(deviceLanguage) ??
      AppLanguage.defaultLanguage;
}
