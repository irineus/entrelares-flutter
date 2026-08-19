import 'package:entrelares_core/entrelares_core.dart'
    show isUniqueDayConflict;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/care_schedule.dart';
import '../models/family.dart';
import '../models/member.dart';
import 'custody_data_source.dart';

/// The real data source. Mirrors `CustodyService.cs`/`ProfileService.cs` reads
/// and the full-row write; Realtime is NATIVE here — the F-29 JS bridge and
/// the F-23 poll retire in this stack (the poll returns as a safety net only
/// if the socket misbehaves under real load; the spike must observe it).
class SupabaseCustodyDataSource implements CustodyDataSource {
  final SupabaseClient _client;

  SupabaseCustodyDataSource(this._client);

  @override
  Future<List<Member>> fetchMembers() async {
    final rows = await _client.from('profiles').select();
    return rows.map(Member.fromJson).toList();
  }

  @override
  Future<Member?> fetchOwnProfile() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await _client
        .from('profiles')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    return row == null ? null : Member.fromJson(row);
  }

  @override
  Future<void> updateOwnLanguage(int profileId, String languageCode) async {
    await _client
        .from('profiles')
        .update({'language': languageCode}).eq('id', profileId);
  }

  @override
  Future<void> updateDetectedLanguage(
      int profileId, String languageCode) async {
    await _client
        .from('profiles')
        .update({'language_detected': languageCode}).eq('id', profileId);
  }

  @override
  Future<List<CareSchedule>> fetchMonth(int year, int month) async {
    final first = DateTime(year, month, 1);
    final last = DateTime(year, month + 1, 0);
    final rows = await _client
        .from('care_schedules')
        .select()
        .gte('schedule_date', CareSchedule.isoDate(first))
        .lte('schedule_date', CareSchedule.isoDate(last))
        .order('schedule_date', ascending: true);
    return rows.map(CareSchedule.fromJson).toList();
  }

  @override
  Future<List<CareSchedule>> fetchUpcoming(DateTime from, int days) async {
    final rows = await _client
        .from('care_schedules')
        .select()
        .gte('schedule_date', CareSchedule.isoDate(from))
        .lte('schedule_date',
            CareSchedule.isoDate(from.add(Duration(days: days))))
        .order('schedule_date', ascending: true);
    return rows.map(CareSchedule.fromJson).toList();
  }

  @override
  Future<Family?> fetchOwnFamily() async {
    // Same shape as the web's GetMyFamilyAsync: a plain RLS-scoped select,
    // first row or null — never the is_premium() RPC (the mirror exists so
    // no extra round-trip is needed).
    final rows = await _client.from('families').select().limit(1);
    return rows.isEmpty ? null : Family.fromJson(rows.first);
  }

  @override
  Future<Map<String, String>> fetchPublicSettings() async {
    final rows = await _client.from('app_settings').select('key, value');
    return {
      for (final row in rows)
        (row['key'] as String): (row['value'] as String? ?? ''),
    };
  }

  @override
  Future<CareSchedule?> fetchDay(DateTime date) async {
    final row = await _client
        .from('care_schedules')
        .select()
        .eq('schedule_date', CareSchedule.isoDate(date))
        .maybeSingle();
    return row == null ? null : CareSchedule.fromJson(row);
  }

  @override
  Future<void> insertDay(CareSchedule day) async {
    await _client.from('care_schedules').insert(day.toInsertJson());
  }

  @override
  Future<void> updateDay(CareSchedule day) async {
    await _client
        .from('care_schedules')
        .update(day.toUpdateJson())
        .eq('id', day.id);
  }

  @override
  Future<void> deleteDay(int id) async {
    await _client.from('care_schedules').delete().eq('id', id);
  }

  @override
  Future<int> bulkInsertNewDays(List<CareSchedule> days,
      {void Function(int percent)? onProgress}) async {
    if (days.isEmpty) return 0;
    final dates = days.map((d) => d.scheduleDate).toList()
      ..sort((a, b) => a.compareTo(b));
    final first = dates.first;
    final last = dates.last;

    Future<Set<String>> existingDates() async {
      final rows = await _client
          .from('care_schedules')
          .select('schedule_date')
          .gte('schedule_date', CareSchedule.isoDate(first))
          .lte('schedule_date', CareSchedule.isoDate(last));
      return {for (final r in rows) r['schedule_date'] as String};
    }

    final existing = await existingDates();
    onProgress?.call(20);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final toInsert = [
      for (final d in days)
        // Past days are immutable; already-assigned days are kept.
        if (!d.scheduleDate.isBefore(today) &&
            !existing.contains(CareSchedule.isoDate(d.scheduleDate)))
          d,
    ];
    onProgress?.call(30);
    if (toInsert.isEmpty) {
      onProgress?.call(100);
      return 0;
    }

    // T-33: another member may create one of these days between the check and
    // the batch INSERT — on the UNIQUE(family, date) collision, re-fetch,
    // drop the collided days and retry the remainder once (web mirror).
    Future<int> insertBatch(List<CareSchedule> batch) async {
      try {
        await _client
            .from('care_schedules')
            .insert([for (final d in batch) d.toInsertJson()]);
        return batch.length;
      } catch (e) {
        if (!isUniqueDayConflict(e.toString())) rethrow;
        final fresh = await existingDates();
        final remainder = [
          for (final d in batch)
            if (!fresh.contains(CareSchedule.isoDate(d.scheduleDate))) d,
        ];
        if (remainder.isEmpty) return 0;
        await _client
            .from('care_schedules')
            .insert([for (final d in remainder) d.toInsertJson()]);
        return remainder.length;
      }
    }

    const batchSize = 10;
    final totalBatches = (toInsert.length + batchSize - 1) ~/ batchSize;
    var inserted = 0;
    var batchesDone = 0;
    for (var i = 0; i < toInsert.length; i += batchSize) {
      final end =
          i + batchSize > toInsert.length ? toInsert.length : i + batchSize;
      inserted += await insertBatch(toInsert.sublist(i, end));
      batchesDone++;
      onProgress?.call(30 + (batchesDone * 70 ~/ totalBatches));
    }
    return inserted;
  }

  @override
  Future<void Function()> watchChanges(void Function() onChange) async {
    final channel = _client
        .channel('care_schedules_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'care_schedules',
          callback: (_) => onChange(),
        )
        .subscribe();
    return () => _client.removeChannel(channel);
  }
}
