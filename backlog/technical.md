# Backlog — Technical / Architecture (pending)

Active technical items. Completed records live in [`archive/`](archive/). Conventions and the forward plan: [`README.md`](README.md). Live status: the [Notion board](https://app.notion.com/p/3ae2f3f4b9b28169acd9e642ad4760aa).

---

_T-08 (item 4.2), T-09 + T-11 (item 4.3) and T-07 + T-13 + T-27 (item 4.4) were completed in Phase 4 — records live in [`archive/phase-4.md`](archive/phase-4.md)._

_**T-34** (privacy e-mail address), **T-37** (Umami product analytics), **T-41** (`app_settings` config table) and **T-42** (`npm:` Deno imports) were completed in Phase 6 — records live in [`archive/phase-6.md`](archive/phase-6.md)._

_**T-35** (non-guessable concurrency token), **T-45** (next-day handoff consistency) and **T-49** (the test suite no longer spends the Resend allowance) were completed in Phase 7 — records live in [`archive/phase-7.md`](archive/phase-7.md)._

---

### T-18 — Add offline-first data strategy for service worker

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `medium` |

**Description**
The published service worker caches static assets (DLLs, CSS, JS, images) but has no strategy for API data. If the user opens the app offline after the initial load, all Supabase API calls fail silently and the calendar shows empty or an error. Implement a cache-then-network strategy for read operations (cache the last successful API response in IndexedDB, serve it when offline, refresh when online) and a background-sync queue for write operations (save to IndexedDB, sync to Supabase when connectivity is restored).

**Justification**
The app is marketed as a PWA that "works offline", but in practice only the shell loads offline — no data is visible. For a custody app, being able to check today's schedule without connectivity (e.g. in a basement, airplane, or rural area) is a core value proposition.

**Increment (Aug 2026 — external product review).** The review asked for the *reading* half by
name — "ver o calendário na porta da escola ou no elevador" — plus a discreet **"Modo offline"**
indicator. Both are folded in here, and the review's framing is the useful one: **this item
should be split, and the read half is the whole user-facing value.**

- **PR 1 — read offline (the actual ask).** Cache the last successful read of the *current
  month* + the today card, serve it when the network fails, refresh on reconnect. That is the
  door-of-the-school moment; nothing else in the item is needed for it.
- **A visible "Modo offline" strip, reading ONE connectivity state.** `navigator.onLine` alone
  lies (it reports the interface, not reachability — a captive portal is "online"), so the
  indicator must combine it with what the app already knows: `RealtimeBridgeService` tracks the
  socket state and already retunes the F-23 safety poll on it (25s socket-down / 120s healthy),
  and every PostgREST call goes through `RetryHelper`, which is where a failure is first seen.
  Derive the state once, in one service, and let the strip and the poll cadence read the same
  value — two independent notions of "offline" is a bug generator. The strip must also say
  **how stale** what is on screen is ("dados de HH:mm"), otherwise it invites the opposite
  mistake: trusting an old plan as current.
- **The strings go through the U-13 catalogue** (both languages + a call site, per
  `LocalizationTests`), and the date/time in "dados de …" through `DateFormats` (U-24).
- **A write queue is NOT a free extension of the read cache — it is a separate decision.**
  Every day rule lives in the **database**, and a write parked offline can be legitimately
  refused when it flushes: the T-35 `submitted_token` echo is **stale by construction** if
  anyone else wrote the day in the meantime (the flush is *supposed* to fail); the day may have
  been frozen by a swap request in the interval; the F-39 planning horizon may have moved; and
  a day that was in the future when queued may be in the past when it flushes (V008
  immutability). So background sync needs a per-item conflict UI and a replay policy, not just
  a queue — and a silent "saved" that later evaporates is worse than an honest "sem conexão".
  Ship the read half first and take that decision on its own.
- Store shells raise the stakes: a Play-installed app (T-38) that shows an empty calendar
  offline reads as a broken *app*, not as a browser with no signal.

**Files affected**
- `Entrelares/wwwroot/service-worker.published.js` — add API route interception and IndexedDB caching
- New JS module: `Entrelares/wwwroot/js/offline-store.js` — IndexedDB wrapper for schedule data
- `Entrelares/Services/CustodyService.cs` — optionally read from local cache when API fails (via JS interop)
- A single connectivity state (extend `Services/RealtimeBridgeService.cs` or a small
  `ConnectivityService`) + the indicator in `Layout/MainLayout.razor` — plus its catalogue keys
- Tests: unit (the staleness sentence and the state machine — online → degraded → offline);
  E2E is limited (Playwright can drop the context's network, but the cache lives in the SW)

---

_T-19 (Phase 5 item 5.6) was completed in July 2026 (v1.5.6) — its record lives in [`archive/phase-5.md`](archive/phase-5.md)._

---

_T-22 (item 4.6) was investigated and **skipped** in Phase 4 — no newer SDK exists for its goal (Gotrue is already at the latest published version). Findings and the revisit trigger live in [`archive/phase-4.md`](archive/phase-4.md)._

---

_T-29 was completed at the start of Phase 4 — its record lives in [`archive/phase-4.md`](archive/phase-4.md)._

---

_T-30 (Phase 5 item 5.1, first delivery) was completed in July 2026 — its record lives in [`archive/phase-5.md`](archive/phase-5.md). Scenario expansion: T-31 (done) and T-32 (below)._

---

_T-31 (Phase 5 item 5.2) was completed in July 2026 across three incremental PRs — its record lives in [`archive/phase-5.md`](archive/phase-5.md)._


---

_T-32 (Phase 5 item 5.16) was completed in July 2026 (test-only, no version bump) — its record + full findings report live in [`archive/phase-5.md`](archive/phase-5.md) and [`t32-findings.md`](t32-findings.md). Two batches of adversarial/boundary scenarios, all proving the app fails safely. Findings: T32-A1→**T-35** (guessable optimistic token, low — closed in `1.7.2`), T32-A2 (integration suite rate-limit flake — fixed with sign-in backoff in the fixture), T32-A3 (100-char notes limit is UI-only, accepted). **Closes Phase 5.**_

---

_T-33 (Phase 5 item 5.15) was completed in July 2026 (v1.5.24) — its record, including the full mutation-by-mutation concurrency inventory, lives in [`archive/phase-5.md`](archive/phase-5.md). Stale calendar UPDATEs now fail loudly via a `revision` guard (scope decision: care_schedules only — single-field profile/family edits stay last-writer-wins, accepted); bulk skips-and-reports conflicted days; the wizard survives batch INSERT collisions._

---

_T-35 was completed in August 2026 (`1.7.2`) — its record lives in [`archive/phase-7.md`](archive/phase-7.md). The T-33 counter kept its guard and gained a **non-guessable** half: `care_schedules.revision_token` is re-rolled on every write and the writer must echo it in `submitted_token`, so neither guessing the next value nor omitting the column passes. Server-side flows are exempt **by role** (`postgres`/`service_role`), which is what makes the guard unbypassable from outside. Closes T-32 finding T32-A1._

---

### T-36 — Supabase Pro upgrade + production-ops checklist for public availability

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `high` |

**Description**
Consolidates every operational decision that was deliberately deferred "until
public availability" into one checklist, so none is lost when the switch flips.
Most items are a paid-plan decision plus Dashboard toggles — no code.

1. **Upgrade the PROD project to Pro** (billed per organization; the dev/QA
   account can stay Free). Unlocks the two deferred protections:
   - **PITR / automated daily backups** (Free has none — today's only net is
     the weekly encrypted R2 dump, T-19). Recommended durability step in the
     deploy runbook (`supabase/README.md` §1).
   - **Leaked Password Protection** (HaveIBeenPwned check on sign-up/reset) —
     Pro-gated, confirmed July 2026; on Free the mitigation is the server-side
     8-char minimum. Closes the accepted `auth_leaked_password_protection`
     Advisor warning (see S-14 triage note).
2. **DMARC hardening** on `guardacompartilhada.com`: after a few weeks of clean
   reports, tighten `_dmarc` from `p=none` to `p=quarantine` (Cloudflare TXT
   edit — runbook §5.5 already flags it).
3. **Auth rate-limit review on prod** (Authentication → Rate Limits): confirm
   the e-mail limit (~30/h with custom SMTP) and the sign-in/OTP limits are
   sane for a public user base.
4. **Re-run the Security Advisors + RLS sweep** (runbook §6.4) as the final
   gate once S-14/S-15/T-34 are done.

**Justification**
Each of these was individually accepted as "fine for a single-family beta,
revisit before public availability" (T-19, S-12/S-13, S-14 triage, runbook
§5.5). Public availability is the trigger; this item is the collector so the
trigger actually fires.

**Scheduling decision (owner, Aug 2026), revised twice.** First it left group 1
for the END of the public-availability gate (group 2). Then, once S-16 (`1.7.1`)
and T-35 (`1.7.2`) emptied that group of development work, it **moved again to
the new group 8 · Início da monetização**
together with S-17: both are owner ops that wait on something other than
development — this one on revenue — so holding the queue behind them was buying
nothing. The group makes the owner's rule explicit instead of implicit:
**additional platform spend waits for actual revenue**, and it can be pulled
forward the moment that changes. The Pro fee is a recurring cost that only makes
sense once the app has actual revenue; the billing go-live for the current base
proceeds on the Free plan (consistent with the T-39 activation decision, which
already waived this gate for the current base). It still cannot slide past
**T-38**, whose public Play listing requires this green. Accepted risk while
deferred:
prod runs without PITR/daily backups — the weekly encrypted dump (T-19) is the
only backup net (payment truth lives in Asaas either way); revisit immediately
when revenue starts.

**Files affected**
- None in the app — Supabase/Cloudflare Dashboard operations; update the
  runbook (`supabase/README.md`) and the S-14/T-19 notes as each box is ticked.

---

### T-40 — iOS App Store wrapper (Capacitor)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 4 (distribution), **slot 2 — promoted from last (owner, Aug 2026)**: the earlier "deferred until monetization is validated" condition was dropped, the owner wants both store listings as soon as possible. The T-38-first ordering survives (Android proves the channel at a quarter of the cost). *(Was labelled "Phase 7 (Enhancement)" while phases doubled as a plan; since Aug 2026 the phase is assigned at CLOSE time and the group is the plan.)* |
| **Prerequisites** | T-38 (Android first proves the store channel); **T-47 (App Review publishability spike) — its verdict shapes this item's scope**; reuses landing `L-03` screenshots; pairs with F-09 (native push) |

**Description**
Apple does not accept a bare PWA, so an iOS App Store presence requires a **native wrapper
(Capacitor)** around the existing Blazor WASM app. Beyond the wrapper, the real work is:

- **Bundle the published app INTO the shell** (Capacitor local assets — added Aug 2026): never a
  WebView loading the remote URL, which is the variant Guideline 4.2 ("minimum functionality")
  rejects on sight. Local assets + APNs push + native touches are the standard defense — and
  **T-47** validates exactly this combination with a real App Review verdict before this item's
  budget is spent.
- **Native push via APNs** — the F-29 realtime bridge is JS/WebSocket; native push needs a
  Capacitor push plugin + APNs certificates (couples with F-09, Web/native Push).
- **App Review scrutiny** — Apple rejects "thin wrappers"; the app is feature-rich enough to
  pass, but expect to add native touches (splash, status-bar, share sheet) to feel native.
- **IAP consideration** — if a subscription is sold *inside* the iOS app, Apple requires In-App
  Purchase (15–30% cut). The **web-first billing** decision (T-39) is what lets the iOS app stay
  a "manage your subscription on our website" client and avoid the cut — verify current App
  Store review rules for the external-link allowance at build time. If store-cohort data ever
  justifies native purchase on iOS, StoreKit via a Capacitor plugin is the incremental path (the
  iOS mirror of **T-48**) — explicitly out of this item's scope.
- Apple Developer Program (US$99/yr), provisioning, TestFlight, store assets (reuse L-03).

**Justification**
iOS is a real distribution channel, but far costlier than the Android TWA (native shell, APNs,
review risk, annual fee). Split out of T-38 so the cheap Android channel proves the store
strategy first — that ordering still holds. What changed in Aug 2026 is the *timing*: it no
longer waits for monetization to be validated, because the owner wants both listings as soon as
possible. Two costs that ride along and are worth naming, since the same owner just created
group 8 to hold platform spend until revenue: the **US$99/yr** Apple fee is recurring, and native
push means bringing **F-09** (group 5) forward or shipping iOS without push at first.

**Files affected**
- New Capacitor project/shell wrapping the published WASM app; APNs config
- `wwwroot/manifest.webmanifest` / icons reused; native push plugin wiring (couples with F-09)
- New `store/ios/README.md` — Capacitor build + App Store submission runbook


---

### T-47 — iOS publishability spike (real App Review verdict before T-40)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` |
| **Complexity** | `medium` |
| **Impact** | `high` |
| **Roadmap** | Roadmap group 4 (distribution), between T-38 and T-40 |
| **Prerequisites** | T-38 (store assets exist, Android proves the channel); Apple Developer Program account — **US$99/yr, owner ops** |

**Description**
Time-boxed spike whose deliverable is **Apple's own verdict** on the wrapped app, obtained with
zero users affected and before T-40's budget is spent:

- Minimal Capacitor shell with the **published app bundled** (local assets, never a remote-URL
  WebView) + APNs registration wired — enough native surface to not read as a bare website.
  Billing/upgrade entry points hidden (same rule as T-38's store-context detection).
- Submit through App Store Connect with **manual release ("Pending Developer Release")** — the
  review verdict arrives without anything being published to users.
- **Approved** → the fear is closed by evidence; T-40 proceeds as scoped, and the approved shell
  is its starting point. **Rejected** → the rejection reasons are recorded HERE and become T-40
  scope items (almost always: more native integration), with years of lead time instead of a
  launch-week surprise.
- Build lane decided at execution: GitHub Actions macOS runner (**10× minutes multiplier** on the
  private-repo 2000/mo budget — a single spike run fits, a build loop does not) vs a local/cloud
  Mac. The owner is on Windows, so signing/upload steps must be written click-by-click.

**Justification**
Created Aug 2026 from the architecture review that considered (and declined) a .NET MAUI
rewrite: the owner's core fear was "will Apple ever accept this app when the moment comes?".
A MAUI Blazor Hybrid would face the SAME WKWebView review as Capacitor, so the migration would
not have bought the guarantee — this spike buys the actual fact for days of effort and US$99.
Its verdict is a formal prerequisite of T-40.

**Files affected**
- New `store/ios/` Capacitor spike project (becomes T-40's base if approved)
- New/updated `store/ios/README.md` — build lane, signing, submission + the recorded verdict

---

### T-50 — Move the Playwright traces off the GitHub artifact quota (to R2)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 5 — but see "Why this is not cosmetic": it is already biting |
| **Prerequisites** | None. The R2 bucket + credentials already exist for the weekly encrypted backup (T-19), so this reuses a path that is in production. |

> **Created 07/08/2026**, from an incident. Diagnosing a red `dev` E2E run (the U-23 tour
> blocking the whole smoke pack) had to be done by reading source, because the traces could
> not be uploaded: `Failed to CreateArtifact: Artifact storage quota has been hit. Unable to
> upload any new artifacts.`

**Description**
Upload `e2e-traces` (`deploy.yml`, on E2E failure) to the **Cloudflare R2 bucket the weekly
backup already uses (T-19)** instead of GitHub Actions artifacts, and print the object URL in
the job log. This takes the traces off GitHub's meter entirely — the lever `CLAUDE.md` already
names as the next one if the pack ever grows again.

**Why this is not cosmetic**
The 500 MB artifact cap is **account-wide**, shared by both repos, and `e2e-traces` is the only
artifact either of them produces — so it alone decides whether the quota holds. When it is
full, the failure mode is precisely the worst one: **you lose the diagnostic exactly when a
test is failing**, which is the only time the trace exists. It is a silent tax on every future
red run, in both repos, and it compounds — a run you cannot diagnose is a run more likely to be
"fixed" by guessing.

The August 2026 mitigations (`Screenshots` OFF in `UiFixture`, retention lowered to **1 day**)
bought real headroom — one red run had reached 391 MB by recording a frame-by-frame screencast
of every context, including the tests that PASSED — but they did not remove the ceiling. This
does.

**Scope**
- Replace the `actions/upload-artifact` step for `e2e-traces` with an R2 upload (the backup job
  already has the credential pattern and the bucket).
- Print the resulting URL in the job log, so a red run still tells you where its trace is.
- Keep the trace CONTENT as it is: DOM `Snapshots` on, `Screenshots` off. The video is what
  made the packs enormous; the step-by-step replay is what makes them useful.
- Decide a retention/lifecycle rule on the bucket side (R2 lifecycle), so traces expire without
  anyone remembering to delete them.

**Do this first, regardless (one line, minutes)**
Add `continue-on-error: true` to the trace-upload step. It is a **diagnostic** step, and today
a full quota makes it fail and add noise to a job that had already failed for an unrelated
reason. A step whose only job is to explain a failure must never be able to change a verdict.
Worth doing even if this item is never scheduled.

**Related**
T-19 (the R2 bucket and the credentials this reuses). The `CLAUDE.md` "Repo went private"
note (effect (b)) is where the quota mechanics and the 391 MB measurement are recorded.

---

### T-51 — Register `entrelares.app.br` (brand-protection domain)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` (by construction — waits on revenue, owner decision 12/08/2026) |
| **Complexity** | `low` (registration + one redirect; no code) |
| **Impact** | `medium` — squatting protection for the brand the Play listing makes public |
| **Roadmap** | Group 8 (Início da monetização), after F-49/L-15 — same shelf as everything that waits for the app to earn |

> **Created 12/08/2026 with the F-54 rebrand.** The rebrand bought `entrelares.app` (primary
> domain); `entrelares.app.br` was verified AVAILABLE the same day but deliberately not bought —
> the owner deferred it until the app has actual revenue, consistent with the group-8 rule
> (additional spend follows revenue). This item exists so the deferral has a reminder attached.

**Description**
Register `entrelares.app.br` at https://registro.br (~R$ 40/year; needs a CPF or CNPJ — if
F-49 has happened by then, register under the company's CNPJ so the domain follows the
business, not the person). Then a single ops step: add the zone to Cloudflare (or use
registro.br's own DNS) and 301-redirect apex + `www` to `https://entrelares.app`. No
mailboxes, no subdomains, nothing in either repo changes — `entrelares.app` remains the only
canonical host everywhere.

**Risk while it stays unregistered**
`.app.br` is the variant a Brazilian guesses when typing, and the brand is public in the Play
listing from the F-54 redeploy onwards. Anyone can take it for R$ 40 and hold it. That is an
accepted, revocable risk: if the app starts getting real traction (or any sign of squatting
appears on the name), pull this item forward instead of waiting for revenue — the whole point
of registering early is that it only works BEFORE someone else does.

**Related**
F-54 (the rebrand that created the split), F-49 (CNPJ — the ideal registrant), the group-8
rationale in `backlog/README.md`.

---

### T-56 — Archive the `entrelares-app` repository

| Field | Value |
|---|---|
| **Status** | `in-progress` |
| **Priority** | `high` — every extra day is a day the product's written memory lives in a repository nobody opens |
| **Complexity** | `high` (70 migrations, 12 Edge Functions, a 225-test database gate, the whole backlog and three ops pipelines) |
| **Impact** | `high` — it decides where the product's written memory lives |
| **Roadmap** | Outside the groups: structural debt opened by the cutover, not forward plan |

> **This item REVOKES a written decision.** The cutover plan
> ([`../docs/flutter-cutover.md`](../docs/flutter-cutover.md), § *"Onde o rollback morre"*,
> 23/08/2026) said: *"o repo `entrelares-app` NÃO é aposentado: ele continua sendo o repo do
> banco, das Edge Functions, do backlog e do gate de integração"*. That held while this repo
> was the T-53 spike and the Blazor client was the product. The cutover inverted both roles
> the next day, and keeping the database, the gate and the written memory in a repository
> nobody opens is the shortest path to losing them. New owner decision, 24/08/2026.

**Description**
Make `entrelares-app` **archived**: no longer needing to be updated and, above all, no longer
needing to be consulted. Everything about the application moves to `entrelares-flutter`;
`entrelares-site` keeps answering for the site.

The **eight decisions**, the **three measurements** behind them and the **PR-by-PR plan** live
in [`../docs/arquivamento-app.md`](../docs/arquivamento-app.md), which is this item's living
operational record. What the three measurements settled, because they overturned assumptions:
the database gate was tied to the Blazor client by only 1.010 lines of PostgREST contracts (not
by the suite itself); the Playwright suite is 62 tests against the 5 of this repo's
`integration_test` lane, so replacing the FLOW gate — not the database one — is the hard
problem; and this repo has no staging stage, since a merge to `main` publishes production.

**What was still open when this record was written**
- The **flow gate** replacing the Playwright suite (`flutter drive` + chromedriver spike).
- The **port of the database gate to Dart**, suite by suite.
- The **emptying** of the old repo, in a single PR.
- The **Blazor shutdown**, which is when the rollback dies — triggered by a measured condition
  (N days without a hit on `legado.entrelares.app`), never by a date.

**A finding for the Dart port, paid for on 24/08/2026.** `AdversarialTests.CrossFamilyAuditLog_IsNotReadable`
went red with `57014 — canceling statement due to statement timeout` after five suite runs in two
hours against the dev project. It was NOT an RLS breach: the assertion never ran. The test reads
`activity_logs` **with no filter** and lets RLS do the work, so its cost grows with everything the
QA project has accumulated — not with the size of its own throwaway family — and it hits the
8 s `statement_timeout` of the `authenticated` role. It passed on re-run, so it is contention, but
it is a fragility that grows: the gate now runs from TWO repositories. **When this suite is ported,
the query must be filtered and assert the absence of the specific id**, never download the table.
Same for any sibling written against the same pattern.

**A process consequence of the same episode.** `verify.yml` cancels in-progress runs of the same
ref, which is right for minutes but wrong for `db-gate`: a cancelled run dies before its teardown
and leaves throwaway families behind (the orphan sweep spares anything younger than 2 h, on
purpose, so a running suite is never robbed). Excluding `db-gate` from the cancellation — it
already has its own serialized `concurrency` — is a candidate fix, deliberately not made inside a
documentation PR.

---

### T-52 — Retire the legacy Android package `com.guardacompartilhada.app`

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` — nothing is broken while it waits; the cost of waiting is only that two brand traces stay live |
| **Complexity** | `low` (one Console action + a two-line diff) |
| **Impact** | `low` for users, `medium` for the "no trace of the old brand" directive |
| **Roadmap** | Group 4 (distribution), after the closed test — it is gated on a Play state, not on development |

> **Split out of F-54 at its close-out (13/08/2026).** The rebrand shipped complete, with one
> thing deliberately left standing: the app is a NEW Play package, so whoever installed the
> previous one still has it, and the pairing that keeps THAT app full-screen is the legacy
> statement in `assetlinks.json`. Removing it while those installs exist would put the browser
> bar back on their screens — a regression for the exact people who volunteered to test.
> F-54 could not stay open waiting for an external trigger with no date (a row left behind
> reads as current to every future session), so the bridge became its own item with the
> trigger written down.

**Description**
When the legacy app is unpublished — i.e. when its remaining testers have migrated to
`com.entrelares.app`, or the Play closed test of the new package reaches production —, remove
the bridge:

1. **Play Console**: unpublish `com.guardacompartilhada.app` (*Test and release → Setup →
   Advanced settings → App availability → Unpublish*). Warn its testers first; they lose
   updates, not their data — the account and history live on the server and are reachable at
   `web.entrelares.app` from any browser.
2. `Entrelares/wwwroot/.well-known/assetlinks.json` — drop the whole
   `com.guardacompartilhada.app` statement (both fingerprints), keeping only the new package.
3. `Entrelares/wwwroot/index.html` — drop the `android-app://com.guardacompartilhada.app`
   arm of the TWA referrer check.
4. `Entrelares/Helpers/StoreContext.cs` — drop the comment documenting the transitional
   acceptance.
5. `store/README.md` — the intro still says the legacy statement is "kept until that app is
   retired"; after this item, say it was.

**Justification**
The store-shell flag (T-38) and the Digital Asset Links pairing are the two places where a
retired package can still change behaviour, and both are invisible in normal use — nobody
notices a stale statement until an install proves it. Keeping the removal as a written item,
with its trigger and its file list, is what stops it from being discovered years later by
someone wondering why the repo names a brand that no longer exists.

**Files affected**
- `Entrelares/wwwroot/.well-known/assetlinks.json`
- `Entrelares/wwwroot/index.html`
- `Entrelares/Helpers/StoreContext.cs`
- `store/README.md`
- Play Console (owner ops, no code)
