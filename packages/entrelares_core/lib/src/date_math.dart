/// Date arithmetic the mirrors share. Both .NET `DateTime.AddMonths` and
/// Postgres `make_interval(months => n)` CLAMP the day-of-month when the
/// target month is shorter (Aug 31 − 6 months → Feb 28/29). Dart's `DateTime`
/// constructor overflows instead (Jan 31 + 1 month → Mar 3), so every mirror
/// that adds or subtracts months must go through [addMonthsClamped] — a
/// drifted day here would let the client disagree with the DB trigger about
/// the F-39 horizon and the F-40 retroactive floor.
library;

/// The date with the time-of-day dropped — the mirrors' `DateOnly`.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// [months] may be negative. Day-of-month clamps to the target month's length,
/// matching .NET `AddMonths` and Postgres interval arithmetic.
DateTime addMonthsClamped(DateTime date, int months) {
  final zeroBased = date.year * 12 + (date.month - 1) + months;
  final year = zeroBased ~/ 12;
  final month = zeroBased % 12 + 1;
  // Day 0 of the NEXT month = last day of this one.
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day <= lastDay ? date.day : lastDay);
}
