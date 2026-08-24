/// The Entrelares **database gate**, in Dart.
///
/// This is the test layer that proves the invariant the whole product is built
/// on — *the client MIRRORS, the database ENFORCES*. It asserts RLS, the
/// SECURITY DEFINER RPCs, the day-protection and transition triggers, the sudo
/// elevation window, the consent gate and the billing ledger against the REAL
/// dev project, through a throwaway family that the database itself guards
/// against being anything but throwaway.
///
/// It is being PORTED here suite by suite from `db-gate/`, the C# suite that
/// moved over from `entrelares-app` intact (T-56). Each PR of that crossing
/// translates a group and DELETES the C# classes it replaced, so the gate is
/// never uncovered; `C# tests + Dart tests` staying at 225 is the arithmetic
/// that says nothing was lost on the way.
///
/// Run it with the DEV project's service_role key — never production's:
/// ```
/// cd packages/entrelares_db_gate
/// E2E_SUPABASE_SERVICE_ROLE_KEY=<dev key> dart test
/// ```
library;

export 'src/admin_api.dart';
export 'src/gate_fixture.dart';
export 'src/iso_date.dart';
export 'src/test_env.dart';
