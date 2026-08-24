import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// T-33 — the optimistic-concurrency guard on `care_schedules`:
///   · a client UPDATE carrying a STALE revision (the row changed since it was
///     read) is rejected with the PT-BR "someone got there first" message —
///     it used to silently overwrite, last-writer-wins;
///   · an up-to-date UPDATE passes and the revision increments;
///   · server-side column-list UPDATEs (the S-11/F-24 RPC style) never send a
///     revision, so they pass regardless.
///
/// T-35 hardened it against a FORGED payload, which the counter alone could not
/// stop — `revision = read + 1` is guessable, and simply omitting a column looks
/// exactly like echoing it correctly inside a BEFORE UPDATE trigger:
///   · `revision_token` is re-rolled on every write and the writer must echo it
///     in `submitted_token` — unguessable, and impossible to satisfy without
///     actually re-reading the row;
///   · an end-user write with NO echo (a pre-T-35 client build, or a forger
///     dropping the column) is rejected with a DISTINCT message telling the user
///     to reload the app;
///   · the exemption is by ROLE now (`postgres`/`service_role`), not by payload
///     shape — which is what makes the guard unbypassable from the outside.
///
/// Port of `db-gate/Entrelares.IntegrationTests/OptimisticConcurrencyTests.cs`.
void optimisticConcurrencyTests(GateFixture fx) {
  // The date comes from the fixture allocator, never from local arithmetic:
  // these days belong to family A, and a hand-picked offset (this used to seed
  // today+31…+34) is only unique until the allocator marches into it. It did —
  // T-45 added a handful of allocations and the next test to ask for "a date
  // family A never used" was handed one of these four.
  Future<CareSchedule> seedDay() async {
    final date = fx.nextFutureDate();
    await fx.founder.from('care_schedules').insert({
      'schedule_date': isoDate(date),
      'scheduled_parent_id': fx.founderProfile.id,
    });
    return readDay(fx.founder, date);
  }

  group('OptimisticConcurrencyTests', () {
    test('a stale update is rejected; a fresh one passes and increments',
        () async {
      final day = await seedDay();

      // Both members read the same version of the day.
      final readByFounder = await readDayById(fx.founder, day.id);
      final readByMember = await readDayById(fx.member, day.id);
      expect(readByFounder.revision, readByMember.revision);

      // The founder saves first — passes, revision increments.
      await fx.founder
          .from('care_schedules')
          .update(readByFounder.copyWith(notes: 'e2e t33 founder venceu').toUpdateJson())
          .eq('id', day.id);
      final afterFirst = await readDayById(fx.founder, day.id);
      expect(afterFirst.revision, readByMember.revision + 1);

      // The member saves with the STALE read — rejected with the PT-BR conflict
      // message, and the founder's data survives untouched.
      await expectRejected(
        () => fx.member
            .from('care_schedules')
            .update(
                readByMember.copyWith(notes: 'e2e t33 member perderia').toUpdateJson())
            .eq('id', day.id),
        contains: 'salvou este dia primeiro',
      );

      final settled = await readDayById(fx.founder, day.id);
      expect(settled.notes, 'e2e t33 founder venceu');
      expect(settled.revision, afterFirst.revision);

      // T-35: the token moved too, and it is not derivable from the old one.
      expect(afterFirst.revisionToken, isNot(readByMember.revisionToken));
      expect(afterFirst.revisionToken, isNotEmpty);
      expect(afterFirst.revisionToken,
          isNot('00000000-0000-0000-0000-000000000000'));
      // NOT asserted here: that `submitted_token` is never STORED. The contract
      // computes the echo from `revision_token` on the client, so it cannot
      // observe that column. The behavioural proof is the no-echo test below: if
      // the column were persisted, an update omitting the echo would inherit the
      // stored value and pass, instead of being rejected.

      // Re-reading (the rehydrate flow) and saving again works.
      await fx.member
          .from('care_schedules')
          .update(settled
              .copyWith(notes: 'e2e t33 member depois de recarregar')
              .toUpdateJson())
          .eq('id', day.id);
    });

    test('a forged token is rejected', () async {
      // T-35: the attack the monotonic counter could not stop. There `read + 1`
      // was a valid guess; here the writer would have to guess a uuid.
      final day = await seedDay();
      final read = await readDayById(fx.founder, day.id);

      // Everything else is legitimate — same revision, same row; only the token
      // is invented, a value this client never read.
      final payload = read.copyWith(notes: 'e2e t35 token forjado').toUpdateJson()
        ..['submitted_token'] = '00000000-0000-4000-8000-000000000f06';

      await expectRejected(
        () => fx.founder.from('care_schedules').update(payload).eq('id', day.id),
        contains: 'salvou este dia primeiro',
      );

      final after = await readDayById(fx.founder, day.id);
      expect(after.notes, isNull); // the write did not land
      expect(after.revision, read.revision); // and nothing incremented
    });

    test('an end-user update with no echo is rejected as a stale client build',
        () async {
      // T-35, the other half of the same attack: a column-list UPDATE from an
      // end user carries no `submitted_token` and used to sail through. It is
      // rejected now, and with the "reload the app" message — because that
      // payload shape is also what a client build older than T-35 produces.
      final day = await seedDay();

      await expectRejected(
        () => fx.founder
            .from('care_schedules')
            .update({'notes': 'e2e t35 sem eco'}).eq('id', day.id),
        contains: 'Recarregue o aplicativo',
      );

      final after = await readDayById(fx.founder, day.id);
      expect(after.notes, isNull);
    });

    test('a server-side column-list update passes regardless of revision',
        () async {
      // The S-11/F-24 RPC pattern keeps working. Since T-35 this is an exemption
      // BY ROLE (`service_role` here, `postgres` inside the SECURITY DEFINER
      // RPCs), which is why the very same payload shape is rejected for an end
      // user in the test above.
      final day = await seedDay();

      // Bump the row once so its revision is non-zero.
      final fresh = await readDayById(fx.founder, day.id);
      await fx.founder
          .from('care_schedules')
          .update(fresh.copyWith(notes: 'e2e t33 bump').toUpdateJson())
          .eq('id', day.id);

      await fx.service
          .from('care_schedules')
          .update({'notes': 'e2e t33 server-side'}).eq('id', day.id);

      final after = await readDayById(fx.founder, day.id);
      expect(after.notes, 'e2e t33 server-side');
      expect(after.revision, fresh.revision + 2); // both updates incremented
    });
  });
}
