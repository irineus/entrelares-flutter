/// Pure-Dart core of Entrelares — the client-side MIRROR of rules the server
/// enforces. The server is the authority (RLS, triggers, RPCs); these exist so
/// the UI can present state and refuse bad input upfront, and so every contract
/// is unit-tested without a device — the same philosophy as the C# mirror
/// suites in `entrelares-app` (CalendarHelpersTests, EntitlementService).
library;

export 'src/calendar_rules.dart';
export 'src/save_errors.dart';
