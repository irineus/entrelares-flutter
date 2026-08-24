/// `yyyy-MM-dd`, the only shape a date takes on the wire.
///
/// The C# suite forced the invariant culture in a module initializer, because
/// the test host inherited the machine culture and a `pt-BR` host turned
/// `26/07/2026` into a PostgREST filter that answers `22008`. Dart has no
/// ambient culture to be poisoned by, so the equivalent protection is simply
/// that no date is ever formatted any other way: every filter, every payload
/// and every assertion goes through this function.
String isoDate(DateTime date) => '${date.year.toString().padLeft(4, '0')}'
    '-${date.month.toString().padLeft(2, '0')}'
    '-${date.day.toString().padLeft(2, '0')}';

/// `HH:mm:ss`, the shape PostgREST returns a `time` in and the only shape the
/// gate writes one back.
String isoTime(DateTime instant) => '${instant.hour.toString().padLeft(2, '0')}'
    ':${instant.minute.toString().padLeft(2, '0')}'
    ':${instant.second.toString().padLeft(2, '0')}';

/// [days] calendar days after [date], as a date-only value.
///
/// NOT `date.add(Duration(days: n))`: a `Duration` is elapsed TIME, so on a
/// day-saving boundary it lands on 23:00 of the day before or 01:00 of the day
/// after, and `isoDate` then names the wrong day. The whole gate reasons about
/// D and D+1 — the T-27 transition rule is literally defined against D-1 — so
/// the calendar step is the one that must be used, and going through the
/// constructor makes the arithmetic the CALENDAR's rather than the clock's.
DateTime addDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// Today, as a date-only value.
DateTime today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}
