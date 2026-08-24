@Timeout(Duration(minutes: 5))
library;

import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import 'suites/adversarial.dart';
import 'suites/caregiver_gate.dart';
import 'suites/consent_and_retention.dart';
import 'suites/day_protection.dart';
import 'suites/family_isolation.dart';
import 'suites/handoff_transition.dart';
import 'suites/optimistic_concurrency.dart';
import 'suites/planning_horizon_gate.dart';
import 'suites/reconsent_gate.dart';
import 'suites/rls_hardening.dart';

/// **The single entrypoint of the database gate, and why it is single.**
///
/// In xUnit, 41 of the C# suite's 43 classes shared ONE family through
/// `[Collection("e2e-family")]` — a collection fixture is constructed once for
/// the whole collection, whatever the class count. `dart test` has no such
/// thing: it runs each *file* in its own isolate, so a `setUpAll` is per FILE.
/// A file-per-suite port would therefore create one throwaway family per file
/// — 40-odd sign-up flows, invitations and purges per run, hammering the shared
/// QA project and multiplying the GoTrue rate-limit surface T-32 already had to
/// back off from.
///
/// So the suites are libraries, not test files: each exposes a function that
/// REGISTERS its groups against a fixture it is handed. This file is the only
/// `_test.dart` in the package, it owns the one `setUpAll`/`tearDownAll` pair,
/// and every suite runs inside it against the same family.
///
/// Two consequences worth knowing before adding a suite:
///   · a suite registers groups at CALL time but must only TOUCH the fixture
///     inside a `test` body — the fields are populated in `setUpAll`, which runs
///     after registration;
///   · order matters as little as it did in xUnit, and for the same reason:
///     every day comes from the fixture's allocators, never from local date
///     arithmetic.
void main() {
  final fx = GateFixture();

  setUpAll(fx.initialize);
  tearDownAll(fx.dispose);

  familyIsolationTests(fx);
  rlsHardeningTests(fx);
  adversarialTests(fx);
  consentAndRetentionTests(fx);
  reconsentGateTests(fx);
  caregiverGateTests(fx);
  dayProtectionTests(fx);
  handoffTransitionTests(fx);
  planningHorizonGateTests(fx);
  optimisticConcurrencyTests(fx);
}
