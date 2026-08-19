import '../models/care_schedule.dart';
import '../models/member.dart';

/// What the calendar slice needs from the backend — an interface so widget
/// tests run against a fake while the real implementation talks to Supabase.
abstract class CustodyDataSource {
  Future<List<Member>> fetchMembers();

  /// The signed-in user's OWN profile row, or null when none exists. Read at
  /// gate time for the U-13 language adoption/detection sync — before the
  /// calendar loads, not inside it.
  Future<Member?> fetchOwnProfile();

  /// U-13: persists the user's explicit language CHOICE. Best-effort at the
  /// call site — the client's language does not depend on the server write.
  Future<void> updateOwnLanguage(int profileId, String languageCode);

  /// U-13: records what this session renders in (`language_detected`), so a
  /// sender with no browser can match the screen. Best-effort, every boot
  /// where it disagrees.
  Future<void> updateDetectedLanguage(int profileId, String languageCode);

  /// All rows of [year]/[month]. RLS scopes the family server-side.
  Future<List<CareSchedule>> fetchMonth(int year, int month);

  Future<void> insertDay(CareSchedule day);

  /// Full-row update carrying the T-33/T-35 echo (see CareSchedule).
  Future<void> updateDay(CareSchedule day);

  /// Starts listening for care_schedules changes; [onChange] fires on any
  /// insert/update/delete visible to this session. Returns a dispose callback.
  Future<void Function()> watchChanges(void Function() onChange);
}
