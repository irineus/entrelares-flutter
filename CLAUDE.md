# CLAUDE.md — Project context for Claude Code

## What this repo is
The **T-53 rewrite** of Entrelares (Blazor WASM PWA, repo `entrelares-app`) in
**Flutter/Dart**. Born as the stage-1 spike (GO verdict, 19/08/2026); **stage 3 is open**:
this repo is becoming the product app, built batch by batch per the parity map
(`entrelares-app/docs/flutter-paridade.md`, order 1→2→3→4→6→5) behind the cutover plan
(`entrelares-app/docs/flutter-cutover.md`). The Blazor app is frozen (owner policy,
19/08/2026) and stays in production until the stage-4 cutover.

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
cd packages/entrelares_core && fvm dart test
cd apps/entrelares_app && fvm flutter analyze && fvm flutter test
cd apps/entrelares_app && fvm flutter build apk --debug --flavor dev --split-per-abi
```
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
