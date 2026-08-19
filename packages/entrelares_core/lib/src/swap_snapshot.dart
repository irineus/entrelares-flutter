/// F-26/F-47 — the pre-edit snapshot half of the revert flow, ported from
/// `SwapRequestService.cs` (`ParseSnapshot`/`GetJson*`, `PreEditNotes`,
/// `NotesDifferForRevert`'s data source and the `RestorePreEditStateAsync`
/// branching). The snapshot is the `old_data` JSONB of the `activity_logs`
/// row the swap request references via `pre_edit_log_id`; the 48h
/// auto-approval path replays the SAME rules server-side
/// (`restore_pre_edit_state`), so these mirrors must keep saying what it says.
library;

import 'dart:convert';

import 'swap_rules.dart';

/// The day's observation as the pre-edit snapshot holds it, or null (at the
/// call site) when there is nothing to restore FROM. Wrapped in a class so
/// "no snapshot" stays distinct from "snapshot with no text": a revert that
/// would ERASE the observation is still a change worth asking about (F-47).
class PreEditNotes {
  final String? notes;
  const PreEditNotes(this.notes);
}

/// F-47: only ask when the answer changes something — equal texts (and the
/// null/empty/whitespace variations of "no observation") mean the restore is
/// a no-op on that field. Case-sensitive comparison — an edit that only
/// changes case or accents is still an edit the family made on purpose.
/// Mirror of `NotesDifferForRevert`.
bool notesDifferForRevert(String? currentNotes, String? snapshotNotes) =>
    (normalizeFreeText(currentNotes) ?? '') !=
    (normalizeFreeText(snapshotNotes) ?? '');

/// The parsed `old_data` snapshot. `parse` mirrors `ParseSnapshot` +
/// `GetJson*`: null/blank/malformed input → null; a valid JSON root that is
/// not an object yields a snapshot whose every field reads null (the C#
/// `TryGetProperty` behaviour).
class PreEditSnapshot {
  final Map<String, dynamic>? _fields;

  const PreEditSnapshot._(this._fields);

  /// [oldData] as PostgREST hands it over — a decoded JSON object (Map), or a
  /// raw JSON string. Anything unparseable is "no snapshot".
  static PreEditSnapshot? parse(Object? oldData) {
    if (oldData == null) return null;
    if (oldData is Map) {
      return PreEditSnapshot._(oldData.cast<String, dynamic>());
    }
    final text = oldData.toString();
    if (text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return PreEditSnapshot._(
          decoded is Map ? decoded.cast<String, dynamic>() : null);
    } catch (_) {
      return null;
    }
  }

  /// Mirror of `GetJsonString`: missing key or JSON null → null; any other
  /// value reads as its string form.
  String? stringOf(String key) {
    final fields = _fields;
    if (fields == null || !fields.containsKey(key)) return null;
    final value = fields[key];
    return value?.toString();
  }

  /// Mirror of `GetJsonLong`: the string form parsed as an integer, or null.
  int? intOf(String key) {
    final value = stringOf(key);
    return value == null ? null : int.tryParse(value);
  }

  /// Mirror of `GetJsonTime`: the value kept as the wire time string when it
  /// parses as a time of day, null otherwise.
  String? timeOf(String key) {
    final value = stringOf(key);
    if (value == null || value.isEmpty) return null;
    return parseTimeOfDay(value) == null ? null : value;
  }

  String? get notes => stringOf('notes');
}

// ── RestorePreEditStateAsync branching, as data ──────────────────────────────

/// What the revert approval does to the `care_schedules` row. Mirror of the
/// three branches in `RestorePreEditStateAsync`; the data source executes the
/// plan, the rule stays pure and tested.
sealed class RevertRestorePlan {
  const RevertRestorePlan();
}

/// No snapshot reference (swaps approved before F-26): fall back to the
/// previous behaviour — just clear the swap back to the scheduled parent.
class RevertClearActualOnly extends RevertRestorePlan {
  const RevertClearActualOnly();
}

/// `old_data` is null/absent: the edit INSERTed the day (it did not exist
/// before) — restoring "before" means removing the day again. The
/// swap_requests / activity_logs history survives (`schedule_id` ON DELETE
/// SET NULL).
class RevertDeleteDay extends RevertRestorePlan {
  const RevertDeleteDay();
}

/// Restore the row from the snapshot (scheduled + actual + handoff).
/// [scheduledParentId] null means "keep the current value" (the C#
/// `?? schedule.ScheduledParentId`); [restoreNotes]/[notes] apply F-47 — the
/// day's observation moves only when the requester asked for it.
class RevertRestoreFields extends RevertRestorePlan {
  final int? scheduledParentId;
  final int? actualParentId;
  final String? handoffTime;
  final bool restoreNotes;
  final String? notes;

  const RevertRestoreFields({
    required this.scheduledParentId,
    required this.actualParentId,
    required this.handoffTime,
    required this.restoreNotes,
    required this.notes,
  });
}

RevertRestorePlan revertRestorePlan({
  required bool hasPreEditLogId,
  required Object? oldData,
  required bool revertNotes,
}) {
  if (!hasPreEditLogId) return const RevertClearActualOnly();

  final snapshot = PreEditSnapshot.parse(oldData);
  if (snapshot == null) return const RevertDeleteDay();

  return RevertRestoreFields(
    scheduledParentId: snapshot.intOf('scheduled_parent_id'),
    actualParentId: snapshot.intOf('actual_parent_id'),
    handoffTime: snapshot.timeOf('handoff_time'),
    restoreNotes: revertNotes,
    notes: snapshot.notes,
  );
}
