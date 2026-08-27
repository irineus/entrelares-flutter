---
name: next-item
description: Start a backlog item end-to-end for Entrelares — pick it from the Notion board (or take the ID passed as argument), read row + page + repo record, run the analysis/gap-question step, implement with tests on a fresh branch, and close out board + backlog in the same delivery. Use at session start when the user wants to develop the next (or a specific) backlog item — "próximo item", "novo item", "vamos desenvolver o F-NN / L-NN". Covers the product app (F-/U-/T-/S- in entrelares-flutter) and the landing (L- in entrelares-site).
---

# next-item — develop one backlog item, end to end

You are starting a development item for **Entrelares**. This skill sequences the working
rhythm; the `CLAUDE.md` files remain the authority on every convention — on any conflict,
`CLAUDE.md` wins. Interact with the user in PT-BR.

An argument may have been passed (e.g. `/next-item F-42`): treat it as the item ID.

## 0 · Where things live right now (read this first — it is moving)

The T-53 cutover (23/08/2026) made **both product channels Flutter**, and the archiving of
`entrelares-app` is under way. Until it finishes, an item is **recorded in one repo and
delivered in another**:

| What | Where, today |
|---|---|
| **Code** of a client item (`F-`/`U-`/`T-`/`S-`) | `entrelares-flutter`, branch **`main`** |
| **Code** of a landing item (`L-`) | `entrelares-site`, branch **`preview`** |
| Backlog **records** + `archive/phase-*.md` | **here**, in `backlog/` — the mirror reads them from this repo since 24/08/2026 |
| **Migrations + Edge Functions** | **here**, in `supabase/`. A PR applies them to the **dev** project before the gate runs; a merge to `main` applies them to **production** (job `db-prod`) before the web channel publishes |
| **The DB gate** (237 tests over RLS/RPCs/triggers) | **here**, in `packages/entrelares_db_gate/` — job `db-gate` of `verify.yml`. Pure Dart since T-56 PR 16 (24/08/2026), and the only copy: the app repo's C# suites went with the emptying |
| **Play listing + brand masters** | **here**, in `store/` (T-56 PR 4c) — the TWA/Bubblewrap project stayed behind, and retiring that package is **T-52** |
| The old Blazor client | `entrelares-app`, **shut down and archived** (24/08/2026). It holds the frozen client and its unit suite, nothing else, and nothing is deployed from it. Nothing there needs to be read to work here |

**T-56 is CLOSED** — the table above is the settled layout, not a transition. The code closed on
24/08/2026 and the owner's console work on 25/08: `entrelares-app` is **archived**, and
`legado.entrelares.app` no longer resolves. Nothing about the product lives outside this repo and
`entrelares-site`. The plan, the measurements and the PR-by-PR record are in
[`docs/arquivamento-app.md`](../../../docs/arquivamento-app.md). **If a row above no longer
matches reality, that doc is the authority and this table is stale: fix it in the same
delivery.**

## 1 · Preconditions

- Confirm the **Notion MCP connector** is active. If it is not, STOP and tell the user —
  never guess an item's status (the markdown carries no status summary).
- Check the toolchain before planning around it: does `fvm` exist (app: `fvm flutter`,
  `fvm dart`) / `npm` (landing Worker)? If not, every line is written blind — write against
  the surrounding patterns, split into smaller deliveries, and treat CI as the first
  compiler (see `CLAUDE.md` Build & test).

## 2 · Pick the item

- **With argument:** use that ID.
- **Without argument:** take the first row of the board's execution queue:
  ```
  query_data_sources → mode "sql", data_source_urls
    ["collection://109b1b02-5b6b-48ef-b3b6-990374a3d10f"]
  SELECT "userDefined:ID", "Item", "Repo", "Grupo roadmap", "Ordem",
         "Esforço gasto (h)", url
  FROM "collection://109b1b02-5b6b-48ef-b3b6-990374a3d10f"
  WHERE "Status" = 'pending' ORDER BY "Grupo roadmap", "Ordem" LIMIT 5
  ```
  The first row is the next item; show the user the top of the queue and confirm the pick.
  Gotchas (they cost time before): the column is `"userDefined:ID"`, never `ID`; a column
  alias is NOT usable in `WHERE`; the query is metered — fetch everything needed in ONE call.
- The ID prefix selects the repo: `L-*` → **`entrelares-site`** (base branch `preview`),
  everything else → **`entrelares-flutter`** (base branch `main`). The board's `Repo`
  column may still say the pre-cutover value on old rows — the prefix wins.
- **Rename the session** to the item being implemented — `<ID> — <item name>` (e.g.
  `F-50 — Viewer member`) — as soon as the pick is confirmed, so the session list
  identifies the work at a glance. Right after renaming, **move the session into the
  "Guarda Compartilhada" session group/project**, so all the project's sessions live
  together. Use the harness's session-management capability if one is exposed (search the
  available tools for rename/move); as of Aug 2026 none is — in that case say so ONCE and
  ask the user to do both in the UI, instead of silently skipping.

## 3 · Read before writing

- Fetch the item's Notion **page body** (the row `url`) and read the **markdown record**
  (see the table in §0 for where it lives) — the markdown is the source of truth for what
  the item IS; the row for whether it is still wanted and what was already spent.
- Staleness check: the record repo may run ahead of what is published. If board and repo
  disagree, the repo wins. Confirm the item is not already done or superseded before
  investing in it.

## 4 · Analysis and gap questions — BEFORE any code

Present a concise analysis: scope, files touched, risks, dependencies (check the item's
`Depends on`/prerequisites against the board), test plan, and whether the item needs a
migration/Edge Function. Then ask the gap questions via **AskUserQuestion**. Only start
implementing after the decisions are locked. If the item is big, propose a split into 2–3
incremental PRs (each with its docs/backlog closeout inline) and get the user's pick.

## 5 · Implement

- **Fresh branch from the CURRENT base** (`main` for the app, `preview` for the landing) —
  never reuse a merged branch (squash merges orphan its history). Suggested name:
  `feature/<item>-<slug>`.
- Tests ship with the feature in the same item: every **pure rule** gets a mirror in
  `packages/entrelares_core` with `dart test`; screens get widget tests; **DB rules go to
  `packages/entrelares_db_gate`** (a suite library under `test/suites/`, wired into the
  aggregating entrypoint — see §0); two-user flows to the `integration_test` lane.
- **Run the gate locally before pushing** — the core lane uses `--fatal-infos`, so a single
  info-level lint (e.g. `unnecessary_brace_in_string_interps` inside a test `reason:`)
  fails the job, and because it is the FIRST step the app and web lanes never even start:
  ```
  cd packages/entrelares_core && fvm dart analyze --fatal-infos && fvm dart test
  cd apps/entrelares_app && fvm flutter analyze && fvm flutter test
  ```
  If the item touched the database, run the DB gate too (needs the DEV service_role key,
  never the production one):
  ```
  cd packages/entrelares_db_gate && E2E_SUPABASE_SERVICE_ROLE_KEY=<chave dev> fvm dart test
  ```
  That suite also holds the two source gates: `no_literal_snack_test` (catalog strings) and
  `no_color_literal_test` (U-27 — colours only in `lib/theme/tokens.dart`).
- Migrations via `supabase migration new` in `supabase/migrations/`; Edge Functions redeploy
  from `verify.yml` — and a NEW function must be added to `.github/functions.sh`, or the
  drift guard fails the run rather than letting it be silently never deployed.
- **Version bump** in the SAME delivery for any functional change: `version:` in
  `apps/entrelares_app/pubspec.yaml` (`0.2.x+NN` — BOTH halves; the `+NN` is the Android
  `versionCode` and the Play Console refuses a repeated or lower one). Internal-docs-only
  work skips it.
- Commit (PT-BR, conventional style) and push to the session's work branch. Report what
  was done.

## 6 · Gate: PR and merge

**PR + squash-merge only with the user's explicit OK — never automatic.** The `Backlog: <ID>`
trailer lives at the END of the PR body (only if this PR delivers the item; delete the line
otherwise) — it is what links the commit to the item in the board mirror, and a commit that
loses it needs a hand-written entry in `tool/notion_mirror.py`.

Unlike the old app repo, **`verify.yml` runs on the PR itself** (`pull_request` trigger), so
the gate is green before the merge, not after it.

## 7 · Close-out — all in the SAME delivery

1. Entry status updated in the markdown + record moved to `archive/phase-N.md` (`Fase 7`
   since 03/08/2026 — "Public Availability & Product Depth"; landing records stay in
   `ROADMAP.md` and never set `Fase`).
2. The Notion row: `Status`, `Conclusão`, `Esforço gasto (h)`, `Fase`, and clear
   `Grupo roadmap`/`Ordem`.
3. Regenerate the item's page body:
   ```
   python tool/notion_mirror.py -o mirror.json
   ```
   (run from the `entrelares-flutter` checkout; it finds the sibling repos by default)
   then `update-page` with `command="replace_content"` for the item's page. Never
   hand-edit the Notion body.
4. **Documentation sweep — the docs must not wait for a promotion to catch up.**
   `grep -rn '<ID>'` across the record files, `README.md` and `CLAUDE.md` of the repos the
   item touched, and fix every hit that still describes the item as pending/future:
   - the roadmap section of `backlog/README.md`: remove the item's row from its group
     table; if the group EMPTIED, say so in the group heading/intro; fix status-summary
     phrases that counted items ("all four gates" → "all five").
   - `README.md`: feature tables/capability lists gain the delivered feature; test-suite
     counts and inventories reflect any new test files.
   - `CLAUDE.md`: the Build & test inventories mention new suites/gates; touch the Overview
     ONLY for what changed in PRODUCTION.
   These edits ride the SAME delivery/PR as the close-out (internal docs — no extra version
   bump beyond the item's own).

## 8 · After the merge

**A merge to `main` publishes to real users.** Since the cutover the `deploy-web` job
publishes `web.entrelares.app` from every green push to `main` — there is no QA branch in
between, so the QA that used to happen after the merge now has to happen BEFORE it: on the
PR's green gate, and on a dev-flavor build when the change needs a real device
(`workflow_dispatch` → `build-apk`). The Android channel is the exception: it ships only
when the owner promotes a bundle in the Play Console.

QA feedback lands in a NEW commit/PR — realign the branch onto the current base first. If
the session watches the CI run, schedule the check-in for the last completed run's duration
+ 1 minute.
