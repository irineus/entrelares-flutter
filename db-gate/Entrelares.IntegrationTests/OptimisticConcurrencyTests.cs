using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-33 — optimistic-concurrency guard on care_schedules:
    //   · a client UPDATE carrying a stale revision (the row changed since it
    //     was read) is rejected with the PT-BR "someone got there first"
    //     message — previously it silently overwrote (last-writer-wins);
    //   · an up-to-date UPDATE passes and the revision increments;
    //   · server-side column-list UPDATEs (the S-11/F-24 RPC style) never send
    //     revision, so they pass regardless — no special bypass needed.
    //
    // T-35 hardened it against a FORGED payload, which the counter alone could
    // not stop (revision = read + 1 is guessable, and simply omitting a column
    // looks exactly like echoing it correctly inside a BEFORE UPDATE trigger):
    //   · care_schedules.revision_token is re-rolled on every write and the
    //     writer must echo it in submitted_token — unguessable, and impossible
    //     to satisfy without actually re-reading the row;
    //   · an end-user write with NO echo (a pre-T-35 client build, or a forger
    //     dropping the column) is rejected with a DISTINCT message telling the
    //     user to reload the app;
    //   · the exemption is by ROLE now (postgres/service_role), not by payload
    //     shape — which is what makes the guard unbypassable from the outside.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class OptimisticConcurrencyTests(E2EFamilyFixture fx)
    {
        // The date comes from the fixture allocator, never from local arithmetic:
        // these days belong to family A, and a hand-picked offset (this used to
        // seed today+31…+34) is only unique until the allocator marches into it.
        // It did — T-45 added a handful of allocations and the next test to ask
        // for a "date family A never used" was handed one of these four, so
        // AdversarialTests.CrossFamilyCareSchedule_IsNotReadable failed in the
        // full run while passing alone.
        private async Task<CareSchedule> SeedDayAsync()
        {
            var date = fx.NextFutureDate();
            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id
            });
            return (await fx.Founder.From<CareSchedule>()
                .Where(s => s.ScheduleDate == date).Get()).Models!.Single();
        }

        [Fact] // The stale-UPDATE race now FAILS LOUDLY instead of overwriting.
        public async Task StaleUpdate_IsRejected_FreshUpdatePassesAndIncrements()
        {
            var day = await SeedDayAsync();

            // Both members read the same version of the day.
            var readByFounder = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            var readByMember = (await fx.Member.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            Assert.Equal(readByFounder.Revision, readByMember.Revision);

            // The founder saves first — passes, revision increments.
            readByFounder.Notes = "e2e t33 founder venceu";
            await fx.Founder.From<CareSchedule>().Update(readByFounder);
            var afterFirst = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            Assert.Equal(readByMember.Revision + 1, afterFirst.Revision);

            // The member saves with the STALE read — rejected with the PT-BR
            // conflict message; the founder's data survives untouched.
            readByMember.Notes = "e2e t33 member perderia";
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.From<CareSchedule>().Update(readByMember));
            Assert.Contains("salvou este dia primeiro", ex.Message);

            var final = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            Assert.Equal("e2e t33 founder venceu", final.Notes);
            Assert.Equal(afterFirst.Revision, final.Revision);

            // T-35: the token moved too, and it is not derivable from the old one.
            Assert.NotEqual(readByMember.RevisionToken, afterFirst.RevisionToken);
            Assert.NotEqual(Guid.Empty, afterFirst.RevisionToken);
            // NOT asserted here: that submitted_token is never STORED. The model's
            // SubmittedToken is computed from RevisionToken on the client, so it is
            // never null on a row that was read — it cannot observe the column. The
            // behavioural proof is EndUserUpdateWithoutEcho_… below: if the column
            // were persisted, an update omitting the echo would inherit the stored
            // value and pass, instead of being rejected.

            // Re-reading (rehydrate flow) and saving again works.
            final.Notes = "e2e t33 member depois de recarregar";
            await fx.Member.From<CareSchedule>().Update(final);
        }

        [Fact] // T-35: a payload that FORGES the token cannot pass. This is the
               // attack the monotonic counter could not stop — there, `read + 1`
               // was a valid guess; here the writer would have to guess a uuid.
        public async Task ForgedToken_IsRejected()
        {
            var day = await SeedDayAsync();

            var read = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();

            // Everything else is legitimate — same revision, same row, only the
            // token is invented (the client never read this value).
            read.Notes = "e2e t35 token forjado";
            read.RevisionToken = Guid.NewGuid();

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.From<CareSchedule>().Update(read));
            Assert.Contains("salvou este dia primeiro", ex.Message);

            var after = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            Assert.Null(after.Notes);                            // write did not land
            Assert.Equal(read.Revision, after.Revision);         // and nothing incremented
        }

        [Fact] // T-35: OMITTING the echo is the other half of the same attack —
               // a column-list UPDATE from an end user carries no submitted_token
               // and used to sail through. It is now rejected, and with the
               // "reload the app" message, because that payload shape is also
               // what a client build older than T-35 produces.
        public async Task EndUserUpdateWithoutEcho_IsRejected_AsAStaleClientBuild()
        {
            var day = await SeedDayAsync();

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.From<CareSchedule>()
                    .Where(s => s.Id == day.Id)
                    .Set(s => s.Notes!, "e2e t35 sem eco")
                    .Update());
            Assert.Contains("Recarregue o aplicativo", ex.Message);
            Assert.DoesNotContain("salvou este dia primeiro", ex.Message);

            var after = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            Assert.Null(after.Notes);
        }

        [Fact] // Server-style partial UPDATE (SET column) ignores revisions —
               // the S-11 cleanup/auto-approval RPC pattern keeps working. Since
               // T-35 this is an exemption BY ROLE (service_role here, `postgres`
               // inside the SECURITY DEFINER RPCs), which is why the very same
               // payload shape is rejected for an end user above.
        public async Task ColumnListUpdate_PassesRegardlessOfRevision_AndIncrements()
        {
            var day = await SeedDayAsync();

            // Bump the row once so its revision is non-zero.
            var fresh = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            fresh.Notes = "e2e t33 bump";
            await fx.Founder.From<CareSchedule>().Update(fresh);

            // Partial update via Set() sends only that column — no revision.
            await fx.Service.From<CareSchedule>()
                .Where(s => s.Id == day.Id)
                .Set(s => s.Notes!, "e2e t33 server-side")
                .Update();

            var after = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            Assert.Equal("e2e t33 server-side", after.Notes);
            Assert.Equal(fresh.Revision + 2, after.Revision);   // both updates incremented
        }
    }
}
