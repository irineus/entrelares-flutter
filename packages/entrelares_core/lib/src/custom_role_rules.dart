/// F-41 custom family roles — mirror of `entrelares-app`
/// `Entrelares/Helpers/CustomRoleRules.cs`.
///
/// Only the two cheap, unambiguous checks live here. Everything that needs to
/// know the family (duplicates, the admin check, the Premium gate, whether the
/// role is in use) is enforced by the RPCs `create_custom_role` /
/// `update_custom_role` / `delete_custom_role`, and the caller surfaces the
/// server's message verbatim.
///
/// ⚠️ The messages below are hard-coded PT-BR and NOT catalog keys — that is
/// deliberate and must survive the port: they have to match the RPC's own
/// wording byte-for-byte, so a rule that trips client-side and a rule that
/// trips server-side read identically to the user.
library;

abstract final class CustomRoleRules {
  static const int maxLabelLength = 30;

  /// UTF-16 code units, matching C#'s `String.Length` (the DB counts
  /// codepoints via `char_length`). Multi-codepoint emoji — ZWJ families,
  /// flags — stay comfortably under both bounds.
  static const int maxEmojiLength = 16;

  /// Returns the error message, or null when the input is acceptable.
  /// The label is trimmed BEFORE its length check; the stored value is trimmed
  /// by the caller, not here (same split as the C# service).
  static String? validate(String? label, String? emoji) {
    final cleanLabel = (label ?? '').trim();
    if (cleanLabel.isEmpty) return 'Informe o nome do papel.';
    if (cleanLabel.length > maxLabelLength) {
      return 'O nome do papel pode ter no máximo $maxLabelLength caracteres.';
    }
    if ((emoji ?? '').trim().length > maxEmojiLength) return 'Emoji inválido.';
    return null;
  }

  /// How a role reads everywhere it is shown: "👵 Avó", or just the label when
  /// the role carries no emoji.
  static String displayLabel(String translatedLabel, String? emoji) =>
      (emoji == null || emoji.trim().isEmpty)
          ? translatedLabel
          : '$emoji $translatedLabel';

  /// The curated picker palette. UX only — the RPC accepts any short string,
  /// so trimming or extending this list needs no migration. Several entries
  /// carry a variation selector (🕊️, ❤️, ☀️, ✈️); they are copied byte-exactly
  /// from the web palette so the two clients offer the same glyphs.
  static const List<String> emojiPalette = [
    // People & ages
    '👨', '👩', '🧑', '👴', '👵', '🧓', '🧔', '👱', '👦', '👧', '🧒', '👶',
    // Family & care
    '👪', '🤱', '🍼', '🤝', '🫶', '💪', '🙏', '🕊️',
    // Hearts
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🤍', '💖',
    // Light & nature
    '⭐', '🌟', '✨', '🌈', '☀️', '🌙', '🍀', '🌻', '🌸', '🌺',
    // Home & activities
    '🏠', '🏡', '🎒', '📚', '🧸', '⚽', '🎨', '🎵', '🚗', '✈️',
    // Affectionate nicknames
    '🦉', '🐻', '🦁', '🐱', '🐶', '🐰', '🦋', '🐞',
  ];
}
