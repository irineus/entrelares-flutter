import 'package:entrelares_core/entrelares_core.dart';

/// A row of `roles`. Mirrors `Entrelares/Models/Role.cs`.
///
/// Two kinds live in one table: the 21 built-ins (`family_id IS NULL`, seeded
/// by migration) and F-41 custom roles, which belong to one family. RLS already
/// narrows reads to built-ins plus the caller's own family, so the client never
/// filters for security — only for presentation.
class Role {
  final int id;

  /// The stored name. For built-ins this is the canonical key ([RoleCatalog]
  /// translates it); for custom roles it is free text the family typed, and it
  /// is shown exactly as written, in every language.
  final String roleName;

  /// Null for a built-in.
  final int? familyId;

  final String? emoji;

  const Role({
    required this.id,
    required this.roleName,
    this.familyId,
    this.emoji,
  });

  bool get isCustom => familyId != null;

  factory Role.fromJson(Map<String, dynamic> json) => Role(
        id: json['id'] as int,
        roleName: (json['role'] as String?) ?? '',
        familyId: json['family_id'] as int?,
        emoji: json['emoji'] as String?,
      );

  /// How this role reads for [language] — the composition every surface uses:
  /// built-ins translate, custom roles pass through, and the emoji leads when
  /// there is one.
  String displayLabel(AppLanguage language) => CustomRoleRules.displayLabel(
        RoleCatalog.translate(roleName, language),
        emoji,
      );
}
