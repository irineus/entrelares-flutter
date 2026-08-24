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
