# CLAUDE.md — Project context for Claude Code

## What this repo is
The **T-53 rewrite** of Entrelares (Blazor WASM PWA, repo `entrelares-app`) in
**Flutter/Dart**. Born as the stage-1 spike (GO verdict, 19/08/2026); **stage 3 is open**:
this repo is becoming the product app, built batch by batch per the parity map
(`entrelares-app/docs/flutter-paridade.md`, order 1→2→3→4→6→5) behind the cutover plan
(`entrelares-app/docs/flutter-cutover.md`). **All six batches are delivered — batch 5
(premium/billing with the T-48 Play Billing redesign) closed on 20/08/2026**, so stage 3
is functionally complete. **U-27**, the visual foundation (design
tokens, the shared component set, skeletons), closed on 20/08/2026 — deliberately done
while zero users were on the Flutter app, because after the cutover every visual change is
a change to a live product. **Stage 4 (the cutover) OPENED 23/08/2026**: the decisions,
the two-channel runbook and the day the rollback dies are in
`entrelares-app/docs/flutter-cutover.md`. Its CODE half is delivered — this repo now
publishes the web channel — but the switch itself (Play track, the Cloudflare domain
move, the announced date) is owner ops and has NOT been thrown. The Blazor app is
frozen (owner policy, 19/08/2026) and stays in production until that cutover.

Authority chain: `entrelares-app/CLAUDE.md` holds the product invariants (language rules,
backlog trailer convention, working agreement) — they all apply here. This file only adds
what is Flutter-specific. Backlog + board live in the app repo / Notion; this repo never
carries its own backlog.

## Locked decisions
| Decision | Value |
|---|---|
| Flutter | **3.44.7 (stable)** via FVM (`.fvmrc`) — same pin as desmalha/console |
| JDK | 17 |
| `minSdk` | 26 |
| `applicationId` (per flavor) | **dev = `com.entrelares.flutter`** — different from the Play package on purpose, so the dev APK coexists with the store-installed app on the owner's device. **prod = `com.entrelares.app`** (stage 0 proved the Play package accepts a Flutter build with the same upload signature). Release signing is per flavor via git-ignored `android/key.properties` (T-55): `dev.*` = dedicated sideload keystore, `prod.*` = the PRODUCT's upload keystore — never swap them; without the file, release builds fail fast (debug unaffected). |
| Structure | Monorepo: `apps/entrelares_app` (Flutter) + `packages/entrelares_core` (pure Dart) |
| Environment | Build flavors (stage 3): `dev` → project `buroanotfjcgvbfmacuh`, `prod` → production — both PUBLIC configs hardcoded in `env.dart`, selected at compile time via `appFlavor`. Every Android build requires `--flavor`; flavor-less targets (`flutter test`) fall back to dev by construction. The Supabase singleton initializes once per process, so environments are per build variant, NEVER a runtime switcher. |
| Targets | Android **and web** (batch 6, tension 1: Flutter Web replaces the PWA). The CHANNEL acceptance (first load on a mid-range Android over 4G) is the owner's measurement, still pending. |
| Web channel (stage 4) | **`flutter build web` accepts NO `--flavor`** — on web `appFlavor` is always null, so a flavor-only rule resolves the web build to DEV. Production says so with **`--dart-define=APP_ENV=prod`**, and `web_channel_test` fails the build if that define (or `--no-web-resources-cdn`, which keeps CanvasKit on our own origin) leaves the workflow. Published by the `deploy-web` job of `verify.yml` to Cloudflare Pages project **`entrelares-web`**, behind `needs: verify`, only from `main`, and self-disarming while the CF secrets are absent. Everything in `apps/entrelares_app/web/` is copied verbatim into the build — including `.well-known/assetlinks.json` (the App Link of the INSTALLED app is verified against this host) and `service-worker.js`, which is the **tombstone** of the Blazor PWA's worker: the only thing that reaches an installed PWA is the browser's update check of that exact URL, so the file must never be deleted while a device may still carry the old worker. |
| Billing | **Two rails, decided by the BUILD** (T-48 redesign, lote 5). The web target sells through the Asaas rail (`billing.enabled`, live in production since 29/07/2026); Android sells through **Play Billing** behind its own switch `billing.store_enabled`, which is PUBLIC and starts `false`. While it is false — or the device has no store, or no product comes back — the store branch shows the **T-38 neutral note**, which is also the fail-closed default. The **store price is Play's** (the product carries it; `app_settings` prices rule the web rail only), and **the client never grants Premium**: the purchase token goes to `billing-store-verify`, which asks the Play Developer API, and the acknowledge to Play happens only after the server accepted. Product ids `premium_monthly`/`premium_annual` are pinned by test — renaming one orphans real purchases. Go-live is console work: `entrelares-app/supabase/README.md` §9-bis. |
| Visual system | **U-27 (20/08/2026)**: `apps/entrelares_app/lib/theme/tokens.dart` is the ONE place a colour may be written — `no_color_literal_test` fails the build on a `Color(0x` anywhere else in `lib/`. Both themes are hand-written (never `ColorScheme.fromSeed`: seeding tints the greys with the brand indigo and kills the neutral identity), and **dark ships with the tokens**, following the system — a user-facing switch is U-12's. Colour is never the only vector: each calendar slot carries a `SlotPattern` texture too, and the swapped day is amber with a dashed border (web parity), which is what freed the rose `#E11D48` to be a role again. The eleven shared components live in `apps/entrelares_app/lib/widgets/ui/` (barrel `ui.dart`) and encode two conventions: the action pair puts the CONFIRMATION FIRST (the Blazor order — parity with the muscle memory people arrive with) and every field carries a permanent label, which is how WCAG 1.4.11 is met without a heavier border. Loading states are SKELETONS wherever the shape of what is coming is known; a spinner survives only for a button mid-press, a determinate bar, and a wait with no shape (splash, payment return). Type is **Inter**, four static weights subset to `latin` (~96 KB gzip), regenerable with `apps/entrelares_app/tool/subset_inter.py`; the PDF keeps Roboto on purpose (F-33). |
| Analytics | T-37 via Umami Events API. The website id is PUBLIC and per environment: **dev is empty on purpose** (every call becomes a no-op, so QA never pollutes production statistics); prod carries the product's site. No PII ever — the sanitizer is a pure mirror with its own suite. |

## Product invariants that survive the rewrite (from the app repo)
- **The client MIRRORS, the database ENFORCES.** RLS, SECURITY DEFINER RPCs, sudo S-10
  (`ELEVATION_REQUIRED:` marker) and the T-33/T-35 concurrency guard (`revision` +
  `revision_token`/`submitted_token` echo) are the security. Never "protect" in the client.
- **Dates on the wire are ISO 8601** (`yyyy-MM-dd`); display formatting is client-side and
  per reader language (U-24). Translating a screen must never change the wire format.
- **UI text PT-BR** (bilingual per reader is U-13 — NOT validated by the spike; PT-BR only
  here). Code/comments/docs in English. Commits PT-BR conventional style; delivery commits
  end with the `Backlog: <ID>` trailer.
- **Owner directive (18/08/2026):** parity is the floor, not the ceiling — where Flutter
  offers a natural improvement over the Blazor behaviour (native Realtime instead of the
  F-23 poll, month swipe, native bottom sheet, pull-to-refresh, haptics), take it. The
  improvement is UX/platform only, never a rule change.

## The eight paid-for lessons (pilot `entrelares-console` — each was a real defect)
1. Restored session ≠ live session: gate app open with `refreshSession()` BEFORE routing;
   failure → `signOut(scope: local)` + "sessão expirada". Add an `onAuthStateChange`
   listener that returns to login when the session dies mid-use.
2. Without a valid session the client is `anon` (zero privilege, 100% RLS) — map
   `42501` / `permission denied for function` to "Sessão expirada" centrally.
3. `signOut()` with a dead token THROWS → catch, fall back to `SignOutScope.local`,
   navigate ALWAYS.
4. `refreshSession()` best-effort before sensitive operations; propagate the server's own
   error text (`FunctionException.details['error']`), never collapse failures.
5. **`INTERNET` permission is missing from `src/main/AndroidManifest.xml`** in the
   `flutter create` template — release APK gets no network, looks like DNS. Already fixed
   here; first thing to re-check on any new Flutter module.
6. Debug keystore is per machine — create the real keystore early, outside the repo.
7. `--split-per-abi` for direct distribution (~18 MB arm64 vs ~52 MB universal); `.aab`
   for Play.
8. Supabase singleton initializes once per process → environments via flavors (see table).

## Build & test
```
cd packages/entrelares_core && fvm dart analyze --fatal-infos && fvm dart test
cd apps/entrelares_app && fvm flutter analyze && fvm flutter test
# The two source gates live in that suite: no_literal_snack_test (catalog strings)
# and no_color_literal_test (U-27 — colours only in lib/theme/tokens.dart).
cd apps/entrelares_app && fvm flutter build apk --debug --flavor dev --split-per-abi
# Canal web: os dois flags NÃO são opcionais — sem o define o build aponta para o
# banco de QA, e sem o --no-web-resources-cdn o CanvasKit vem do gstatic.
cd apps/entrelares_app && fvm flutter build web --release --no-web-resources-cdn --dart-define=APP_ENV=prod
```
⚠️ O lane core do `verify.yml` roda **`dart analyze --fatal-infos`**, não `dart analyze`:
uma info (ex.: `unnecessary_brace_in_string_interps` num `reason:` de teste) derruba o job
— e como esse é o PRIMEIRO passo, os lanes de app e web nem chegam a rodar. Rodar o
comando acima antes do push é o que separa um push verde de um `main` vermelho (lote 5,
20/08/2026).

**Alvo web (lote 6):** habilitado em 19/08/2026 — Flutter Web SUBSTITUI o PWA (tensão 1)
e o `verify.yml` compila o web em todo push, imprimindo o peso gzip do first-load no
summary do run. O aceite do CANAL continua sendo medição real em Android mediano/4G,
que só o owner pode fazer.
Lane E2E (aberta no lote 3): `apps/entrelares_app/integration_test/` — app real em
emulador contra o projeto dev, família descartável (`E2E-<runId>`, `@resend.dev`,
`purge_e2e_family` no teardown). Fora do gate por custo de minutos: agendada
(06:10 UTC) + `workflow_dispatch` (`run-e2e`, `e2e-pack` p0/full). A service_role do
dev chega só por `--dart-define` a partir do secret `SUPABASE_SERVICE_ROLE_DEV`.
Cloud sessions: `bash tool/setup_env.sh && source tool/env` (hosts needed:
`storage.googleapis.com`, `dl.google.com`, `pub.dev` — all reachable in this product's
cloud policy; if one is blocked, STOP and report the domain, no unofficial mirrors).

## Rules
1. Secrets never enter the repo. `env.dart` carries only PUBLIC client config (same as the
   web app's `appsettings.json`); the anon key has zero privilege by construction (T-44).
2. Every pure rule lives in `packages/entrelares_core` with `dart test` coverage — the
   same mirror-test philosophy as the app's C# helper suites. The app package only
   orchestrates and presents.
3. Flutter version changes only by explicit owner decision recorded on the board.
4. One scope per session; end each session with a clear summary block for the board.
