/// U-13 — the two languages the product speaks. Ported from
/// `entrelares-app` `Entrelares/Localization/AppLanguage.cs`.
///
/// Deliberately a closed enum and not a `Locale`: the UI language must move
/// WITHOUT dragging number/date formatting with it — every date that reaches
/// Supabase stays ISO 8601 (`CareSchedule.isoDate`), and display formatting is
/// the separate `date_formats.dart` (U-24). Adding a third language is adding
/// one member here plus one catalog — nothing else in the app widens.
library;

enum AppLanguage {
  /// Brazilian Portuguese — the product's original and default language.
  ptBr,

  /// English — added by U-13 to unblock international tester recruitment.
  en;

  /// The storage code — persisted locally, in `profiles.language` (behind a
  /// CHECK constraint) and read by the Edge Functions. A storage CONTRACT:
  /// changing one is a migration, not a rename.
  String get code => this == AppLanguage.en ? enCode : ptBrCode;

  static const String ptBrCode = 'pt-BR';
  static const String enCode = 'en';

  /// The language a session falls back to when nothing can be detected.
  /// PT-BR and not EN on purpose: the existing user base is Brazilian, so an
  /// undetectable environment is far more likely to be one of them than a
  /// recruited English tester (who WILL carry an `en-*` device locale).
  static const AppLanguage defaultLanguage = AppLanguage.ptBr;

  /// Parses a stored/declared code into a language. Any `pt*` tag (`pt`,
  /// `pt-BR`, `pt-PT`) is PT-BR; any other NON-EMPTY tag is English — that
  /// asymmetry is the item's rule, since the app has exactly one Portuguese
  /// and one everything-else. Null/blank yields `null` so callers can tell
  /// "absent" from "explicitly chosen".
  static AppLanguage? tryParse(String? code) {
    if (code == null || code.trim().isEmpty) return null;
    return code.trim().toLowerCase().startsWith('pt')
        ? AppLanguage.ptBr
        : AppLanguage.en;
  }
}
