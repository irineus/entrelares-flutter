import '../models/care_schedule.dart';
import '../models/member.dart';

/// What the calendar slice needs from the backend — an interface so widget
/// tests run against a fake while the real implementation talks to Supabase.
abstract class CustodyDataSource {
  Future<List<Member>> fetchMembers();

  /// All rows of [year]/[month]. RLS scopes the family server-side.
  Future<List<CareSchedule>> fetchMonth(int year, int month);

  Future<void> insertDay(CareSchedule day);

  /// Full-row update carrying the T-33/T-35 echo (see CareSchedule).
  Future<void> updateDay(CareSchedule day);

  /// Starts listening for care_schedules changes; [onChange] fires on any
  /// insert/update/delete visible to this session. Returns a dispose callback.
  Future<void Function()> watchChanges(void Function() onChange);
}
