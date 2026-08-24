# Release checklist — v1.6.1 → v1.6.23 (first Phase-6 production promotion)

Tailored, filled-in checklist for **this** promotion. It complements the generic
prod-promotion checklist in [`README.md` §7](README.md#7-prod-promotion-checklist-dev--master)
— follow this one top to bottom. The app repo's flow is `feature → dev (QA) → master (prod)`,
promoted `--ff-only` (`GitHelp.md`).

**What CI does automatically on the `master` push** (it holds `SUPABASE_*_PROD`): apply
pending migrations → deploy all 6 Edge Functions → publish the app to Cloudflare — in that
order, aborting the publish if the schema push fails. Everything below is what CI does **not**
do: prod-Dashboard config (a separate Supabase account) + the git promotion itself.

> **State at authoring:** prod app = **v1.6.1**; QA/`dev` = **v1.6.23** (34 commits ahead,
> `--ff-only` verified possible). Prod carries all of Phase 6: analytics (T-37), freemium
> foundation (F-32), the PDF-report wedge (F-33), the four per-feature gates (F-37/38/39/40),
> the config table (T-41), plus S-14/T-34.

---

## Migration state — reconciled (2026-07-25)

Prod's `supabase_migrations.schema_migrations` was compared against the 34 canonical files in
`supabase/migrations/`. Result: **prod has the first 26 canonical migrations, in order,
contiguous — no drift to repair.** The **8 trailing** migrations (the Phase-6 monetization
block) are genuinely pending and CI's `db push` applies them in order on the `master` push:

```
20260723120000 f32_family_plan_and_premium_interest
20260723140000 s14_drop_legacy_always_true_policies
20260724120000 f37_gate_third_caregiver_premium
20260724140000 f39_planning_horizon_gate
20260724150000 t41_app_settings
20260724160000 f38_email_quota_gate
20260724170000 t41_lock_settings_writes
20260724180000 f40_admin_override_tier
```

- [ ] **(optional, belt-and-suspenders)** confirm the 8 pending objects don't already exist on
  prod — expect all empty/`false` (proves no physical drift for the pending set):
  ```sql
  select to_regclass('public.app_settings')                                    as app_settings_table,
         exists(select 1 from information_schema.columns
                where table_name='families' and column_name='plan')             as families_plan_col,
         exists(select 1 from information_schema.columns
                where table_name='families' and column_name='premium_interest') as premium_interest_col;
  ```
- No `supabase migration repair` is required. (Re-verify with the compare query if `dev`
  gains more migrations before the promotion.)

---

## 🔴 Prod-side prep — do ALL of this BEFORE the `master` push

Every step is in the **prod** Supabase account's Dashboard/SQL editor (a separate account —
nothing from dev/QA propagates). Runbook section numbers in parentheses.

- [ ] **1. Back up prod data first** (Free plan has no automatic backups). Linked to prod:
  `npx supabase db dump --linked --data-only -f data_2026-07_prod.dump.sql` — **never commit**
  (`*.dump.sql` is gitignored). Verify `supabase/.temp/project-ref` is the **prod** ref first.
- [ ] **2. Migrations** — nothing to reconcile (see above); CI applies the 8 pending. Optional
  existence check above.
- [ ] **3. JWT signing state (S-16)** — Dashboard → **JWT Keys**: confirm **HS256 is *Current***
  (roll back if prod auto-migrated to ES256: Standby the ES256 key → Rotate). Otherwise
  `register-invitee`'s `admin.createUser` fails and invite sign-ups break first.
- [ ] **4. Edge Function secrets** (Edge Functions → Secrets): `RESEND_API_KEY` (a **prod**
  Resend key), `RESEND_FROM_EMAIL` (on the verified domain), `RESEND_FROM_NAME=Guarda Compartilhada`,
  `APP_URL=https://app.guardacompartilhada.com` (no trailing slash), `APP_ENVIRONMENT=Production`.
- [ ] **5. Auth settings** (Authentication): Confirm email **ON**; minimum password length **8**;
  Site URL = `https://app.guardacompartilhada.com`; Redirect URLs `.../login` (or `/**`);
  **PT-BR templates** for Confirm signup + Reset (§5.4); **"Secure email change" ON**; auth
  rate limit ~30/h (§5.5).
- [ ] **6. Custom SMTP via Resend** (§5.5): host `smtp.resend.com`, port `465`, user `resend`,
  password = the prod `RESEND_API_KEY`, sender = the same `RESEND_FROM_EMAIL`/`_NAME`. Verify
  the domain's SPF/DKIM/DMARC are green in Resend (DMARC `p=none` at first).
- [ ] **7. Crons** (§4): enable `pg_net` + `pg_cron`; store the prod `service_role` key in Vault
  (`select vault.create_secret('<KEY>', 'service_role_key');`); create
  `auto-approve-expired-hourly` (`0 * * * *`) and `purge-deleted-daily` (`0 4 * * *`) with the
  **prod** ref URL and the `Authorization: Bearer` header from the Vault secret (§4.4/§4.5 —
  never the Dashboard's empty-headers default).
- [ ] **8. CI prod secrets exist** (GitHub → Settings → Secrets and variables → Actions):
  `SUPABASE_ACCESS_TOKEN_PROD`, `SUPABASE_PROJECT_REF_PROD`, `SUPABASE_DB_PASSWORD_PROD`
  (+ the Cloudflare secrets). Without them the `master` pipeline can't reach prod.

---

## 🟢 The promotion (only after 1–8, on explicit go)

```bash
git checkout dev    && git pull origin dev
git checkout master && git pull origin master
git merge dev --ff-only
git push origin master
```

Triggers the prod pipeline: **full E2E gate → `db push` (8 pending) on prod → 6 Edge Functions
→ app publish**. Longer than a `dev` run (full E2E pack). Watch it to green.

---

## ✅ Post-deploy verification (§6/§7)

- [ ] **Security advisors** (Advisors → Security): no RLS-disabled / anon-exposed errors.
- [ ] **Workflow smoke test**: sign in, calendar loads, create + approve a swap, priority tag
  shows. Login footer reads **v1.6.23**.
- [ ] **Sign-up smoke test**: `/register` → "Confirme seu e-mail" → PT-BR confirmation e-mail
  arrives → confirm → sign in → send an invite → invite e-mail arrives with a working link.
  Clean up the throwaway users afterwards.
- [ ] **Backup go-live (T-19, §7.7)**: create the private R2 bucket `guarda-backups` + a
  bucket-scoped token, add the 4 secrets (`BACKUP_PASSPHRASE` — keep an offline copy —,
  `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`), then run the "Weekly encrypted
  backup" workflow once and confirm the object lands in R2.
- [ ] **Schema snapshot**: `npx supabase db dump --linked -f snapshot_2026-07.sql` → move into
  `database/snapshots/` (schema only — no `COPY`/`INSERT` lines).
- [ ] **Flip the "prod = v1.6.1" doc claims** to v1.6.23 (`CLAUDE.md`, `backlog/README.md`,
  README feature/version prose) — same delivery as the promotion.
- [ ] **Landing consistency**: confirm `RESEND_API_KEY` is set on the prod Worker, then promote
  the landing `preview`→`main` so guardacompartilhada.com matches the repositioned F-33
  ("Relatório do histórico em PDF").

---

## Known test-coverage gaps to watch after launch (from the pre-deploy review)

Not blockers, but the first areas to harden (fast-follow): the Edge-Function priority-tag
mirror has no direct test; scenario-C (F-28) is enforced client-side only (no adversarial DB
test); the revert/F-26 restore and the scenario-B message text are guarded only by the
prod-gated p1 E2E pack. The `dev` E2E gate runs only the p0 smoke pack, so run the **full pack**
via `workflow_dispatch` before promoting (done for this release).
