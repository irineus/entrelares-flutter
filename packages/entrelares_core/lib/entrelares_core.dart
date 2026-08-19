/// Pure-Dart core of Entrelares — the client-side MIRROR of rules the server
/// enforces. The server is the authority (RLS, triggers, RPCs); these exist so
/// the UI can present state and refuse bad input upfront, and so every contract
/// is unit-tested without a device — the same philosophy as the C# mirror
/// suites in `entrelares-app` (CalendarHelpersTests, EntitlementService).
library;

export 'src/auth_rules.dart';
export 'src/bulk_rules.dart';
export 'src/calendar_rules.dart';
export 'src/date_math.dart';
export 'src/day_protection_rules.dart';
export 'src/entitlement_rules.dart';
export 'src/freemium_rules.dart';
export 'src/environment_rules.dart';
export 'src/feedback_rules.dart';
export 'src/localization/app_language.dart';
export 'src/localization/date_formats.dart';
export 'src/localization/k.dart';
export 'src/localization/k_app.dart';
export 'src/localization/language_resolver.dart';
export 'src/localization/localization.dart';
export 'src/localization/notification_renderer.dart';
export 'src/localization/strings_en.dart';
export 'src/localization/strings_pt_br.dart';
export 'src/save_errors.dart';
export 'src/settings_rules.dart';
export 'src/today_rules.dart';
export 'src/wizard_rules.dart';
