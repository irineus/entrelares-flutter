# Backlog — Technical / Architecture (pending)

Active technical items. Completed records live in [`archive/`](archive/). Conventions and the forward plan: [`README.md`](README.md). Live status: the [Notion board](https://app.notion.com/p/3ae2f3f4b9b28169acd9e642ad4760aa).

---

_T-08 (item 4.2), T-09 + T-11 (item 4.3) and T-07 + T-13 + T-27 (item 4.4) were completed in Phase 4 — records live in [`archive/phase-4.md`](archive/phase-4.md)._

_**T-34** (privacy e-mail address), **T-37** (Umami product analytics), **T-41** (`app_settings` config table) and **T-42** (`npm:` Deno imports) were completed in Phase 6 — records live in [`archive/phase-6.md`](archive/phase-6.md)._

_**T-35** (non-guessable concurrency token), **T-45** (next-day handoff consistency) and **T-49** (the test suite no longer spends the Resend allowance) were completed in Phase 7 — records live in [`archive/phase-7.md`](archive/phase-7.md)._

---

### T-18 — Offline-first data strategy (read cache + offline indicator)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `high` |
| **Impact** | `medium` |

**Description**
With no connectivity the app fails silently: every PostgREST call errors and the calendar
renders empty. Cache the last successful read locally and serve it when the network fails, so
the plan is still visible offline — the door-of-the-school moment ("ver o calendário na porta
da escola ou no elevador") that an external product review asked for by name.

> **Rewritten 26/08/2026 (post-cutover board sweep).** The original record was written for the
> Blazor PWA — `service-worker.published.js`, IndexedDB via JS interop, `RealtimeBridgeService`,
> `RetryHelper` — and every one of those surfaces died with the T-53 cutover (the shipped
> `service-worker.js` is deliberately a TOMBSTONE and must stay one). The product decisions
> survive unchanged; the implementation is Flutter's.

- **PR 1 — read offline (the whole user-facing value).** Persist the last successful read of
  the current month + the today card in a small local cache service (`shared_preferences` or a
  file; a real local DB only if the shape ever demands it), serve it when the fetch fails,
  refresh on reconnect. Nothing else in the item is needed for that moment.
- **A visible "Modo offline" strip, reading ONE connectivity state.** Derive the state once, in
  one service, from what the app already has — the native Realtime channel state and the
  success/failure of the PostgREST calls — never from a bare reachability probe alone (it
  reports the interface, not reachability; a captive portal is "online"). The strip must say
  **how stale** what is on screen is ("dados de HH:mm"), otherwise it invites the opposite
  mistake: trusting an old plan as current.
- **The strings go through the localization catalogs** (U-13, both languages) and the date/time
  through the per-language formats (U-24).
- **A write queue is NOT a free extension of the read cache — it is a separate decision.**
  Every day rule lives in the **database**, and a write parked offline can be legitimately
  refused when it flushes: the T-35 `submitted_token` echo is **stale by construction** if
  anyone else wrote the day in the meantime (the flush is *supposed* to fail); the day may have
  been frozen by a swap request in the interval; the F-39 planning horizon may have moved; and
  a day that was in the future when queued may be in the past when it flushes. So background
  sync needs a per-item conflict UI and a replay policy, not just a queue — and a silent
  "saved" that later evaporates is worse than an honest "sem conexão". Ship the read half
  first and take that decision on its own.
- The store raises the stakes, not the web: the Play-installed app IS this codebase now — an
  empty calendar offline reads as a broken *app*, never as a browser with no signal.

**Files affected**
- New cache + connectivity service under `apps/entrelares_app/lib/services/`; the pure state
  machine (online → degraded → offline) and the staleness sentence mirrored in
  `packages/entrelares_core` with `dart test`
- Calendar/today reads go through the cache; "Modo offline" strip in the app shell
- Catalog keys for every new string (U-13/U-24)

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

### T-40 — iOS channel: native Flutter build + App Store listing

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `high` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 4 (distribution) |
| **Prerequisites** | Store assets exist (T-38/F-54; T-57's re-shoot should land first so the listing is not born stale); pairs with F-09 (push); Apple Developer Program — **US$99/yr, owner ops** |

**Description**
Put the app on the App Store as a **native Flutter iOS build** (`flutter build ipa`) — the
same codebase that ships the Android and web channels.

> **Rewritten 26/08/2026 (post-cutover board sweep), absorbing T-47.** The item was born as a
> Capacitor wrapper around the Blazor WASM app, and **T-47** existed to buy Apple's verdict on
> that wrapper's "thin wrapper" risk (Guideline 4.2) before this item's budget was spent. A
> native Flutter app is not a wrapper: that risk collapsed with the T-53 cutover, so T-47 was
> closed `skipped` (owner, 26/08/2026) and its surviving idea — a cheap validation pass through
> TestFlight before the real submission — became step 1 here.

- **Step 1 — TestFlight validation pass (the surviving half of T-47).** First
  `flutter build ipa`, signing, upload, one internal TestFlight round. Surfaces the platform
  work — icons, launch screen, `Info.plist` permission strings, the iOS side of
  `url_launcher`/`printing`/share — with zero users affected and before the listing work starts.
- **Push:** native APNs rides the same `firebase_messaging` wiring F-09 chooses (the plugin
  carries APNs on iOS) — bringing F-09 forward or shipping iOS without push at first is the
  same trade-off as before.
- **Billing:** the web-first rail (T-39) is what lets the iOS app stay a "manage your plan on
  the website" client and avoid Apple's IAP cut — re-verify the App Store external-link rules
  at build time. If store-cohort data ever justifies native purchase on iOS, StoreKit via
  `in_app_purchase` is the incremental path (the iOS mirror of T-48) — explicitly out of this
  item's scope.
- **Build lane decided at execution:** GitHub Actions macOS runner (**10× minutes multiplier**
  on the private-repo 2000/mo budget — a submission fits, a build loop does not) vs a
  local/cloud Mac. The owner is on Windows, so signing/upload steps must be written
  click-by-click.
- Apple Developer Program (US$99/yr), provisioning, TestFlight, store assets (reuse the
  T-38/T-57 set).

**Files affected**
- `apps/entrelares_app/ios/` — icons, launch screen, `Info.plist` permission strings, signing
- New `store/ios/README.md` — build + signing + submission runbook (click-by-click)
- CI: an optional macOS lane for the ipa build (`workflow_dispatch`, never per-push)

---

_T-47 (iOS publishability spike) was **skipped** on 26/08/2026 — its premise, a Capacitor
shell around the Blazor WASM app needing Apple's verdict on the "thin wrapper" risk
(Guideline 4.2), died with the T-53 cutover: the iOS channel is now a native Flutter build.
The surviving idea (a cheap TestFlight validation pass before the real submission) is step 1
of the rewritten **T-40**. Record in [`archive/phase-7.md`](archive/phase-7.md)._

---

_T-50 (move the Playwright traces to R2) was **skipped** on 26/08/2026 — the artifact producer
died with the archiving of `entrelares-app` (T-56): the Playwright suite is gone, and this
repo's only CI artifact is the debug APK at 1-day retention. If the `web-e2e`/emulator lanes
ever record heavy diagnostics, a new item with real scope replaces it. Record in
[`archive/phase-7.md`](archive/phase-7.md)._

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
2. `apps/entrelares_app/web/.well-known/assetlinks.json` — drop the whole
   `com.guardacompartilhada.app` statement (both fingerprints), keeping the two that stay
   (`com.entrelares.flutter`, `com.entrelares.app`). **This is the file the cutover moved**:
   since 23/08/2026 `web.entrelares.app` is served from this repo, so the statement that keeps a
   legacy install full-screen is published from here — the Blazor copy at
   `entrelares-app/Entrelares/wwwroot/` now serves `legado.` only and dies with it.
3. Nothing else has a client half left, and since 24/08/2026 nothing else has a client at all:
   the two Blazor arms the original record listed — the
   `android-app://com.guardacompartilhada.app` referrer check in `index.html` and the
   transitional comment in `Helpers/StoreContext.cs` — went out of service with the shutdown of
   that client (T-56), never having been this item's to remove. The Flutter store rail reads the
   platform, not a referrer. **So this item is now exactly two things**: the Play Console
   unpublish and the `assetlinks.json` statement in step 2.

**Justification**
The store-shell flag (T-38) and the Digital Asset Links pairing are the two places where a
retired package can still change behaviour, and both are invisible in normal use — nobody
notices a stale statement until an install proves it. Keeping the removal as a written item,
with its trigger and its file list, is what stops it from being discovered years later by
someone wondering why the repo names a brand that no longer exists.

**Files affected**
- `apps/entrelares_app/web/.well-known/assetlinks.json`
- Play Console (owner ops, no code)

---

### T-57 — Bring the whole product listing to the current app (icon, art, screenshots, copy — PT-BR + en-US)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` — raised from `medium` on 26/08/2026. It opened as "nothing is broken, the pictures are merely old"; the sweep below found the listing **claiming a feature the product does not have** (offline) and the Console apparently serving a pre-masking screenshot upload. A listing is a claim about the system, so a stale one is not merely unflattering |
| **Complexity** | `medium` — the capture is one sitting; the cost is the seeded family, the two languages, the three publishing surfaces, and the fact that the mark, the art, the frames and the copy have to land TOGETHER |
| **Impact** | `high` — it is the store listing's and the landing's whole visual argument, and it is also where the product makes its public promises |
| **Roadmap** | Group 5 (polish), taking the slot L-21 vacates |
| **Repo** | `flutter` (the app being photographed, `store/`, and the mark's generator) **and** `entrelares-site` (the landing's own art and frames). Plus the Play Console uploads, which live in no repo at all |

> **Absorbs [L-21](https://github.com/irineus/entrelares-site/blob/preview/ROADMAP.md)
> ("English screenshots for `/en/`"), 24/08/2026, owner decision.** L-21 was written on
> 10/08/2026 with a premise that has since died: that the PT-BR captures were current and only
> the English set was missing. The cutover (T-53) replaced the client they photograph and
> U-27/U-28 replaced its visual system, so **both** sets are now stale — and one capture session
> produces both. Splitting "shoot the EN frames" from "publish the EN frames" would create a
> hand-off inside a single sitting.

**Description**
Re-capture the eight product frames from the **Flutter** app and republish them to both
consumers. The current set was captured on **23/07/2026** from the QA environment of the
**Blazor** client, with the `[Dev]` badge masked in place afterwards.

The eight frames (the names are the contract — the landing's `<picture>` elements and their
`alt` text reference them, so keep them):

| File | What it shows |
|---|---|
| `today-calendar-meu-dia` | Home: the day card when the day is the viewer's, plus the month |
| `today-calendar-dia-do-outro` | The same card in its two-colour state |
| `calendario-tres-cuidadores` | The month with three caregivers, one colour each |
| `editor-dia` | The day sheet: responsible, handoff time, observation |
| `troca-aguardando-aprovacao` | A pending swap with Aprovar / Recusar |
| `assistente-rotacao-com-avo` | The rotation wizard building a cycle with a grandmother |
| `historico-auditoria` | The immutable history with date and time |
| `familia-membros` | The family screen with members and the e-mail invitation |

Each one ships as a **`.png` + `.webp` pair, 1080×1920**. The PT-BR set keeps its place at
`entrelares-site/public/img/screenshots/`; the English set goes to a **parallel directory**,
`public/img/screenshots/en/` — L-21's call, and it is the right one: `public/index.html` and
`public/en/index.html` point at the same files today, so overwriting them in English would
hand the PT-BR page an English UI and merely move the defect. The **Play listing** takes the
PT-BR set for `pt-BR` and the English one for `en-US`, uploaded in the Console.

**Two constraints inherited from L-21/L-03, and they are not stylistic**

- **No invented data and no mocked screens** — the frames are a claim about the system, so
  this is the S-15 rule applied to marketing assets. Fictional family, real running UI.
- **Keep the `webp` + `png` pair and the existing `loading`/`width`/`height` attributes**, or
  the hero's LCP regresses. The `alt` text on `/en/` has to describe the English screen it
  will then actually show.

If **L-17** (the landing's animated demo of the immutable history) is scheduled anywhere near
this, do them in the same sitting: the recording and the stills come from the same running
app, and standing that app up is the expensive part.

**The item grew to the WHOLE listing (26/08/2026, owner decision)**

It opened as "re-shoot the eight frames". Two things happened after it was written: **U-29
replaced the mark** (26/08 — the calendar card whose day cells draw the two interlocked houses)
and a sweep of the live listing found that the frames were the least of it. The owner's call:
the item now covers **every surface a stranger sees, in both languages**, and they publish
**together**.

**Why together, and not one fix at a time.** U-29 deliberately did NOT move the store icon —
[`store/README.md`](../store/README.md) §2 records the reason: *"the Play listing stays on the
clay emblem until the listing art is updated as a whole — screenshots, feature graphic and icon
together (coordinate with T-57)"*. Shipping the icon alone gives the store one mark and eight
photographs of another; shipping the frames alone does the mirror image. **This item is the
release condition of that decision**, and it is not met surface by surface.

**A · The mark — three places, none of them the bundle**

The launcher icon travels in the `.aab` and U-29 already regenerated it, which is why the
INSTALLED app shows the new mark while the store shows the old one. The listing icon is a
different artifact with a different delivery path, and nothing in any build touches it.

| Where | What |
|---|---|
| [`store/store_icon.png`](../store/store_icon.png) | 512², still the retired F-54 clay emblem. `brand-icons.py` does **not** write it — a deliberate 13/08 removal so a routine re-run could not silently regress the framing, reaffirmed by U-29. First decision of this section: teach the script to write it, or hand-frame it again. Play crops it, and the old file was hand-supplied precisely because it survived that crop better |
| Play Console → *Grow users → Store presence → Main store listing → **App icon*** | The upload itself |
| `entrelares-site/public/` | `favicon.png`, `icon-192.png`, `icon-512.png`, `og-cover.png`, `og-cover-en.png` — **five** files, all on the clay mark. `store/README.md` §2 calls moving them "a follow-up of its own"; this is that follow-up |

**B · Feature graphic (1024×500, required by Play)**

[`store/feature-graphic.png`](../store/feature-graphic.png) is still the clay art, rendered from
`feature-graphic.html` with headless Chrome. Re-render against the new mark and **re-upload** —
§3's warning applies: *Play serves its own copy and nothing updates it automatically*.

The English side is a known hole, not an oversight: `feature-graphic-english.png` is
**2950×1440** — Play's 2.048∶1 ratio, but the form takes 1024×500 — and there is no
`feature-graphic-english.html` that reproduces it. An en-US listing either downscales that file
or gains a generator. Decide which; do not leave the EN listing showing the PT graphic.

**C · The eight frames — with a finding attached**

The frames and their file names are as described above, unchanged. What is new is this:

> **The Console's screenshots look like an upload OLDER than the repo's files (26/08/2026).** On
> the live Play page, both calendar frames carry an orange **DEV** pill at the bottom right. The
> versioned files — `entrelares-site/public/img/screenshots/today-calendar-meu-dia.png` and
> `calendario-tres-cuidadores.png` — were opened and **do not have it**: the `[Dev]` masking was
> done, in the repo. So the two consumers that `store/README.md` §1 calls "one set" have drifted,
> and the store is the one that drifted. **Confirm at full size in the Console before acting on
> it**; if it holds, the listing has been telling every visitor since 13/08 that they are looking
> at a development build. It also kills the assumption that a re-upload is optional whenever the
> files already exist in the repo.

**D · The copy — where this stops being cosmetic**

[`store/listing-pt-BR.txt`](../store/listing-pt-BR.txt) and
[`listing-en-US.txt`](../store/listing-en-US.txt) were last touched when they MOVED repositories
(#70, 24/08); their content predates the cutover. **Re-verify every sentence against the code
before re-publishing — the S-15 rule, applied to marketing.** The sweep already found one:

> **"Funciona também offline (os dados sincronizam ao reconectar)" is not true of this product.**
> **T-18** — *"Offline-first data strategy (read cache + offline indicator)"* — is `pending` in
> this very file. If offline worked, that item would not exist. The sentence was written for the
> **Blazor PWA**, whose service worker cached the shell; what answers at that URL today is the
> **tombstone** worker, which deletes caches by design (T-53 stage 4). The claim did not rot
> through neglect — the cutover falsified it, and nobody re-read the listing.

Two more to check, stated as questions rather than verdicts:

- **"Notificações em tempo real […] chegam na hora para todos os responsáveis."** In-app Realtime
  exists (plus the F-23 poll), but **F-09, push notifications, is `pending`** — with the app
  closed, nothing arrives. Decide whether the sentence survives as written.
- The store shows the app as **"Entrelares (acesso antecipado)"**. That is Play's own
  early-access tag from the closed test, not our copy — recorded so the next reader does not go
  hunting for it in `listing-pt-BR.txt`.

The **en-US listing** gets the same treatment, and it is not a translation exercise: it is the
same verification performed in the other language, against the same code. Console path —
*Main store listing → Manage translations → English (United States)*; the default language stays
pt-BR.

**E · The publish, in one sitting**

Nothing here is delivered by a merge. The repo half is `store/` plus `entrelares-site`; the store
half is **manual uploads in the Console** — icon, feature graphic, eight screenshots per
language, and both listing texts. Do them as one pass, in both languages, and only then is the
U-29 decision discharged.

**Acceptance:** open the Play page and the landing as a stranger would, in each language, and
find nothing left of the previous product — no clay mark, no Blazor screenshot, no DEV pill, and
no sentence the code cannot back.

**Four things that will bite, all knowable in advance**

1. **Do not shoot the dev flavour.** `SupabaseCustodyDataSource.environmentPrefix` puts
   `"[Dev] "` at the head of every stored notification title on non-production flavours. It is
   a deploy marker, deliberately outside `params` — so it is baked into the text a
   notification frame would photograph, and no amount of masking fixes a title. Shoot a
   **production-configured** build (`--dart-define=APP_ENV=prod` on web, `--flavor prod` on
   Android) against a family created for the purpose.
2. **The language is resolved, not toggled.** `LanguageResolver` reads localStorage override →
   `profiles.language` → `navigator.language`. The English set therefore needs the override or
   a profile stamped `en` — not a device-language guess, which is what makes an English frame
   silently render Portuguese.
3. **The seeded family has to be plausible AND disposable.** Three caregivers (the
   `calendario-tres-cuidadores` and `assistente-rotacao-com-avo` frames need the grandmother),
   real-looking names, a swap mid-flight for the approval frame, and history for the audit
   frame. It must not be a real family's data, and it must not be an `E2E-` family the purge
   sweep will eat mid-session.
4. **A closed test survives a listing update**, so this does not have to wait for a release —
   but it should PRECEDE the next production rollout, which is the argument the
   `store/README.md` note has been carrying.

**Justification**
The listing and the landing are the only two places where somebody who has never opened the
app decides whether to. Both currently show the Blazor client under the pre-U-27 visual
system: the product is misrepresented *cosmetically*, not in what it claims — which is why
this is polish and not a defect, and also why it never becomes urgent on its own and has to be
written down to happen at all.

**Files affected**
- `entrelares-site/public/img/screenshots/*.{png,webp}` — the eight PT-BR frames, re-shot
- `entrelares-site/public/img/screenshots/en/*.{png,webp}` — the English set (new directory)
- `entrelares-site/public/index.html` + `public/en/index.html` — `alt` text review; `/en/`
  finally points at the English captures (the L-21 half)
- `entrelares-site/ROADMAP.md` — L-21's record, closed as absorbed
- `store/README.md` §1 — the "out of date" note comes down when the frames are current
- Play Console (owner ops, no code): the `pt-BR` and `en-US` screenshot sets

---

### T-58 — The web flow gate must prove it ran (guard against a vacuous green)

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` — it is the alarm on the gate that stands between a merge and production |
| **Complexity** | `medium` — the guard is small; deciding what a real gate is allowed to block is not |
| **Impact** | `high` — every web publish since 24/08/2026 went out past a gate that asserted nothing |
| **Roadmap** | Group 5 (polish), right behind T-57 |
| **Repo** | `flutter` |
| **Depends on** | the E2E lane actually executing — PR #81's three defects. This item starts when that lands |

**The finding**
`web-e2e` has blocked the web publish since [#64](https://github.com/irineus/entrelares-flutter/pull/64) (24/08/2026), and it was passing **green while its `setUpAll` was throwing**. On web, `flutter drive` prints `All tests passed.` and exits **0** when zero tests ran — so an empty run is indistinguishable from a full one, and `set -euo pipefail` cannot see it, because the process really does exit 0.

Measured on 25/08/2026, same two files, same pack, one commit apart:

| Lane | before `2bcfcfb` (run `32832807358`, `main`) | after (run `32839493354`) |
|---|---|---|
| `web-e2e` | `All tests passed.` **2 s** after the debug service connected, exit 0 — **green** | names the test, exit 1 — **red** |
| `e2e` (emulator) | `setUpAll` throws — 0 passed / 2 failed | 1 passed / 1 failed |

Two seconds is not enough for a single round trip to Supabase, let alone a seeded family.

**The dating is what makes it structural, not a slip**
`role_name` entered in `ffb28b4` (19/08, the day the E2E lane was born). `web-e2e` was created in `ba5d192` ([#63](https://github.com/irineus/entrelares-flutter/pull/63)) on 24/08 and started blocking the publish in `ed8c3c4` (#64) — **five days after the bug**. It therefore never had a working `setUpAll`, which means it **never executed a test**. The green that justified letting it block production was vacuous from the first run.

**Scope**

1. **The guard: require positive proof of execution**, not the absence of an error. Suggested shape — the suites record how many tests ran in `binding.reportData` (a `tearDownAll`), `test_driver/integration_test.dart` swaps `integrationDriver()` for `integrationDriver(responseDataCallback: …)` writing that out, and the workflow step fails when the file is missing or the count is zero / below expectation. **Design it against the first genuinely green web run** — at the time of writing none has ever existed, so nobody knows what `flutter drive` prints on a real web success. A guard that greps expected output is how this class of bug is written a second time.
2. **Decide the regime, and that part is the owner's.** A gate that actually asserts can actually block a publish. That is its declared purpose, but in practice it is a change of regime, not a repaired test — which is exactly why it is an item and not a fix folded into someone's PR.

**Already done, and by someone else (25/08/2026).** This item opened carrying a third piece of
scope — correcting the false PR-5 line in [`docs/arquivamento-app.md`](../docs/arquivamento-app.md),
which recorded *"144 s para os dois packs (5 testes)"* while having timed **compilation** (2 targets
× ~42 s + startup) with zero tests executed. That correction landed in
[#82](https://github.com/irineus/entrelares-flutter/pull/82) hours later, written by the session
that owned the T-56 record: the "(5 testes)" claim is gone and the row now carries an explicit
`⚠️ CORRIGIDO` saying the lane was not blocking anything. Nothing is left of that piece.

**The method lesson that PR left, and the reason it belongs here rather than there.** It is the
rule the guard has to satisfy, stated better than this record first stated it:

> A probe proves what it exercises and nothing more. That one proved the lane can report a failing
> **assertion**; it never asked whether the lane can report a suite that **never got as far as
> asserting**. When a test exists precisely because the TOOL lies about success, the probe has to
> cover every way the run can end — and the record has to say which ways were covered.

Read against this item: a guard validated only by "we broke a test and the job went red" would
reproduce the original defect exactly. The acceptance for the guard is that it goes red on a suite
that runs **zero** tests — which is the case nobody checked, and the whole reason this item exists.


**And now the second half of the same question: the lane also OSCILLATES (26/08/2026).** The
first measured non-determinism since the lane started genuinely executing. Three jobs of the
same test code, no source change between them:

| Job | Result | Window (UTC) |
|---|---|---|
| `web-e2e` of [#86](https://github.com/irineus/entrelares-flutter/pull/86) ([97881850874](https://github.com/irineus/entrelares-flutter/actions/runs/32872255730/job/97881850874)) | pass | 25/08 **16:29:24 → 16:38:33** |
| `web-e2e` of [#87](https://github.com/irineus/entrelares-flutter/pull/87) ([97881998833](https://github.com/irineus/entrelares-flutter/actions/runs/32872300613/job/97881998833)) | **fail** | 25/08 **16:29:51 → 16:37:53** |
| the same job, re-run ([98124411440](https://github.com/irineus/entrelares-flutter/actions/runs/32872300613/job/98124411440)) | pass | 26/08 09:12:12 → 09:21:28 |

The failure: `Bad state: No element` from `ensureVisible` at `account_flows_test.dart:106`, in
*"p0 — an invitation is created and revoked through the real Família page"*. A finder matched
nothing. Both PRs were **documentation only** — neither touched a line the lane executes.

**Two variables change between the red and the green, and neither is established.** The re-run is
both *another day* and *alone*; the failure ran *alongside a sibling*. Read the windows: the two
runs of 25/08 started 27 seconds apart and the failing one lived entirely inside the passing
one's window. `web-e2e` is serialized **per ref** (`group: web-e2e-${{ github.ref }}`), so two
PRs run the lane against the same dev project simultaneously — by design.

Three candidate mechanisms, none of them demonstrated:

1. **Two concurrent runs on one dev project.** The job's own comment states non-collision as a
   *design assumption*, not a measurement: *"each invents its own `E2E-<runId>` family and both
   orphan sweeps spare anything younger than 2h"*. That reasoning covers per-family state and
   says nothing about what two runs SHARE — the Resend allowance is per ACCOUNT (a documented
   gotcha: the suite once spent production's), and S-01 throttling is per identity. An
   invitation e-mail that a shared limit refuses is exactly a finder that matches nothing.
2. **A date-dependent path.** There is precedent in this product: the Blazor `BulkUiTests`
   failure that held the `dev`→`master` promotion at the cutover was deterministic *only when
   the allocated days fall on the last row of the month*. A calendar-shaped failure looks like
   flakiness until somebody plots it against the date.
3. **An ordinary render/timing race** in `ensureVisible`, which is the dullest explanation and
   therefore the one most likely to be true.

**Why this belongs to T-58 rather than to a new item.** T-58 asks whether the gate can be
*trusted*, and there are two ways to fail that: it can approve without asserting (the original
finding) and it can refuse for reasons unrelated to the change (this one). Both spend the same
trust, and the second is the more corrosive in practice — a lane that goes red at random teaches
everyone to re-run until green, which is indistinguishable from not having a gate at all. **The
re-run above is exactly that behaviour**, done knowingly and recorded here rather than quietly.

**How to settle it cheaply, before writing any fix.** Do not start from the code. Re-run the
FAILING sha alone, on a day whose calendar shape differs, and separately push two branches on
purpose within a minute of each other and watch both lanes. One of those two experiments
separates the variables; guessing between them writes the wrong fix confidently.

**Deliberately NOT in scope:** the three stacked E2E defects themselves (the `roles.role_name` column, `bootApp`'s inverted order, the unpinned language). Those belong to PR #81. This item is about the lane being *unable to lie*, not about the tests it happens to be running today.

**Justification**
A gate that approves without asserting is worse than no gate: it spends the trust a gate is for. The failure mode is silent by construction — there is no red build, no error, no slow step, only a green check that means nothing — so it is only ever found by accident, and it was: while chasing an unrelated scheduled failure. Writing the guard is what converts that accident into a rule.

**Files affected**
- `apps/entrelares_app/test_driver/integration_test.dart` — the driver's `responseDataCallback`
- `apps/entrelares_app/integration_test/*.dart` — the executed-count report
- `.github/workflows/verify.yml` — the assertion in the `web-e2e` step

---

### T-59 — Play production rollout: closed alpha → public availability

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `high` |
| **Complexity** | `low` |
| **Impact** | `high` |
| **Roadmap** | Roadmap group 4 (distribution), after T-52 — the collector for the event the surrounding items keep referencing |

**Description**
The step every nearby item points at but none tracked: promoting the Play track from the
closed alpha to production/open testing. Created 26/08/2026 by the post-cutover board sweep —
T-57 and S-18 both say "should precede the next PRODUCTION rollout", T-36 gates a public
listing, F-53 fulfils a public promise to the testers, and the Play Billing go-live is
console ops (§9-bis) — but the rollout itself had no row. Like T-36, this is a **collector**:
mostly owner ops, plus small PRs wherever a checkbox turns out to be code.

**Checklist (each box names its own item where one exists)**
- [ ] **F-53 executed** — tester families identified and granted the permanent comp (the
  public promise of 11/08/2026; the mechanism exists since F-58).
- [ ] **S-18 settled** — Play Data safety caught up (App interactions, the Messages call on
  F-44 notes, the §7 operator list) + the materiality call on the policy text.
- [ ] **T-57 shot** — the listing must not go public with screenshots of the dead Blazor
  client under the pre-U-27 visual system.
- [ ] **T-36 decision** — the no-PITR/no-daily-backup risk was accepted for a closed test
  with ~12 testers; a public listing reopens that acceptance (T-36 is the dependency that
  survived every reordering).
- [ ] **Play Billing go-live** (§9-bis in [`supabase/README.md`](../supabase/README.md)) — or
  an explicit decision to launch with the store rail dark (`billing.store_enabled = false`
  shows the T-38 neutral note by design, and the web rail keeps selling).
- [ ] **The rollout itself** — promote the bundle/track in the Play Console, verify the
  public listing, record the date here and on the board.

**Justification**
The closed alpha is nearly done. Without a collector, the prerequisites live only as
cross-references inside other items' prose — which is exactly how launch-week surprises
happen (the S-15 lesson, applied to our own plan). One row makes the gate explicit and gives
the board a place to record the date the product became publicly available.

**Files affected**
- Mostly none (Play Console + Supabase dashboard ops); small PRs may fall out of S-18/T-57

### T-60 — Flutter upgrade package: SDK pin + share_plus/KGP + dependency refresh

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `low` |
| **Complexity** | `medium` |
| **Impact** | `medium` |
| **Roadmap** | Roadmap group 7 (future / low priority) — fires only on the owner's explicit decision to move the Flutter pin (locked decision: the version changes by board-recorded owner decision only) |

**Description**
Created 27/08/2026 from the owner's 2.0.0 release build: the build log carries a warning with
a real deadline — `share_plus` still applies the Kotlin Gradle Plugin, and **future Flutter
versions will refuse to build** apps whose plugins do (Flutter's built-in Kotlin migration).
Today it is noise; the day the SDK pin moves, it is a build failure. This item packages the
three things that must travel TOGETHER so none becomes a surprise:

1. **Flutter SDK pin** (`.fvmrc`, currently 3.44.7) — owner decision, recorded on the board;
   CI and every dev machine follow FVM, so the pin move is one commit plus a full gate run.
2. **`share_plus` major bump** to a release that supports built-in Kotlin (13.x already
   exists), plus whatever its platform-interface drags along.
3. **General dependency refresh** — `flutter pub outdated` lists ~18 majors held back by
   constraints (`go_router` 18, `intl`, `archive`, …). Bump deliberately, one suite run per
   cluster, never as a side effect of a release build.

**Also as a package on purpose:** upgrading the SDK re-baselines the Gradle/AGP/Kotlin
toolchain, which is what silences the `java.lang.System::load` native-access warnings the
release build prints today (they come from Gradle 9 on a modern JDK, not from our code).

**Out of scope**
- Any behaviour change riding along "while we're at it" — the gates (485+ widget tests,
  806 core, db-gate) are the acceptance, unchanged.

**Files affected**
- `.fvmrc` · `apps/entrelares_app/pubspec.yaml` + lockfiles across the workspace ·
  possibly `android/settings.gradle`/AGP versions if the SDK bump asks for them
