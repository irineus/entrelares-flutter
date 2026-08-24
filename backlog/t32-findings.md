# T-32 — Negative / boundary / adversarial exploration — findings & coverage

Phase-5 closing test pass (roadmap 5.16). Reviews every Phase-5 delivery plus
cross-phase gaps, records what the happy-path suites already prove, and drives
the new adversarial scenarios. Any real defect found becomes its own backlog
item; accepted limitations are documented here.

Baseline before this item: **106 unit**, **72 integration**, **44 E2E**.

> **Finding IDs are `T32-A<n>` (renamed July 2026).** They used to be `F-32-<n>`, which
> collided with the backlog ID space: any tool reading `F-32` out of a commit message or
> doc matched the **feature** F-32 (freemium foundation) and attributed this item's work to
> it. Finding IDs must never start with a backlog prefix (`F-`/`U-`/`T-`/`S-`/`L-` + two
> digits). Old references to `F-32-1…5` mean `T32-A1…A5`.

## 1. Coverage map — Phase 5 deliveries

| Item | Behaviour | Covered by |
|---|---|---|
| S-10 sudo | elevation gate on RPCs, audit, self-actions owner-only | `SudoElevationTests` (7) |
| S-11 PR1 exit | leave/cancel, successor, last-member family removal, freeze, purge | `AccountDeletionTests` (10) |
| S-11 x-family | warn + migrate, tombstone, active-block | `RegisterInviteeTests` (4) |
| S-11 PR2 family delete | request/respond/withdraw/execute, unanimity, reminder, purge | `FamilyDeletionTests` (9) |
| S-12 posture | anon reads nothing (12 tables) | `RlsHardeningTests` (4) |
| S-13 LGPD | consent stamp, retention purge | `ConsentAndRetentionTests` (3) |
| F-29 realtime | bridge init + reconnect UI | `RealtimeUiTests` (2) + adaptive-poll fallback preserves F-23 |
| T-33 concurrency | stale-UPDATE guard, server-side pass-through | `OptimisticConcurrencyTests` (2) + `CalendarHelpersTests` |
| QA clear-day (v1.5.25) | delete assigned day = admin-only | `DayProtectionTests` (7) |

## 2. Findings

### T32-A1 — Optimistic revision guard is bypassable by a fabricated counter (accepted limitation)
`care_schedules.revision` increments **monotonically (+1)**, so a client that
sends `revision = read + 1` **without re-reading** matches `OLD.revision` and
its stale write is accepted — defeating the T-33 optimistic lock. **This is not
a security hole:** the value is trivially guessable, but the worst outcome is a
last-writer-wins overwrite of `notes`/`actual_parent` — exactly the pre-T-33
behaviour — and every real invariant (S-09 planned parent, the swap workflow,
day protection) is still enforced by its own trigger regardless of `revision`.
The legitimate client always echoes the value it read (`ShallowCopy` carries
`Revision`), so honest staleness is caught as designed. Accepted: T-33 is an
**optimistic** guard for honest-but-stale clients, not an adversarial lock. A
non-guessable token (random per-write nonce, or `If-Unmodified-Since` on
`updated_at`) would harden it — tracked as **T-35** (low priority), **delivered in `1.7.2`**;
see the follow-ups section for what the fix had to change about this suggestion.

### T32-A2 — Integration suite flakes under GoTrue's auth rate limit at scale (test-infra, fixed)
Adding more throwaway families (each = several `SignInWithPassword` calls) pushed
a CI run over GoTrue's request rate limit → HTTP 429 `over_request_rate_limit`
flaked four unrelated `AccountDeletionTests`. Not an app bug — a harness scaling
limit. Fixed in the fixture: `SignInAsync` now retries on 429 with exponential
backoff (1/2/4/8/16s). Keeps the growing suite deterministic.

### T32-A3 — The 100-char notes limit is UI-only (accepted)
`care_schedules.notes` is `text` with no DB length constraint; the 100-char cap
is `maxlength` on the input only. A client hitting PostgREST directly can store
longer notes. Accepted — notes are free-text with no security weight, the UI
governs normal use, and a length CHECK could be added later if abuse appears.
Locked at the boundary by `NotesAt100Chars_RoundTripIntact` (exactly 100, incl.
accented chars, survives byte-for-byte).

### T32-A4 — PII in Edge Function logs (fixed in the 1.6.0 cleanup)
The pre-release cleanup sweep found `send-swap-email` logging **names and
e-mail addresses** to Supabase's function logs (requester/target, invitee) —
contradicting the S-13 "no PII in logs" posture (which had only covered the
client `ErrorLoggingService`). Scrubbed to log by **id and operational
counters only**. The other function logs (counts, statuses, priority tag) carry
no PII.

### T32-A5 — Full-pack E2E only runs on master; stale tests + a month-end date bomb (test-infra, fixed)
The first `master` push of Phase 5 (the 1.6.0 promotion) went red in E2E while
the same commit was green on `dev` — because dev pushes run only the p0 smoke
(T-31) and the full pack had not executed since v1.5.0. Four failures, all in
the tests, none in the app: (a) `BulkClear` still ran without admin mode after
v1.5.25 made clearing assigned days admin-only; (b)+(c) the fixture's
`NextVisibleDay` clamped month overflow to day 1 of the CURRENT month — a past,
V008-immutable day returned REPEATEDLY (notes silently not applied; then a
UNIQUE violation) — so any master run near the end of a month would fail;
(d) the leave-family test asserted the cancel button with an instant
`IsVisibleAsync` racing the screen's "Carregando…" phase. Fixed: same-month
block allocator (`NextVisibleDays`) that jumps whole to the next month +
`ShowMonthOfAsync` navigation helper, admin mode in `BulkClear`, and a proper
wait in the leave test. Lesson recorded: after UI-touching phases, run the full
pack via workflow_dispatch BEFORE promoting to master.

### No defects found in the adversarial/compose batches
Every forged-payload / compose-two-operations probe is **rejected** by the
database — the app fails safely. The one real bug this class of testing finds
(the clear-day bypass) was already caught manually and fixed in v1.5.25.
Batch 2 probes all held: leave→cancel loops keep the color slot / seat and
never duplicate the profile; a frozen (pending-swap) day cannot be deleted by a
regular member; malformed invite tokens are refused gracefully at one of two
layers — the function maps an invalid uuid cast to the friendly "Convite
inválido" (400), while attack-signature payloads (SQL injection, path traversal)
are blocked earlier by the platform edge/WAF with a 403, before the function
runs. Either way: a safe 4xx refusal, no raw DB error, no account created. (The
test asserts the 4xx and checks the friendly body only on the 400 path — an
earlier version pinned 400 for every case and flaked when the WAF returned 403.)

## 3. New scenarios added (this item)

**`AdversarialTests.cs` (Suite E — integration):**
- Direct INSERT into `family_deletion_requests` / `family_deletion_responses`
  is blocked (SELECT-only RLS) — a member cannot forge a request or fabricate
  another member's consent outside the RPCs.
- `execute_family_deletion` / `respond_family_deletion` with **no pending
  request** are rejected with the PT-BR contract message.
- Cross-family notification INSERT is blocked (RLS `WITH CHECK` on the
  recipient's family) — cannot spam another family's member.
- Replaying a **resolved** swap: any CHANGE out of a resolved status
  (approved→rejected, approved→pending) is rejected by
  `enforce_swap_status_transition`. Re-writing the SAME status is a legitimate
  no-op (the trigger short-circuits `OLD.status = NEW.status`, e.g. to stamp
  `reminder_sent_at`), so double-submit only matters when it tries to change
  the outcome — and that path is blocked.
- `care_schedules.revision` is server-managed — a client update carrying a
  revision it never read is rejected (documents the honest-client guard).

**`SwapRequestServiceLogicTests.cs` (boundary units):**
- `ComputePriorityTag` across far-past / far-future spans (no overflow, correct
  classification decades out).

## 4. Open follow-ups (deferred, tracked in backlog)
- ~~**T-35** — harden the concurrency token against fabrication (T32-A1).~~ **Delivered** in
  `1.7.2` (Aug 2026): the fix is a read/echo token PAIR, because a single non-guessable
  token — the correction this report proposed — is still bypassable by OMITTING the column.
  Record in [`archive/phase-7.md`](archive/phase-7.md).
- Remaining T-32 candidate categories not yet automated (next batches): DST /
  month-boundary UI generation in the wizard, 344 px viewport E2E assertions,
  100-char notes round-trip, whole-month bulk selection, RetryHelper end-to-end
  under injected 5xx. These are lower-yield (the pure formulas are unit-covered
  and Brazil currently observes no DST) and are listed for completeness.
