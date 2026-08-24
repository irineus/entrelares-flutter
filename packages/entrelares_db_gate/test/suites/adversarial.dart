import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// T-32 (Suite E) — negative / adversarial exploration: probe how the app
/// FAILS. Every scenario forges a payload or composes two allowed operations to
/// reach a forbidden state, and every one must be rejected by the DATABASE (RLS
/// or a trigger), never by the UI alone — that is the invariant an attacker who
/// hits PostgREST directly cannot evade. Destructive scenarios run on throwaway
/// families.
///
/// Port of `db-gate/Entrelares.IntegrationTests/AdversarialTests.cs`.
void adversarialTests(GateFixture fx) {
  group('AdversarialTests', () {
    // ── Forged writes to the S-11 PR2 consent tables (SELECT-only RLS) ──────

    test('a forged family-deletion request is blocked', () async {
      await expectRejected(() => fx.member.from('family_deletion_requests').insert({
            'family_id': fx.familyId,
            'requested_by': fx.memberProfile.id,
            'scheduled_for':
                DateTime.now().toUtc().add(const Duration(days: 30)).toIso8601String(),
            'status': 'pending',
          }));

      final forged = await fx.service
          .from('family_deletion_requests')
          .select()
          .eq('family_id', fx.familyId);
      expect(forged, isEmpty);
    });

    test("a forged family-deletion response is blocked", () async {
      final fam = await fx.createFamily('adv-consent');
      await fx.elevate(fam.adminProfile);
      await fam.admin.rpc<dynamic>('request_family_deletion');
      final request = FamilyDeletionRequest.fromJson((await fam.admin
              .from('family_deletion_requests')
              .select()
              .eq('status', 'pending'))
          .single);

      // The requester tries to stamp the member's agreement themselves — which
      // would be fabricated evidence of somebody else's consent.
      await expectRejected(() => fam.admin.from('family_deletion_responses').insert({
            'request_id': request.id,
            'profile_id': fam.memberProfile.id,
            'agreed': true,
          }));

      final written = await fx.service
          .from('family_deletion_responses')
          .select()
          .eq('request_id', request.id);
      expect(written, isEmpty);
    });

    // ── RPC guards with no pending request ─────────────────────────────────

    test('the family-deletion RPCs are rejected with no pending request',
        () async {
      final fam = await fx.createFamily('adv-nopending');

      await fx.elevate(fam.adminProfile);
      await expectRejected(
        () => fam.admin.rpc<dynamic>('execute_family_deletion'),
        contains: 'Não há solicitação',
      );

      await expectRejected(
        () => fam.member
            .rpc<dynamic>('respond_family_deletion', params: {'p_agree': true}),
        contains: 'Não há solicitação',
      );
    });

    // ── Cross-family notification spam ─────────────────────────────────────

    test('a cross-family notification insert is blocked', () async {
      // RLS WITH CHECK ties a notification to the caller's family — a member of
      // family A cannot insert one targeting family B.
      final marker = 'adv-notif-${uniqueMarker()}';
      await expectRejected(() => fx.founder.from('notifications').insert({
            'recipient_profile_id': fx.founderBProfile.id, // other family
            'type': 'swap_requested',
            'title': 'forjado',
            'message': marker,
            'is_read': false,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          }));

      final written =
          await fx.service.from('notifications').select().eq('message', marker);
      expect(written, isEmpty);
    });

    // ── Double-submit / replay of a resolved swap ──────────────────────────

    test('replaying a resolved swap is rejected', () async {
      final fam = await fx.createFamily('adv-replay');
      final date = fx.nextFutureDate();
      final schedule = CareSchedule.fromJson((await fam.admin
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(date),
                'scheduled_parent_id': fam.adminProfile.id,
              })
              .select())
          .single);

      // Admin requests a swap proposing the member (the same INSERT the client
      // does); the member is the target and approves it.
      final request = SwapRequest.fromJson((await fam.admin
              .from('swap_requests')
              .insert({
                'schedule_date': isoDate(date),
                'schedule_id': schedule.id,
                'requesting_profile_id': fam.adminProfile.id,
                'target_profile_id': fam.memberProfile.id,
                'proposed_actual_parent_id': fam.memberProfile.id,
                'proposed_handoff_time': '12:00:00',
                'status': 'pending',
              })
              .select())
          .single);

      await fam.member
          .from('swap_requests')
          .update({'status': 'approved'}).eq('id', request.id);

      // Replay: any CHANGE out of the resolved 'approved' status is rejected
      // (approved→rejected and approved→pending both hit the trigger's ELSE).
      // Re-writing the SAME status is legitimately allowed — the trigger
      // short-circuits OLD.status = NEW.status, e.g. to stamp reminder_sent_at —
      // so double-submit only matters when it tries to CHANGE the outcome.
      for (final attempted in ['rejected', 'pending']) {
        await expectRejected(
          () => fam.member
              .from('swap_requests')
              .update({'status': attempted}).eq('id', request.id),
          contains: 'transition',
        );
      }

      final finalRow = SwapRequest.fromJson(
          (await fx.service.from('swap_requests').select().eq('id', request.id))
              .single);
      expect(finalRow.status, 'approved');
    });

    // ── Compose two operations: leave + cancel loop keeps state clean ───────

    test('a leave/cancel loop keeps the colour slot and the seat, with no '
        'duplication', () async {
      final fam = await fx.createFamily('adv-loop');
      final originalSlot = Member.fromJson((await fx.service
              .from('profiles')
              .select()
              .eq('id', fam.memberProfile.id))
          .single).colorSlot;

      for (var cycle = 0; cycle < 2; cycle++) {
        await fx.elevate(fam.memberProfile);
        await fam.member.rpc<dynamic>('request_account_deletion');
        await fx.elevate(fam.memberProfile);
        await fam.member.rpc<dynamic>('cancel_account_deletion');
      }

      final rows = [
        for (final row in await fx.service
            .from('profiles')
            .select()
            .eq('family_id', fam.familyId))
          Member.fromJson(row)
      ];
      // Exactly one profile per member — no duplication across the cycles.
      final mine = rows.where((p) => p.id == fam.memberProfile.id).toList();
      expect(mine, hasLength(1));
      expect(mine.single.isActiveMember, isTrue); // back and active
      expect(mine.single.leftAt, isNull);
      expect(mine.single.colorSlot, originalSlot); // colour slot preserved
    });

    // ── A frozen day (pending swap) is untouchable by a regular member ──────

    test('a frozen day cannot be deleted by a regular member', () async {
      final fam = await fx.createFamily('adv-frozen');
      final date = fx.nextFutureDate();
      final schedule = CareSchedule.fromJson((await fam.admin
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(date),
                'scheduled_parent_id': fam.adminProfile.id,
              })
              .select())
          .single);

      // The member requests a swap on this day → the day is now frozen.
      await fam.member.from('swap_requests').insert({
        'schedule_date': isoDate(date),
        'schedule_id': schedule.id,
        'requesting_profile_id': fam.memberProfile.id,
        'target_profile_id': fam.adminProfile.id,
        'proposed_actual_parent_id': fam.memberProfile.id,
        'proposed_handoff_time': '09:00:00',
        'status': 'pending',
      });

      await expectRejected(
        () => fam.member.from('care_schedules').delete().eq('id', schedule.id),
        contains: 'solicitação pendente',
      );

      final stillThere = await fx.service
          .from('care_schedules')
          .select()
          .eq('id', schedule.id);
      expect(stillThere, hasLength(1));
    });

    // ── Boundary: a 100-char note round-trips intact ────────────────────────

    test('a 100-character note round-trips intact', () async {
      // 100 chars is the UI's maxlength. The DB column is `text` with NO length
      // limit — the cap is UI-only (documented, accepted) — so what this pins is
      // that the round-trip is byte-for-byte, accents included.
      final fam = await fx.createFamily('adv-notes');
      final date = fx.nextFutureDate();
      final note = 'á' * 50 + 'x' * 50;

      await fam.admin.from('care_schedules').insert({
        'schedule_date': isoDate(date),
        'scheduled_parent_id': fam.adminProfile.id,
        'notes': note,
      });

      final stored = CareSchedule.fromJson((await fam.admin
              .from('care_schedules')
              .select()
              .eq('schedule_date', isoDate(date)))
          .single);
      expect(stored.notes, note);
      expect(stored.notes!.length, 100);
    });

    // ── The concurrency token cannot be stamped to an unread value ──────────

    test('stamping a revision this client never read is rejected', () async {
      // T-33: an update carrying a revision the client never legitimately
      // reached is rejected — the honest-client guard holds. (The
      // monotonic-counter limitation is documented as T35-A1/T-35; no invariant
      // is broken either way.)
      final fam = await fx.createFamily('adv-rev');
      final date = fx.nextFutureDate();
      await fam.admin.from('care_schedules').insert({
        'schedule_date': isoDate(date),
        'scheduled_parent_id': fam.adminProfile.id,
      });

      final day = CareSchedule.fromJson((await fam.admin
              .from('care_schedules')
              .select()
              .eq('schedule_date', isoDate(date)))
          .single);

      final payload = day.copyWith(notes: 'adv revision').toUpdateJson()
        ..['revision'] = day.revision + 50;
      await expectRejected(
        () => fam.admin.from('care_schedules').update(payload).eq('id', day.id),
        contains: 'salvou este dia primeiro',
      );
    });

    // ── S-14: cross-family isolation after dropping the always-true policies ─
    // Each probe seeds a row in family B and proves family A can neither read
    // nor mutate it. Before the S-14 migration the legacy `USING (true)`
    // policies made every one of these leak; the family-scoped policies now
    // stand alone.

    test("family A cannot READ family B's calendar", () async {
      final day = fx.nextFutureDate();
      await fx.founderB.from('care_schedules').insert({
        'schedule_date': isoDate(day),
        'scheduled_parent_id': fx.founderBProfile.id,
      });

      // Unique date, family A wrote nothing there → after S-14 it sees zero.
      final seenByA = await fx.founder
          .from('care_schedules')
          .select()
          .eq('schedule_date', isoDate(day));
      expect(seenByA, isEmpty);
    });

    test("family A cannot DELETE family B's calendar", () async {
      final day = fx.nextFutureDate();
      final rowB = CareSchedule.fromJson((await fx.founderB
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(day),
                'scheduled_parent_id': fx.founderBProfile.id,
              })
              .select())
          .single);

      // RLS filters the delete to zero rows — no error, but nothing happens.
      // Which is exactly why the assertion is that the row SURVIVED.
      await fx.founder.from('care_schedules').delete().eq('id', rowB.id);

      final stillThere =
          await fx.service.from('care_schedules').select().eq('id', rowB.id);
      expect(stillThere, hasLength(1));
    });

    test("family A cannot READ family B's immutable audit history", () async {
      final day = fx.nextFutureDate();
      final scheduleB = CareSchedule.fromJson((await fx.founderB
              .from('care_schedules')
              .insert({
                'schedule_date': isoDate(day),
                'scheduled_parent_id': fx.founderBProfile.id,
              })
              .select())
          .single);

      // The insert trigger wrote a family-B audit row; find it via the service
      // client, which is the only one allowed to see across families.
      final logB = ActivityLog.fromJson((await fx.service
              .from('activity_logs')
              .select()
              .eq('schedule_id', scheduleB.id)
              .limit(1))
          .single);

      // FILTERED, on purpose, and this is the one line of this port that is not
      // a translation. The C# version read `activity_logs` with NO filter and
      // let RLS do the work — so its cost grew with everything the shared QA
      // project had ever accumulated, not with this run's own family. On
      // 24/08/2026 it went red with `57014 — canceling statement due to
      // statement timeout` after five suite runs in two hours, and the failure
      // read like an RLS breach when the assertion had simply never run. Asking
      // for ONE id costs an index lookup and says exactly the same thing: family
      // A cannot see that row.
      final seenByA =
          await fx.founder.from('activity_logs').select('id').eq('id', logB.id);
      expect(seenByA, isEmpty);
    });

    test("family A cannot READ family B's profiles", () async {
      // …while still seeing its OWN family, which guards the other direction:
      // a policy tightened into uselessness would also pass a "cannot see B"
      // assertion on its own.
      final seenByA = [
        for (final row in await fx.founder.from('profiles').select())
          Member.fromJson(row)
      ];

      expect(seenByA.map((p) => p.id), isNot(contains(fx.founderBProfile.id)));
      expect(seenByA.map((p) => p.id), contains(fx.founderProfile.id));
    });
  });
}
