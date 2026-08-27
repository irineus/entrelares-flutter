# Supabase — QA & Production Deploy Runbook

**This is the source-of-truth checklist for deploying the backend** (database
migrations, Edge Functions, cron and Dashboard configuration) plus the app-publish
step that is coupled to it. Follow it top to bottom; nothing should be done from memory.

Everything is **per Supabase project**: run the whole runbook on **QA** first
(the CLI baseline + migrations are already applied on the existing environments),
validate with step 6, then repeat on **prod**.

---

## Deploy order & couplings — read this first

The six steps below are ordered because they depend on each other:

```
1. DB migrations  →  2. Edge Functions  →  3. Publish the app  →  4. Cron  →  5. Auth settings  →  6. Verify
```

> **Since T-29 (Phase 4), steps 1–3 are AUTOMATED by CI/CD**: pushing `dev` or
> `master` runs `supabase db push` (pending migrations), deploys both Edge
> Functions and publishes the app — in that exact order, aborting the app
> publish if the schema push fails. Steps 4–5 remain per-project Dashboard
> work, and step 6 remains the human verification. The manual procedures below
> are kept as **fallback** and for one-off environments.

> **Historical note:** the V007–V010 couplings below are from the Phase-4 CLI
> cutover and are long past on **both** environments (prod is at v1.6.1, well
> beyond V010). They are kept as a worked example of *why* migrations, functions
> and the app publish are ordered — not as live steps for the current promotion.

- **Migrations ↔ app are coupled (V010):** the OLD app build still sends the
  `is_urgent` field when creating swap requests; once V010 drops the column,
  creating a swap in the old app **fails**. The reverse also breaks (the new
  app needs V008 RLS / V009 RPCs). So: apply the migrations and **publish the
  new app immediately after** (steps 1 → 3, same maintenance window).
- **Migrations ↔ `send-swap-email` are coupled (V009/V010):** the deployed
  function copy must know the F-15 `invitation` type and must NOT expect the
  client's `isUrgent` — always redeploy it in the same window (step 2).
- **The cron needs the function** (step 4 after step 2), and the function's
  RPC comes from V007 (step 2 after step 1).

> **Account architecture (consolidated July 2026 — supersedes the old two-account
> split):** dev/QA and prod live under **ONE Supabase login** (`irineus@gmail.com`)
> in **two separate organizations** — dev/QA in a **Free** org, prod in a **Pro**
> org — so both are reachable from one Dashboard session with no extra per-project
> fee. CI-token isolation never depended on separate accounts: it comes from
> per-project service_role keys plus the two **named** account-level access tokens
> (`SUPABASE_ACCESS_TOKEN_DEV`/`_PROD`, see `deploy.yml`) — named tokens buy
> per-pipeline revocation and audit, not scoping. Dashboard steps below: same
> login, pick the right org/project. Watch two Free-org effects: dev
> **auto-pauses after 7 days idle** (`.github/workflows/keepalive-dev.yml` pings
> it twice weekly) and the MCP/OAuth connector is **scoped to one org per
> connection** (keep it on dev day-to-day; reconnect to the prod org for prod work).

**Per-environment values** used throughout the steps:

| Value | QA | Production |
|---|---|---|
| App URL (`APP_URL` secret, Site URL, Redirect URLs) | **`https://web.entrelares.app` — the same value as production, since 27/08/2026.** Dev has had NO web deployment since T-56 killed the Blazor QA site, so there is no dev-specific host left to name. It used to say `qa.entrelares.app`, which did not stop resolving when that deployment died — it became a ghost serving a stale build, which is worse than a dead host because it answers. Cost of the alignment, worth knowing before it confuses someone: a DEV invitation e-mail now points at the PRODUCTION web app, whose database has no such token, so it says "convite inválido" — dev invite testing happens inside the app, never from the inbox (§9-ter) | `https://web.entrelares.app` (F-54, Aug 2026 — the apex `entrelares.app` hosts the product **landing page**; e-mail/DNS records stay on the apex; the pre-rebrand `app.guardacompartilhada.com` 301-redirects here indefinitely) |
| `APP_ENVIRONMENT` secret | anything ≠ `Production` (e.g. `QA`) → notifications/e-mails prefixed `[Dev]` | `Production` (no prefix) |
| App publish trigger (step 3) | push/merge to the `dev` branch | push/merge to `master` |

---

## 0. Prerequisites — values to gather first

From the Supabase Dashboard of the **target** project:

| Value | Where |
|---|---|
| **`<project-ref>`** | Project Settings → General → **Reference ID** (also the subdomain of your API URL, `https://<project-ref>.supabase.co`) |
| **`<SERVICE_ROLE_KEY>`** | Project Settings → **API** → Project API keys → **`service_role`** (`secret`). ⚠️ Full-access key — never put it in client code or commit it |

Tools: **Supabase CLI** (`npx supabase …`, run from the repo root) and access to the
project's **SQL Editor**.

**CI secrets (one-time, GitHub → Settings → Secrets and variables → Actions).**
The T-29 pipeline steps need, besides the existing app/Cloudflare secrets:

| Secret | Value |
|---|---|
| `SUPABASE_ACCESS_TOKEN_DEV` / `_PROD` | two personal access tokens — supabase.com/dashboard/account/tokens, named e.g. `ci-qa` and `ci-prod`. ⚠️ Tokens are **account-scoped** (either can manage any project); two named tokens buy per-pipeline **revocation and audit**, not isolation |
| `SUPABASE_PROJECT_REF_DEV` / `_PROD` | each project's Reference ID (same as `<project-ref>` above) |
| `SUPABASE_DB_PASSWORD_DEV` / `_PROD` | each project's **database** password (Project Settings → Database) |

---

## 1. Database migrations — automated (T-29)

The pipeline runs `supabase db push` on every push to `dev`/`master`, applying
**only the pending** `supabase/migrations/*` files (tracked per environment in
`supabase_migrations.schema_migrations`) — nothing to do manually. Authoring
flow and conventions: [`database/README.md`](../database/README.md).

Check an environment's state:

```
npx supabase link --project-ref <ref>
npx supabase migration list
```

**Manual fallback** (CI unavailable / one-off environment): `npx supabase db push`
with the same link — it is idempotent, so running it locally and letting CI
re-run later is safe.

> ⚠️ **Before ANY local `db push`, check the link**: `cat supabase/.temp/project-ref`
> must show the DEV ref (`buroanotfjcgvbfmacuh`). The CLI link is sticky, invisible
> state that survives across sessions — on 2026-07-15 a stale PROD link (left by an
> old backup dump) sent a migration straight to production. Since the July-2026
> account consolidation one login reaches BOTH projects, which makes a stale
> link even easier to follow by accident — always check before pushing. CI is
> immune (explicit link + per-pipeline token every run).

> **History note:** the pre-CLI era (V001–V010, `database/migrations/VNNN__*`,
> tracked in `public.schema_migrations`) is frozen. Its CLI-era equivalent is
> the baseline migration `20260713000000_baseline_v1_4_0.sql`, marked as already
> applied on the existing environments during the T-29 cutover
> (`supabase migration repair --status applied 20260713000000`).

After each **production** deploy, refresh `database/snapshots/` with a **schema** dump:

```powershell
npx supabase link --project-ref <prod-ref>
npx supabase db dump --linked -f snapshot_YYYY-MM.sql   # asks for the DATABASE password
Move-Item snapshot_YYYY-MM.sql database\snapshots\
```

> ⚠️ **Windows path gotcha:** the CLI resolves `-f` against its own working
> directory, not necessarily your shell's — a relative path like
> `database/snapshots/…` fails ("cannot find the path") and a bare filename may
> land in `%USERPROFILE%`. Dump to a bare filename, then find it (repo root or
> home) and `Move-Item` it into place.

> **Privacy rule:** only the **schema** snapshot is committed. A **data** backup
> is worth taking too (the Free plan has no automatic backups) but must never
> enter git — `npx supabase db dump --linked --data-only -f data_YYYY-MM.dump.sql`;
> the `*.dump.sql` name is already gitignored. Verify the committed snapshot has
> no `COPY`/`INSERT` lines before pushing.

> **Full backup & disaster-recovery reference (T-19):** the cadence, the
> encryption/retention rules for PII dumps (row data **and** `auth.users`), and
> the step-by-step **restore procedure** live in the README's
> [Backup & Recovery](../README.md#backup--recovery) section. An optional
> ready-to-enable weekly encrypted backup workflow sits at
> [`.github/workflows/backup.yml`](../.github/workflows/backup.yml) (disabled by
> default). The Free plan has no PITR — upgrading to Pro is the recommended
> durability step before public availability.

---

## 2. Edge Functions — secrets, then deploy

**2.1 Secrets** (Dashboard → Edge Functions → Secrets). `SUPABASE_URL`,
`SUPABASE_PUBLISHABLE_KEYS` and `SUPABASE_SECRET_KEYS` are injected automatically
**once the new API keys exist on the project** (S-16, section 10.1) — the
functions read those and fail without them, so confirm they are listed here
before deploying. The legacy `SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY` are
still injected but no longer read by any function. Set the rest:

| Secret | Value |
|---|---|
| `RESEND_API_KEY` | your Resend API key |
| `RESEND_FROM_EMAIL` | sender on the **verified** Resend domain — `noreply@entrelares.app` after the F-54 promotion-A cutover; until that cutover the verified domain (and thus the sender) is still `guardacompartilhada.com` (see 5.6 and 5.8) |
| `RESEND_FROM_NAME` | `Entrelares` |
| `APP_URL` | the environment's app URL (per-environment table above; **no trailing slash, must be public** — a `localhost` link in an e-mail is a spam signal) |
| `APP_ENVIRONMENT` | `QA` on QA, `Production` on prod (per-environment table above) |
| `ASAAS_API_KEY` | T-39: Asaas API key of **that** environment's account (sandbox on QA, the real account on prod) |
| `ASAAS_WEBHOOK_TOKEN` | T-39: shared token the `billing-webhook` demands in `asaas-access-token`; must match the value registered in the Asaas dashboard webhook. **Use a fresh value in prod** — never the sandbox one |
| `ASAAS_API_URL` | T-39: **sandbox is the code default, so production MUST opt in** with `https://api.asaas.com/v3`. Leaving it unset in prod silently keeps real families billing against the sandbox |

**2.2 Deploy — automated (T-29):** the pipeline deploys **all eight** functions on
every push, right after the migrations (see `deploy.yml`). Manual fallback:

```
npx supabase login
npx supabase link --project-ref <project-ref>
npx supabase functions deploy send-swap-email      --project-ref <project-ref>
npx supabase functions deploy auto-approve-expired --project-ref <project-ref>
npx supabase functions deploy register-invitee     --project-ref <project-ref>
npx supabase functions deploy elevate              --project-ref <project-ref>
npx supabase functions deploy purge-deleted        --project-ref <project-ref>
npx supabase functions deploy send-account-email   --project-ref <project-ref>
npx supabase functions deploy billing-webhook      --no-verify-jwt --project-ref <project-ref>
npx supabase functions deploy billing-checkout     --project-ref <project-ref>
```

> `billing-webhook` **must** carry `--no-verify-jwt`: Asaas calls it server-to-server
> with no Supabase JWT, and its own auth is the `asaas-access-token` shared secret.
> Deploying it without the flag makes every webhook 401 — payments confirm at the
> provider and the family never turns premium.

| Function | Purpose |
|---|---|
| `send-swap-email` | Transactional e-mails (Resend) for every workflow event, the F-24 `reminder`/`auto_approved` types, the F-15 `invitation` type; computes the F-20 priority tag at send time |
| `auto-approve-expired` | Cron worker (F-24): calls the `auto_approve_expired()` RPC (24 h reminders + 48 h auto-approval) and dispatches e-mails via `send-swap-email` |
| `register-invitee` | F-15 invite sign-up: `admin.createUser` + profile/family wiring for a user joining via an invitation link (first casualty if the JWT key is on ES256 — see S-16) |
| `elevate` | S-10 sudo elevation: mints a short-lived admin-mode token for the guarded destructive actions |
| `purge-deleted` | S-11 cron worker: hard-deletes accounts (and families) past their 30-day grace. Also carries the retention/notice duties added since: `purge_old_notifications` (S-13, read notices > 6 months), **`purge_stale_invitations`** (S-15/A-4, never-accepted invitations > 30 days — what makes the invite e-mail's purge promise true) and **`billing_grace_warnings_due`** (S-15/B-3, warns admins by e-mail before the Premium grace expires; the RPC writes the in-app notice, the e-mail here is the best-effort twin) |
| `send-account-email` | S-11 account-lifecycle e-mails (deletion scheduled/cancelled, family-deletion consent); mirrors the F-20 priority tag in `America/Sao_Paulo`. S-15/B-3 added `premium_grace_ending` — the only type that e-mails ONLY the subject (a family admin), since billing is admin-only |

| `billing-webhook` | T-39: receives Asaas events (auth = the `ASAAS_WEBHOOK_TOKEN` shared secret in `asaas-access-token`, hence `--no-verify-jwt`). **Idempotent by the provider's event id** — a redelivery is recorded and ignored — and applies every effect through `set_family_plan`, adopting the subscription created by the payment link (`externalReference family:<id>`, link-id fallback) |
| `billing-checkout` | T-39: called with the **user's** JWT and admin-only (guard chain 401→403→409→503); creates the Asaas Payment Link (`RECURRENT`, `dueDateLimitDays` — the API rejects it without one) so payer data is typed only on the provider's PCI page, and handles `cancel` honouring the period already paid. Refuses everything while `billing.enabled` is false; gateway failures are audited as `CHECKOUT_ERROR` in the ledger |

> An outdated `send-swap-email` used to silently build **0 e-mails** for unknown
> types — the historical gotcha the automated redeploy-on-every-push eliminates.

---

## 3. Publish the app — automated

The same pipeline publishes the app to Cloudflare Pages **after** migrations and
functions succeed (per-environment table above: `dev` = QA, `master` = prod), so
schema and app always ship together. Clients pick the new version up on the next
visit (the service worker auto-activates new deployments). Details: root
[`README.md`](../README.md) → Deployment.

---

## 4. Schedule the `auto-approve-expired` cron (F-24)

Per project, after step 2 (the function must exist).

**4.1** Dashboard → **Database → Extensions** → enable **`pg_net`**.

**4.2** Dashboard → **Integrations → Cron** → enable the **`pg_cron`** extension.

> **S-16 — a new environment skips straight to the new-key form.** The commands
> in 4.3/4.4/4.5 below are the LEGACY shape (`Authorization: Bearer` + the
> `service_role` JWT), kept because that is what the existing projects still run.
> A project set up from scratch — or one already migrated — stores the **secret
> key** in Vault and sends it on the **`apikey`** header instead: see
> [section 10.3](#103-migrar-os-crons-para-o-header-apikey). The new keys are not
> JWTs and are rejected on `Authorization`.

**4.3 Store the service-role key in Vault** (so the key is not sitting in
plaintext inside the cron command). In the SQL Editor, paste your
`<SERVICE_ROLE_KEY>` from step 0:
```sql
select vault.create_secret('<SERVICE_ROLE_KEY>', 'service_role_key');
```
Confirm it exists (does not print the secret):
```sql
select name from vault.secrets where name = 'service_role_key';
```

**4.4 Create the job** — Cron → **Jobs → Create Job**:
- **Name:** `auto-approve-expired-hourly`
- **Schedule:** `0 * * * *` (top of every hour)
- **Command:** use exactly this (⚠️ **not** the Dashboard's default — see the gotcha):
  ```sql
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/auto-approve-expired',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  ```

> **⚠️ Gotcha (this cost us a debugging session).** If you accept the Dashboard's
> generated command it comes as `headers := '{}'` and `timeout_milliseconds := 1000`,
> and it **fails silently**: an empty-`headers` call carries no credential at all,
> so it is refused — the cron shows a "Last Run" but nothing happens. **Always**
> include the key header (via the Vault secret above) and a real timeout
> (≥ 30 000 ms).
>
> *S-16 changed where the refusal comes from, not the lesson.* It used to be the
> platform's `verify_jwt` gate answering **401 before the function ran**, which is
> why no function logs appeared. These functions now run with the gate off and
> check the key themselves, so an unauthorized cron call **does** show up in the
> function logs (`refused — caller did not present the secret key`) — a much
> faster diagnosis than the silent version. What still breaks it silently is
> sending the key on the wrong header for its format.

### 4.5 Schedule the `purge-deleted` cron (S-11)

Same mechanics as 4.4 — a daily job that hard-deletes accounts past their
30-day grace (and, from PR2, families). The function has `verify_jwt` on, so
the `Authorization: Bearer <service_role_key>` header (Vault secret from 4.3)
is mandatory, exactly like the gotcha above.

- **Name:** `purge-deleted-daily`
- **Schedule:** `0 4 * * *` (daily, 04:00 UTC — off-peak; grace is measured in
  days, so hourly is unnecessary)
- **Command:** as in 4.4 but with
  `url := 'https://<project-ref>.supabase.co/functions/v1/purge-deleted'`.

---

## 5. Authentication settings & e-mail templates (F-15 sign-up)

Once per project, in the Dashboard → **Authentication**. Without these the
self-service sign-up flow does not work as designed.

**5.1 Turn on e-mail confirmation.**
Authentication → **Sign In / Providers** (older UI: "Providers") → click the **Email**
provider → toggle **"Confirm email" = ON** → Save.
*Why:* with this ON, `SignUp` does not create a logged-in session; the user receives a
confirmation link and **cannot sign in before clicking it** (login returns "Email not
confirmed", which the app translates). E-mail is the workflow notification channel
(F-10/F-24), so it must be verified at the door. The register page already assumes this
mode — after sign-up it shows "📧 Confirme seu e-mail" instead of logging in.

**5.2 Minimum password length = 8.**
Same **Email** provider panel → **"Minimum password length"** → change from `6` (default)
to `8`.
*Why:* the register form validates 8+ client-side, but client validation is UX only — if
the server still accepts 6, a direct API call bypasses the rule. Server and client must
agree.

**5.3 Site URL and Redirect URLs.**
Authentication → **URL Configuration**:
- **Site URL** = the environment's app URL (per-environment table above).
- **Redirect URLs**: add `<app URL>/login` (wildcards work: `<app URL>/**` covers all).

*Why:* `SignUpAsync` **and** `SendPasswordResetAsync` send `RedirectTo = <BaseUri>/login`
— where the browser lands after the confirmation / recovery click. GoTrue **only honours
RedirectTo if it is on this allow-list** (open-redirect protection); otherwise it silently
falls back to the Site URL.

That fallback is not theoretical: found in the pre-production round of Aug 2026, the reset
call passed **no** `RedirectTo` at all, so every environment used its Site URL — and DEV's
was still a `https://localhost:7072` from the pre-deploy days. A reset asked for on the QA
app mailed a link back to a machine the reader does not have. The code now states the
redirect (from `BaseUri`, so local, QA and production each point at themselves), but the
allow-list is the other half: **a project whose Redirect URLs do not include its own app
URL silently reverts to the same bug**, with no error anywhere. Check both projects after
any URL change:
- dev/QA → https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/auth/url-configuration
- prod → https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/auth/url-configuration

**5.4 PT-BR templates for the auth e-mails.**

> **Superseded by 5.7 once the Send Email Hook is enabled** (U-13, Aug 2026). While
> the hook is off, GoTrue sends these templates and this section applies as written —
> that is why it is kept. Once 5.7 is done, GoTrue stops sending and these templates
> become dead configuration: the bodies below live in `send-auth-email` instead, in
> **both** languages. Do not edit both places; edit the function.
>
> **"Dead" is not "harmless" — swept 12/08/2026 (F-54).** These templates are the BACK-OUT
> path of a critical flow, and they live ONLY in the Dashboard: unversioned, in two projects,
> invisible to every `grep`. The rebrand went through the whole codebase, both repos and the
> whole infrastructure, and left them saying *"Redefinição de senha — Guarda Compartilhada"* —
> so the one scenario where they get used (the hook is down, someone is locked out and asks
> for a password reset) is exactly the scenario where the brand would be wrong. Settled:
> **PROD keeps hand-maintained PT-BR templates** (a real person receives that e-mail, so it is
> worth the upkeep) and **DEV is reset to the Supabase default** (nobody real receives it; one
> less thing to rot). **Any brand, domain or sender change must sweep the prod templates in the
> same delivery** — all six of them (Confirm signup, Invite user, Magic Link, Change Email
> Address, Reset Password, Reauthentication), subject line included.

Authentication → **Emails** (older UI: "Email Templates") — the defaults are in
English; replace **both** tabs below so they match the app's PT-BR e-mails. In both,
keep `{{ .ConfirmationURL }}` exactly as is (double braces) — it becomes the action
link.

**Tab "Confirm signup":**

- **Subject heading:** `Confirme seu cadastro — Entrelares`
- **Message body** (the link honours the app's `RedirectTo=/login`):

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Confirme seu cadastro</title>
</head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:system-ui,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0">
    <tr><td align="center" style="padding:32px 16px;">
      <table width="100%" style="max-width:480px;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">
        <tr><td style="background:#212529;padding:20px 24px;">
          <p style="margin:0;color:#ffffff;font-size:18px;font-weight:700;">👨‍👩‍👧 Entrelares</p>
        </td></tr>
        <tr><td style="padding:28px 24px;">
          <h2 style="margin:0 0 16px;font-size:20px;color:#212529;">Falta só um passo! ✅</h2>
          <p style="margin:0 0 12px;color:#374151;line-height:1.6;">Sua conta foi criada. Para ativá-la, confirme que este e-mail é seu tocando no botão abaixo:</p>
          <p style="margin:20px 0;">
            <a href="{{ .ConfirmationURL }}" style="display:inline-block;background:#212529;color:#ffffff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600;">Confirmar meu e-mail</a>
          </p>
          <p style="margin:0 0 12px;color:#374151;line-height:1.6;">Depois de confirmar, é só fazer o login no aplicativo.</p>
          <p style="margin:16px 0 0;font-size:12px;color:#9ca3af;">Se o botão não funcionar, copie e cole este link no navegador:<br/><span style="word-break:break-all;color:#6b7280;">{{ .ConfirmationURL }}</span></p>
          <p style="margin:16px 0 0;font-size:12px;color:#9ca3af;">Se você não criou esta conta, ignore este e-mail — nada será ativado sem a confirmação.</p>
          <p style="margin:24px 0 0;font-size:12px;color:#9ca3af;">Esta é uma mensagem automática. Não responda a este e-mail.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
```

**Tab "Reset Password":**

- **Subject heading:** `Redefinição de senha — Entrelares`
- **Message body** (the link carries `type=recovery`, which the app intercepts and
  routes to `/update-password`):

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Redefinição de senha</title>
</head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:system-ui,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0">
    <tr><td align="center" style="padding:32px 16px;">
      <table width="100%" style="max-width:480px;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">
        <tr><td style="background:#212529;padding:20px 24px;">
          <p style="margin:0;color:#ffffff;font-size:18px;font-weight:700;">👨‍👩‍👧 Entrelares</p>
        </td></tr>
        <tr><td style="padding:28px 24px;">
          <h2 style="margin:0 0 16px;font-size:20px;color:#212529;">Vamos redefinir sua senha 🔑</h2>
          <p style="margin:0 0 12px;color:#374151;line-height:1.6;">Recebemos um pedido para redefinir a senha da sua conta. Toque no botão abaixo para criar uma nova senha:</p>
          <p style="margin:20px 0;">
            <a href="{{ .ConfirmationURL }}" style="display:inline-block;background:#212529;color:#ffffff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600;">Redefinir minha senha</a>
          </p>
          <p style="margin:16px 0 0;font-size:12px;color:#9ca3af;">Se o botão não funcionar, copie e cole este link no navegador:<br/><span style="word-break:break-all;color:#6b7280;">{{ .ConfirmationURL }}</span></p>
          <p style="margin:16px 0 0;font-size:12px;color:#9ca3af;">Se você não pediu a redefinição, ignore este e-mail — sua senha continuará a mesma.</p>
          <p style="margin:24px 0 0;font-size:12px;color:#9ca3af;">Esta é uma mensagem automática. Não responda a este e-mail.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
```

**5.5 SMTP — know the built-in limit; use Resend in production.**
The confirmation e-mail is sent by **GoTrue itself, NOT by `send-swap-email`/Resend**.
Two consequences:

- **⚠️ Built-in SMTP rate limit:** Supabase's default SMTP allows only a handful of
  auth e-mails per hour (~2–4). Several sign-ups in a row and e-mails silently stop
  arriving — that is the limit, not a bug.
- **Custom SMTP via Resend** (**recommended for prod**, optional on QA):
  Authentication → **SMTP Settings** (older UI: Project Settings → Auth → SMTP) →
  enable Custom SMTP with: host `smtp.resend.com`, port `465`, username `resend`,
  password = the `RESEND_API_KEY`, sender = the same `RESEND_FROM_EMAIL`/`RESEND_FROM_NAME`
  used by the Edge Function. Auth e-mails then leave through your Resend account —
  no built-in limit, consistent sender across all app e-mails.
  **Status (July 2026): DONE on the DEV project and verified working (DMARC PASS,
  inbox delivery).** The F-54 promotion-A cutover REPLACES the Resend domain with
  `entrelares.app` (one domain on the Free plan — see 5.8); the record below describes
  the original setup and stays the template for the new zone. DNS on
  `guardacompartilhada.com` (Cloudflare) is live: SPF on the
  root and `send.` subdomain, DKIM (`resend._domainkey`), DMARC (`_dmarc`, `p=none`,
  `rua=mailto:irineus@gmail.com`). PROD is a separate project (own org) — nothing
  propagates: repeat this setup there at promotion (section 7), with a separate
  Resend API key. After a few weeks of clean DMARC reports, harden `_dmarc` from
  `p=none` to `p=quarantine` (edit the existing TXT in Cloudflare). Also raise the
  auth e-mail rate limit (Authentication → Rate Limits) — ~30/h is comfortable with
  custom SMTP.
- **⚠️ The Resend allowance is per ACCOUNT, and dev shares it with prod.** One team,
  one verified domain, six API keys (`guardacompartilhada-dev/-prod`,
  `supabase-smtp-dev/-prod`, plus the landing worker) — all drawing on the same
  **100 e-mails/day** of the free plan. So DEV traffic can return 429 to PRODUCTION,
  and because `supabase-smtp-prod` is the GoTrue sender, the casualty is a sign-up
  confirmation or a password reset: the user simply cannot get in, and nothing
  surfaces the failure. **T-49** removed the largest source — the test suites, which
  were ~86 e-mails/day, 100% of the consumption — by suppressing the Resend call for
  `@resend.dev` recipients inside the Edge Functions (`functions/_shared/mail.ts`).
  **Still open, as a configuration step:** the ~12/day of GoTrue auth e-mails on the
  DEV project go out over the custom SMTP above and never touch that code. To take
  DEV to zero, point its SMTP at a capture sandbox (Mailtrap/Ethereal) instead of
  `smtp.resend.com` — the messages stay readable for QA and prod keeps the whole
  allowance. Do NOT fall back to Supabase's built-in SMTP: ~2–4/hour breaks the pack.
  After that, an 80%-quota warning from Resend means real traffic (or a runaway
  send loop) and is worth investigating instead of ignoring.

**5.6 Deliverability — keep e-mails out of spam.**
During F-15 testing the invitation e-mail landed in the recipient's spam folder. The
levers, in order of impact:

- **Verified sending domain in Resend** (resend.com → Domains): add the domain and
  create the DNS records Resend provides — **SPF** and **DKIM** both green. Add a
  **DMARC** record too (`_dmarc` TXT → `v=DMARC1; p=none; rua=mailto:<your-email>`).
  `RESEND_FROM_EMAIL` must be an address **on that verified domain** (never
  `onboarding@resend.dev` in prod).
- **`APP_URL` must be a public URL** — e-mails embed links built from it.
- **Custom SMTP (5.5)** routes the auth e-mails through the same verified domain —
  one consistent sender reputation for everything the app sends.
- A **new domain with low volume** starts with neutral reputation: first e-mails to a
  given provider may still be flagged; asking the recipient to mark "Not spam" trains
  that inbox for all subsequent workflow e-mails.

**5.7 Send Email Hook — the auth e-mails in the READER's language.** *(U-13, Aug 2026)*

*Why:* GoTrue's templates are **one per project** — one body, one language, every
reader. An English tester who asked for a password reset got a Portuguese e-mail while
every screen around them was in English. There is no way to branch inside GoTrue, so
the message has to leave through us: the hook makes GoTrue hand us the user, the action
type and the token, and `send-auth-email` renders it in the recipient's language and
sends it through the same Resend account as every other e-mail here.

> **⚠️ There is no fallback.** With the hook enabled, GoTrue does not send these
> e-mails itself. If the URL is wrong, the function is broken or the secret is wrong,
> **nobody can confirm a sign-up and nobody can recover a password.** That is why the
> probe (step 4) comes BEFORE the toggle (step 5). To back out at any time: turn the
> toggle off — GoTrue immediately resumes using the 5.4 templates.
>
> **This went wrong on the first attempt (Aug 2026), and the symptom named nothing.**
> The hook was pointed at the APP's URL instead of the function's. A static site
> answers `405` to a POST, so GoTrue reported
> `500: Unexpected status code returned from hook: 405` and every sign-up and password
> reset on QA failed — while the Edge Function logs stayed **empty**, because a 405
> from the gateway means the function never ran. If auth e-mails stop and the function
> shows no invocations at all, the URL is wrong; that is the first thing to check, and
> the probe below is what would have caught it.

Per project (dev first, prod at promotion). The URLs below are **literal — copy them,
do not retype a placeholder**; the whole failure above was one wrong URL.

1. **The function must exist first.** CI deploys it on every push (`deploy.yml`
   deploys `send-auth-email --no-verify-jwt`). Confirm the row **send-auth-email** is
   listed:
   - dev → https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/functions
   - prod → https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/functions

   If it is missing, the hook has nothing to call — stop here and let a deploy run.

2. **Set the function's secret FIRST, before the hook exists.** The order is
   deliberate: a hook that is live before its secret refuses every e-mail.

   Open *Settings → Edge Functions → Secrets*:
   - dev → https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/settings/functions
   - prod → https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/settings/functions

   You cannot fill the value yet — it is created with the hook in step 3 — so this step
   is just to know where the screen is. Come back here right after step 3.

   Optional, and only on **dev**: add `MAIL_ENV_PREFIX` = `[Dev] ` (with the trailing
   space) so a QA e-mail is recognisable in the inbox. Leave it unset in production.

3. **Create the hook — but leave it OFF.**
   - dev → https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/auth/hooks
   - prod → https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/auth/hooks

   **Add hook** → type **Send Email** → **HTTPS**.

   > **⚠️ The URL to paste is NOT the address of the page you are standing on.** The
   > line above is where you NAVIGATE; the value below is what you TYPE INTO the URL
   > field. In Aug 2026 the hook was saved with
   > `https://supabase.com/dashboard/project/<ref>/auth/hooks` — the Dashboard's own
   > address, copied from the browser bar — and `supabase.com` answers `405` to a POST,
   > so every sign-up and password reset on QA failed for two hours. Two `https://…`
   > lines next to each other in a runbook is all it takes.

   The value for the **URL** field, copied exactly:

   - dev → `https://buroanotfjcgvbfmacuh.supabase.co/functions/v1/send-auth-email`
   - prod → `https://jptqbwfziyzlhlmoekzu.supabase.co/functions/v1/send-auth-email`

   It must contain `.supabase.co/functions/v1/send-auth-email`. If what you pasted
   contains `supabase.com/dashboard`, `pages.dev` or `web.entrelares.app`, it
   is not the function.

   Save. The Dashboard shows a **secret** shaped `v1,whsec_…`. **Copy it now** — it is
   the only authorization the function has, and the screen may not show it again.

   Now go back to step 2's screen and add the secret:
   - Name: `SEND_EMAIL_HOOK_SECRET`
   - Value: the whole `v1,whsec_…` string, pasted unchanged.

   The function reads it at request time, so it takes effect immediately — no redeploy.

4. **Read the URI back from the hook screen.** This is the check that matters, and it
   is the one that is easy to skip: reopen the hook you just saved and confirm the URI
   field shows what you typed. A Dashboard edit that was never saved looks exactly like
   a saved one until you reload the panel.

   **A `curl` against the function does NOT verify this** — it proves the function is
   up, which is a different fact. In Aug 2026 the hook was left pointing at the app,
   the operator probed the correct function URL, got the expected `401`, and re-enabled
   a hook that was still misrouted; QA stayed broken for two more hours. The only
   things that see the hook's own configuration are this screen and a real e-mail.

   With that confirmed, probe the function itself from PowerShell (substitute the
   dev/prod ref):

   ```powershell
   curl.exe -s -o NUL -w "%{http_code}`n" -X POST "https://buroanotfjcgvbfmacuh.supabase.co/functions/v1/send-auth-email" -H "Content-Type: application/json" -d "{}"
   ```

   Expected: **`401`**. What the other answers mean:
   - **`405`** — the URL is the app, not the function. Fix step 3 before going on.
   - **`404`** — wrong path, or the function was never deployed (step 1).
   - **`200`** — stop. The function would mail an account-recovery link to whatever
     address a caller names; this is exactly what `EdgeFunctionAuthTests` fails on.

   Then check the function's logs are reachable, because they are your only diagnosis
   once the hook is live:
   https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/functions/send-auth-email/logs

5. **Enable the hook** (step 3's page): toggle it **on**. If anything goes wrong from
   here, this toggle is the undo — turning it off restores the 5.4 templates instantly,
   and there is no reason to debug with sign-up broken.

6. **Confirm with a real e-mail.** Ask for a password reset for an account you own,
   from the app:
   - the subject is `Redefina sua senha` (or `Reset your password` if that account
     reads the app in English). If it is still the old
     `Redefinição de senha — Entrelares` (the 5.4 template subject), the hook is not firing and GoTrue
     is using the 5.4 templates;
   - the button's link points at `…supabase.co/auth/v1/verify?…` and its `redirect_to=`
     is the app URL from 5.3, never `localhost`.

   **If no e-mail arrives**, in this order: the function's logs (link in step 4) — an
   empty log means GoTrue never reached it, i.e. the URL (step 3); a
   `SEND_EMAIL_HOOK_SECRET is not configured` line means the secret (step 3); an
   `Auth Logs` entry reading `Unexpected status code returned from hook` names the
   status the URL returned.

7. **After it works, leave 5.4 alone — but do not forget it exists.** The templates stay in
   the Dashboard as the back-out path for the toggle; they are no longer what anybody
   receives, which is precisely why a brand change sails past them (see the sweep note in
   5.4). On PROD they are hand-maintained in PT-BR; on DEV they are the Supabase default.

**5.8 F-54 sender cutover — `guardacompartilhada.com` → `entrelares.app`** — **EXECUTED
12/08/2026** at the promotion-A sitting; kept here as the record of what was done and as
the pattern for any future sender migration. The Resend Free plan holds ONE domain and the old
one is production's live sender, so the migration cannot be pre-staged: e-mails sent
inside the window are silently lost (the app sends fire-and-forget). Sequence, all in one
sitting: (1) Resend → Domains → delete `guardacompartilhada.com` → add `entrelares.app`
(region `sa-east-1`, sending only, tracking off) → paste the DKIM/SPF/MX records it
returns into the `entrelares.app` Cloudflare zone, plus the `_dmarc` TXT with the same
policy the old domain used → Verify (Cloudflare is authoritative — minutes). **(1b)
Recreate EVERY API key that predates the new domain** — a Resend key can be bound to a
single domain, is not editable, and the binding is invisible in the key list; a bound key
starts refusing everything the moment its domain is deleted (see the (6) note below).
Create one key per consumer, named after what it serves and not after the domain
(`entrelares-prod`, `entrelares-dev`, `entrelares-smtp-prod`, `entrelares-smtp-dev`, the
landing worker's), each with *Sending access* on `entrelares.app`, and paste each into its
place BEFORE step (6). (2) Flip
`RESEND_FROM_EMAIL` to `noreply@entrelares.app` on BOTH Supabase projects (no redeploy
needed). (3) GoTrue on both projects: SMTP sender → `noreply@entrelares.app`; on PROD also
Site URL → `https://web.entrelares.app` (5.3). (4) Asaas: add `web.entrelares.app` to the
registered site/callback domains (section 9 prerequisite — without it the hosted checkout
refuses the new callback URLs). (5) Cloudflare: turn on the old domain's 301s (apex and
`app.` → the new equivalents; the old domain keeps redirecting and receiving e-mail
aliases indefinitely). (6) Human verification on the new domain: sign-up confirmation AND
password reset end to end — the auth-link round trip is the class of defect no suite
reaches. Zero-downtime alternative if ever needed again: Resend Pro for one month
(US$ 20) verifies both domains in parallel.

*What step (1b) costs when it is missed — measured, 12/08/2026.* Step (6) failed on the
first try: the password reset came back with the app's generic "Não foi possível enviar o
e-mail de recuperação", and the function log said
`Resend rejected the message (400): "The associated domain with your API key is not
verified. Please, create a new API key with full access or with a verified domain."` The
domain was verified — the KEY (`guardacompartilhada-prod`, issued in June against the old
domain) was the thing that was not. Note the blast radius: GoTrue answered **500 on
`/auth/v1/recover`**, so it was not one e-mail missing, it was password recovery and sign-up
confirmation both down for every user until the key was replaced. Recreating the key and
saving it as `RESEND_API_KEY` fixed it with no redeploy — the function reads the secret per
invocation. **The diagnosis lives in the Edge Function logs, not in Auth**, which is where
the hook moved it (see the auth-e-mail note in `CLAUDE.md`'s gotchas).

*What the cutover left behind, and what step (2) is really protecting you from:* the three
sending functions read `RESEND_FROM_EMAIL` with a literal fallback in the code, and until
`1.8.5` that fallback was `noreply@guardacompartilhada.com` — an address on a domain that
step (1) had just DELETED. A project missing the secret would therefore send from a domain
Resend no longer knows, and the send fails with nothing on screen: the app dispatches
fire-and-forget, so the casualty is a sign-up confirmation or a password reset that simply
never arrives. The fallback is now `noreply@entrelares.app`, which makes step (2) a
configuration detail again instead of a single point of silent failure. The lesson
generalizes to any provider migration: **a literal default is only harmless while the thing
it names still exists** — flip it in the same delivery that retires what it points at.

---

## 6. Verify the deploy

**6.1 Database & cron:**
```sql
-- CLI migrations landed (this is the CLI's tracking table — the legacy
-- public.schema_migrations is frozen at the V001–V010 baseline, do NOT use it here)
select version, name from supabase_migrations.schema_migrations order by version;
-- cron's HTTP calls should be 200, not 401
select id, status_code, error_msg, created from net._http_response order by id desc limit 5;
-- job run history
select jobid, status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;
```
**Edge Functions → `auto-approve-expired` → Logs** should show a new entry each hour
(`rpc processed N …`).

**6.2 Workflow smoke test** (validates the V008 RLS + V010 + the new app build):
signed in as a normal parent, the calendar loads, a swap request can be created
(would fail against a stale app/function after V010) and approved by the other
side, and the priority tag appears on the Notifications card. The app version in
the Login footer must read the deployed version.

**6.3 F-15 sign-up smoke test** (validates V009 + step 5 end to end): open
`/register`, create a throwaway account → the "Confirme seu e-mail" screen appears
and the PT-BR confirmation e-mail arrives → click the link → sign in → the Família
page shows the new one-member family → send an invite to a second throwaway e-mail
→ the invitation e-mail (Resend) arrives with a working `/register?invite=…` link.
Clean up the test family afterwards (delete the two auth users in Authentication →
Users; their profiles/family cascade is manual — remove via SQL).

**6.4 Security advisors (S-12, periodic):** Dashboard → **Advisors → Security** —
review after any migration that touches tables, policies or functions (and at
least at every prod promotion). Expected steady state: no errors about RLS
disabled or anon-exposed tables; new warnings become backlog items. The
"anon reads nothing" invariant is also locked in CI by
`RlsHardeningTests.AnonKey_WithoutSession_ReadsNothingFromAnyTable`.

---

## 7. Prod-promotion checklist (dev → master)

Everything CI does NOT do — one pass through this list at every promotion,
besides the sections above. Consolidated July 2026 (desktop-session handoff):

1. **S-15: move `policy.enforce_from` to *promotion date + 15 days*** — a one-line
   corrective migration, PLUS the same value in `Helpers/PolicyVersions.EnforceFrom`,
   **in the same delivery**. It currently ships as a deliberately loose `2026-09-30`:
   the 15-day notice the legal review requires exists so the subject can READ the new
   text before losing access, and they can only do that once it is in PRODUCTION —
   counting from the QA merge would burn the whole window while the text is invisible
   to the people it binds. Until the promotion the gate only warns, which is correct.
   `ReconsentGateTests.EnforceFromConstant_MatchesServerSetting` turns the half-done
   version of this into a red gate instead of a live lockout, so moving only one of
   the two fails CI.
2. **Check prod's migration state** against `supabase/migrations/`, BEFORE merging to
   `master`. The drift left by the old stale-CLI-link incident was **verified gone on
   01/08/2026**: prod's applied set was an exact PREFIX of the repo's — no prod-only rows,
   no gaps — so the delta is just the unapplied tail and the CI `db push` runs clean.
   Keep checking anyway (`list_migrations` via the Supabase MCP on the PROD org, or the
   Dashboard): what makes this step cheap is that a mismatch here fails the prod `db push`
   AFTER the gate has gone green, i.e. with the deploy already in motion.
3. **Confirm prod's API keys (S-16)** — BEFORE merging to `master`. The Edge
   Functions read `SUPABASE_SECRET_KEYS`/`SUPABASE_PUBLISHABLE_KEYS` and **fail
   without them**, so the publishable/secret pair must EXIST on the prod project
   before the promotion redeploys the functions there — **section 10.1**, plus the
   matching GitHub secrets (10.2) and the cron header migration (10.3). While prod
   still holds a legacy key anywhere, also check Dashboard → **JWT Keys** that
   **HS256 is *Current*** (roll back if Supabase auto-promoted ES256 — Standby the
   ES256 key → Rotate), because ES256 is exactly what invalidates the legacy keys:
   GoTrue answers `unrecognized JWT kid <nil> for algorithm ES256` and invite
   sign-ups break first (`register-invitee`'s `admin.createUser`). Once nothing
   legacy remains, that rollback stops being needed and ES256 becomes step 10.5.
4. **Custom SMTP via Resend on the prod project** (section 5.5 — separate
   account, nothing propagates; use a separate Resend API key).
5. **Auth e-mail templates in PT-BR on prod** (sections 5.4/5.6 — the generic
   link-only defaults score badly with spam filters). **And then the Send Email
   Hook (section 5.7)**, which is what makes those e-mails follow the reader's
   language; it is per-project and its secret does not propagate, so prod needs
   its own. Do the templates anyway: they are the back-out path if the hook has
   to be switched off.
6. **Verify "Secure email change" is ON** (double confirmation on the old AND
   new address) — the S-10 design leans on it for the e-mail change path.
   Check the auth rate limits while there (section 5.5).
7. **Crons on prod** (section 4): `auto-approve-expired-hourly` and
   `purge-deleted-daily` are per-project — create them on prod with the prod
   ref URL (pg_cron + pg_net + Vault secret first, sections 4.1–4.3).
8. **Backup (T-19) goes live only on `master`**: create the private R2 bucket
   `guarda-backups` + a bucket-scoped token, add the 4 secrets
   (`BACKUP_PASSPHRASE` — keep an offline copy, it is the GPG decryption
   key —, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`), then
   smoke-test via Actions → "Weekly encrypted backup" → Run workflow and
   confirm the object lands in R2. Scheduled workflows only fire from the
   default branch.
9. Standard runbook pass: sections 0–6 (CI covers 1–3; Dashboard steps are
   manual) + human verification (section 6).
10. **Update the documented production version — in the same pass.** Nothing
    derives it automatically, so it drifts silently: `CLAUDE.md` (the Overview
    line **and** the prod-project line under *Environments*), the
    `backlog/README.md` roadmap paragraph, and any README statement about what
    is live. It already bit us — the 30/07 promotion took prod to `1.6.33` while
    every one of those still said `1.6.23`, which made the backlog claim billing
    was awaiting promotion when it had in fact shipped. Also re-read what the
    stale number implied elsewhere, not just the number itself.
11. **Tag and PUBLISH THE RELEASE — the promotion is not done without it**
    (owner, Aug 2026). Annotated tag `vX.Y.Z` on the promoted `master` commit,
    then a published GitHub release on that tag. **This is the only artefact a
    USER can read to learn what changed in the version they just received** —
    the README changelog is developer documentation and the in-app number says
    nothing by itself. Title `vX.Y.Z — <what it delivers>`, body in PT-BR:
    one-paragraph summary, `### Destaques` written for whoever uses the app
    (backlog IDs in parentheses, never as the explanation), `### Banco de dados`
    when migrations shipped, and the `compare/<previous>...<this>` link. Draft
    it from the README changelog rows this promotion carries.
    **How — the full convention (format, wording, publishing, current state) is
    [`docs/releases/README.md`](../docs/releases/README.md); read that one, not
    this paragraph, when actually writing a release.** In short: the notes live
    at **`docs/releases/<tag>.md`** (first line = the release title, rest = the
    body), written in the same PR as the promotion; then run **Actions →
    `Publicar release no GitHub` → Run workflow**, filling `tag` with `vX.Y.Z`
    and leaving `target` empty when the tag already exists (or `master` to have
    the workflow create the tag on the current `master` head). Success looks
    like the version showing up at
    `https://github.com/irineus/entrelares-app/releases` as *Latest*.
    **State (05/08/2026): `v1.7.15` was published WITH that promotion** — the
    first release through the workflow, which the same promotion carried to
    `master` (so "Run workflow" exists from now on). No pre-written file is
    pending; the first delivery after the promotion creates
    `docs/releases/v1.7.16.md` and the rename-per-delivery cadence restarts (the
    workflow fails with "notas não encontradas" when the name does not match the
    tag — on purpose).
    **The "Run workflow" button only appears once `publish-release.yml` is on
    `master`** — `workflow_dispatch` is registered from the DEFAULT branch only
    (same restriction as `schedule`; from `dev` the API answers a bare 404).
    Until then — and as a fallback any time — publish by hand at
    `https://github.com/irineus/entrelares-app/releases/new?tag=vX.Y.Z`:
    *Choose a tag* resolves to the existing tag, the **Release title** is the
    first line of the notes file (without the `# `) and the **body** is
    everything after it; leave *Set as a pre-release* unchecked and click
    **Publish release**.
    The workflow refuses to overwrite an existing release — correct a published
    one by hand in the UI. This indirection exists because the releases REST API
    is blocked in the browser-based Claude Code sessions (the GitHub MCP
    connector only READS releases), so without it the assistant cannot publish.
    **Patch promotions get a release too**, even a three-line one.

---

## 8. Incident response — data breach (LGPD art. 48)

Pairs with the disaster-recovery plan (T-19). A "security incident" here is any
event with possible unauthorized access to personal data: leaked key
(`service_role`, R2 token, Resend key), RLS bypass, compromised admin account,
exposed backup, or a Supabase/Cloudflare/Resend upstream breach affecting us.

**1. Contain (immediately).**
- Rotate the compromised credential first: Supabase Dashboard → Settings → API
  (service_role/anon), R2 token in Cloudflare, Resend key, GitHub secrets that
  mirror them (`deploy.yml` / `backup.yml`).
- If an account is compromised: Authentication → Users → sign-out/ban the user;
  if the app itself is the vector, pause the Cloudflare Pages deployment.
- Preserve evidence: export the relevant Dashboard logs (Auth, Edge Functions,
  Postgres) BEFORE any cleanup — they age out.

**2. Assess (same day).**
- What data, whose, how many subjects, for how long, was it a CHILD-related
  record (notes/schedule)? Custody data leaking to the wrong party is the
  worst-case scenario — treat any cross-family exposure as high risk.
- Record a timeline (detection, window of exposure, vector) in a private
  incident note; it becomes the art. 48 report's core.

**3. Notify (if risk or relevant damage to data subjects).**
- **ANPD**: within the regulated deadline (Resolução CD/ANPD nº 15/2024 —
  **3 business days** from awareness) via the ANPD's incident form; include
  nature of data, subjects affected, technical measures, risks, mitigation.
- **Affected users**: plain-PT-BR e-mail from the privacy address
  (privacidade@entrelares.app) — what leaked, when, what we did,
  what THEY should do (e.g. change password), contact for questions.
- Under-notification is the fined behavior; when in doubt at the risk
  threshold, notify.

**4. Recover & post-mortem.**
- Restore integrity if data was altered (T-19 backups; document any restore).
- Post-mortem within a week: root cause, what detection lacked, corrective
  backlog items (S- prefix), and whether policies/runbook need updating.

---

## 9. Billing go-live (T-39) — activating real charges in production

> **DONE — production has been charging since 29/07/2026.** The product owner
> ran this checklist and flipped `billing.enabled=true` in prod `app_settings`
> that day; prod carries real subscriptions and webhook events since. This
> section is kept as (a) the RECORD of what was configured and (b) the
> procedure for any future environment. **Do not re-run the flag step as if it
> were pending** — and treat the billing path as production-critical from here
> on: a change to `billing-checkout`/`billing-webhook`, `set_family_plan` or the
> grace cron can now cost a real family money or access.
>
> *(Discovered 03/08/2026 while verifying the 1.7.0 promotion against the
> database: the docs had claimed "dormant behind `billing.enabled=false`" for
> five days after the flip. Same lesson as S-15 — check the claim against the
> system, not against our own notes.)*

The billing code has been live in production since `1.6.33`: functions,
tables, RPCs and the grace cron are all deployed by CI. **Go-live was pure
configuration — no deploy, no promotion.** It is the product owner's explicit
decision; the steps below are in the order they must happen (webhook
authentication BEFORE the flag flip, so no payment can ever arrive
unprocessed). Everything was validated end-to-end in the sandbox on
28/07 (checkout → Pix → webhook → premium; refund → free; cancel honors the
paid period; re-subscribe adds time).

**9.1 Real Asaas account** — at https://www.asaas.com (NOT `sandbox.asaas.com`).
Complete the commercial registration (CPF or CNPJ) and wait for the account
approval; register the receiving bank account (*Configurações → Conta
bancária*) and check the current per-transaction fees (*Configurações →
Taxas*). Two prerequisites discovered in the sandbox run: register the site
**the app host** (callback-domain validation; `app.guardacompartilhada.com` at the time —
since F-54 the host is **`web.entrelares.app`**, which must be ADDED there at the
promotion-A cutover or the hosted checkout refuses the new callback URLs) and create a
**Pix key** — without one the hosted checkout silently doesn't offer Pix.

**9.2 Production API key** — Asaas dashboard → avatar menu → *Integrações →
Chave de API*. Shown **once** (`$aact_prod_…`); copy it straight into the
password manager. It must exist nowhere in the repo — only as the function
secret below.

**9.3 Prod function secrets** — Dashboard of the **prod** project
(`jptqbwfziyzlhlmoekzu`) → Edge Functions → Secrets (the section 2.1 table):
- `ASAAS_API_KEY` — the key from 9.2.
- `ASAAS_API_URL` = `https://api.asaas.com/v3` — **mandatory**: the sandbox is
  the code default precisely so a misconfigured environment can never charge
  real money by accident, which means prod must opt in explicitly.
- `ASAAS_WEBHOOK_TOKEN` — a fresh random value (e.g. `openssl rand -hex 32`),
  never the sandbox one. Keep a copy: the same value is typed again in 9.4.
- `APP_URL` — should already be `https://web.entrelares.app` (F-54); confirm.

Secret changes need **no redeploy** — they apply to subsequent invocations.

**9.4 Register the webhook in the Asaas dashboard** (*Integrações → Webhooks* →
new webhook):
- **URL**: `https://jptqbwfziyzlhlmoekzu.supabase.co/functions/v1/billing-webhook`
- **Auth token**: the exact `ASAAS_WEBHOOK_TOKEN` value — Asaas sends it in the
  `asaas-access-token` header, the only authentication the function accepts.
- API version **v3**, sequential queue, alert e-mail = the owner's (Asaas
  e-mails when the queue pauses).
- **Events**: payments `PAYMENT_CONFIRMED`, `PAYMENT_RECEIVED`,
  `PAYMENT_OVERDUE`, `PAYMENT_REFUNDED` + subscriptions
  `SUBSCRIPTION_DELETED`, `SUBSCRIPTION_INACTIVATED`. Selecting "all" is safe —
  unknown events are ledgered and acked with 200.
- Queue semantics: repeated non-2xx responses make Asaas **pause the whole
  queue** (silencing every family's events) — that is why the function returns
  200 even for events it ignores. If the queue ever pauses, fix the cause and
  re-enable it on this same screen.

**9.5 Auth smoke test** (30 seconds, before the flip):
```bash
# no token → must print 401
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  https://jptqbwfziyzlhlmoekzu.supabase.co/functions/v1/billing-webhook \
  -H "Content-Type: application/json" -d '{}'

# with the token → {"error":"Malformed event."}
# (400 = authenticated and parsed, rejected as empty — both sides of the token match)
curl -s -X POST \
  https://jptqbwfziyzlhlmoekzu.supabase.co/functions/v1/billing-webhook \
  -H "Content-Type: application/json" \
  -H "asaas-access-token: <the token>" -d '{}'
```

**9.6 Flip the switch.** This is per-environment runtime configuration, not
schema — a direct UPDATE in the prod SQL Editor is the correct mechanism (a
migration would wrongly drag dev/QA to the same value):
```sql
-- review the prices first if needed: billing.price_monthly_cents,
-- billing.price_annual_cents, billing.grace_days, billing.grace_warning_days
UPDATE public.app_settings SET value = 'true' WHERE key = 'billing.enabled';
```
The moment it commits, the Família page swaps the F-32 waitlist for the real
offer and `billing-checkout` starts creating payment links. The grace/dunning
cron is already scheduled by migration (pg_cron, hourly at :23) — nothing to arm.

**9.7 End-to-end verification with a real payment** — use the owner's own
family in prod: monthly checkout (R$ 5,49, the cheapest — promotional launch price, F-48) → Asaas hosted page →
pay via Pix → redirected back to `/premium/retorno` → verify
`subscriptions.status = 'active'` with `current_period_end` ≈ +1 month, the
`PAYMENT_RECEIVED` row in `billing_events`, `families.plan = 'premium'` and the
premium features unlocked in the app. Optionally close the loop: **refund** the
payment in the Asaas dashboard — `PAYMENT_REFUNDED` must drop the subscription
to `canceled` and the plan to `free` (and the Pix comes back). Troubleshooting
lives in **Edge Functions → `billing-checkout` / `billing-webhook` → Logs** and
in the ledger (`billing_events` rows with `event_type = 'CHECKOUT_ERROR'`
record the gateway's exact refusal).

---
## 9-bis. Store billing go-live (T-48) — the Google Play rail

> **DONE — the store rail is LIVE in production since 23/08/2026.** The code
> shipped with T-53 lote 5 (20/08/2026), reached the prod project with the
> `v1.8.13` promotion (22/08), and `billing.store_enabled` was flipped to `true`
> on 23/08 after the whole console side below was executed and verified on a
> real device.
>
> **What a real purchase proved, end to end** (23/08/2026, licensed tester,
> internal-test track):
>
> | Time (UTC) | Event | Effect |
> |---|---|---|
> | 01:43:40 | `PLAY_RTDN_4` (PURCHASED), via Pub/Sub push | recorded; `subscription_id`/`family_id` NULL — nothing to attach to yet |
> | 01:44:17 | `PLAY_PURCHASE_VERIFIED`, the app calling `billing-store-verify` | subscription row created, plan → `premium` |
> | 01:45:48 | `PLAY_RTDN_3` (CANCELED), via Pub/Sub push | found the row, status → `canceled` |
>
> **The RTDN for the purchase arrived 37 seconds BEFORE the client could
> verify.** That race is real and the design absorbs it: the webhook cannot
> attach a purchase token that no family owns yet, so it records and no-ops, and
> the client's verification is what creates the row. Do not "fix" this by making
> the webhook create subscriptions — it would be granting Premium from a message
> body, which is exactly what the design refuses.
>
> Final state after cancelling: `status = canceled`, `current_period_end` intact
> a month out, `families.plan` still `premium`. The paid period survived, and
> the grace cron owns the eventual downgrade — same shape as an Asaas
> cancellation.
>
> **Rolling back** is still one statement (9-bis.5). Purchases already made keep
> applying, because the RTDN webhook is not gated by the flag.

Why this rail exists at all: a native app may NOT sell a digital subscription
through an external checkout. The Asaas rail (recurring + Pix avulso) keeps
serving the WEB channel; Play Billing serves the store one. Both converge in
the database — same `set_family_plan`, same `billing_events` ledger, same
grace window, same additive renewal.

**9-bis.0 Upload a build that declares BILLING — this comes FIRST.** Play only
unlocks the Subscriptions page once an uploaded build declares
`com.android.vending.BILLING`; until then the page says *"Your app doesn't have
any subscriptions yet"* and offers only *"Upload a new APK"*. The bundle sitting
in the account today is the **TWA**, which carries no billing permission (the
original T-48 was the Digital Goods API and never shipped), so 9-bis.1 below is
unreachable until this step is done — found the hard way on 22/08/2026.

The Flutter build carries the permission with no manifest edit of ours:
`in_app_purchase` pulls `com.android.billingclient:billing`, whose AAR manifest
declares it, and the merge does the rest.

```
cd apps/entrelares_app && fvm flutter build appbundle --flavor prod --release
```

Upload it to the **internal-test** track (see the warning under 9-bis.6 — never
the closed one), with a tester list holding the owner's account only, and add
that same account under *Setup → License testing* so the test purchase does not
charge.

> There is **nothing to declare** about in-app purchases. Checked on the real
> console (22/08/2026): *Policy → App content* holds ten declarations — health
> apps, advertising ID, financial features, government apps, data safety, target
> audience, content ratings, ads, sign-in details, privacy policy — and none of
> them is about IAP. Play derives "contains in-app purchases" from the products
> that exist. Do not confuse it with **Financial features**, which is about
> financial SERVICES (lending, crypto) and is correctly answered "no". The
> uploaded build is the only gate.

**9-bis.1 Create the two subscription products** in Play Console → *Monetize →
Subscriptions*. The product ids are pinned in the client
(`packages/entrelares_core/lib/src/store_billing_rules.dart`, with a test that
fails if they drift) and in `billing-store-verify`:

| Product id | Base plan | Notes |
|---|---|---|
| `premium_monthly` | monthly, auto-renewing | |
| `premium_annual` | annual, auto-renewing | |

Set the prices HERE, per country — the app displays whatever Play answers and
never a number from `app_settings` (which rules the web rail only). Google's
fee (~15% in the subscriptions tier) is yours to absorb or price in; the R$ 5,00
Asaas floor does not apply to Play.

**9-bis.1-bis The Google Cloud project — there was none.** Both 9-bis.2 and
9-bis.3 assume a Cloud project exists; on 22/08/2026 the account had none, and
neither this section nor anything else said to create one.

> **Do NOT look for "API access" in the Play Console.** That page is gone from
> this account (checked 22/08/2026: not under Settings, not under Developer
> account, and `/developers/<id>/api-access` redirects to the app list). It used
> to create and link the Cloud project — and enable the Play API — in one click.
> Without it, both are manual, and **enabling the Play API is no longer
> optional**: skip it and verification answers 403 with the purchase already
> made.

Create everything in Google Cloud, then grant access from the Play Console:

1. Project — <https://console.cloud.google.com/projectcreate>
2. Enable **Google Play Android Developer API** —
   <https://console.cloud.google.com/apis/library/androidpublisher.googleapis.com>
3. Enable **Cloud Pub/Sub API** (for 9-bis.3) —
   <https://console.cloud.google.com/apis/library/pubsub.googleapis.com>

Check that 2 and 3 landed inside the project from 1: each API screen carries
`?project=…` in its URL, and that is where it is verified. Enabling an API on
the wrong project is silent.

Done on 22/08/2026: project `entrelares-506400`, both APIs enabled, service
account `entrelares@entrelares-506400.iam.gserviceaccount.com` with no IAM role
(correct — the Play Console is what authorizes it).

> Pub/Sub usually wants an active **billing account** on the project even when
> usage sits entirely inside the free tier — and RTDN volume for one app is far
> from that limit. Expect near-zero cost, but the decision to attach a card is
> the owner's: it touches the group-8 rule that new platform spend waits for
> revenue (T-36).

**9-bis.2 Service account for the Play Developer API.** In Google Cloud, create
a service account and a JSON key; in Play Console → *Users and permissions*,
invite that account and grant **View financial data** + **Manage orders and
subscriptions** for this app. Paste the whole JSON as the function secret
`PLAY_SERVICE_ACCOUNT`. Without it, `billing-store-verify` fails loudly (by
design — a silent fallback would grant Premium on the client's word).

**9-bis.3 Real-Time Developer Notifications.** Create a Pub/Sub topic, allow
`google-play-developer-notifications@system.gserviceaccount.com` to publish to
it, and point Play Console → *Monetize → Monetization setup → RTDN* at it. Then
create a **push subscription** whose endpoint is:

```
https://<PROJECT_REF>.supabase.co/functions/v1/billing-store-webhook?token=<PLAY_RTDN_TOKEN>
```

Pub/Sub allows no custom headers, so the shared token travels on the query
string — set the same value as the function secret `PLAY_RTDN_TOKEN` (long and
random; it is the ONLY authentication that endpoint has). Set the SECRET FIRST:
until it exists the endpoint answers 401 to everything, including a perfect
configuration. Also leave the subscription's **payload unwrapping OFF** — the
function reads `push.message.data` and `push.message.messageId`, and an
unwrapped delivery would be silently ignored with a 200, which is the worst
kind of failure. Set **Expiration period = never**: the default is 31 days of
inactivity, and a rail with no subscribers yet produces exactly that. Use Play
Console's "Send test notification" button and check the function logs: a test
notification is acknowledged and applies nothing.

> **Known limitation — the token is in the request logs.** The platform logs the
> full URL, so `?token=…` sits in plaintext in the Edge Function logs (seen
> 23/08/2026). That is inherent to the design: Pub/Sub sends no custom headers,
> so the secret must travel in the URL.
>
> The blast radius is small on purpose — the webhook **never trusts the message
> body** for entitlement. It takes the purchase token to the Play Developer API
> and applies what Google says, so a forged message with an invented token is a
> no-op. Damage would require an already-real purchase.
>
> **Rotating it** has no zero-downtime path (the function compares against one
> value), but nothing is lost: a mismatch answers 401, Pub/Sub retries, and the
> retry lands once both sides agree. Order: change the function secret, then the
> push subscription's endpoint URL.

**9-bis.4 Package name.** Set `PLAY_PACKAGE_NAME` to the flavor's
`applicationId` — `com.entrelares.app` in production. The default matches, so
this is only needed if it ever changes.

**9-bis.5 Flip the switch — BEFORE the test purchase, not after.**

```sql
UPDATE public.app_settings SET value = 'true' WHERE key = 'billing.store_enabled';
```

> **This step used to be numbered LAST, and in that order it is impossible**
> (found 22/08/2026, preparing the go-live). While the flag is `false` the
> client returns `StoreOffer.neutralNote` before anything else
> (`store_billing_rules.dart`) and never offers a purchase, and
> `billing-store-verify` refuses with 409. There is no button to press: you
> cannot buy your way to the state the old 9-bis.6 waited for.
>
> Turning it on first is safe **while the store build reaches nobody but the
> tester**. The store rail exists only in the Flutter ANDROID build
> (`isStoreChannel = !kIsWeb`), so with the app on the internal-test track and
> the licensed tester list holding one account, the flag reaches exactly that
> device. The TWA in production and the Flutter web target stay on the Asaas
> rail, untouched. Re-check that assumption before flipping it in any other
> situation: once the stage-4 cutover puts the Flutter build in front of real
> users, this flag is a PRODUCT decision, not a test setup.

The client reads it on the next load; no deploy needed. To roll back, set it to
`false` — the store build returns to the neutral note, and purchases already
made keep working (the RTDN webhook is not gated by the flag: money that Google
already took must keep applying). That rollback is the safety net for
everything below.

**9-bis.6 A real purchase, on a real device.** Add a licensed tester account in
Play Console, install a build from the **internal-test** track, and buy. What
to check: the Premium section flips to active, `subscriptions` holds a row with
`gateway='play'` and the purchase token, and cancelling on Play arrives as an
RTDN that leaves the paid period intact. **An emulator cannot do this** — Play
Billing needs the store, and the test purchase needs the licensed account.

The ledger keys, which this section used to state wrongly as
`play:<token>:<expiry>` (it cost a wrong `LIKE` filter while verifying the real
purchase on 23/08/2026):

| Written by | `event_id` | `event_type` |
|---|---|---|
| `billing-store-verify` | `play:<purchaseToken>` | `PLAY_PURCHASE_VERIFIED` |
| `billing-store-webhook` | `play-rtdn:<messageId>` | `PLAY_RTDN_<type>` |

So `event_id LIKE 'play%'` catches both; `'play:%'` catches only the direct
verification.

> **Internal test, NOT closed alpha** (owner, 22/08/2026). `com.entrelares.app`
> is the same package the current TWA ships under, so a build on the closed
> track would hand the Flutter app to the alpha testers before the stage-4
> cutover — a different app, with no notice. The internal track with a
> single-account tester list is what keeps this a test.


## 9-ter. Google login go-live (F-57) — enabling the provider, per project

> **DONE — Google login is LIVE on BOTH projects since 27/08/2026.** The code merged the same
> day (PRs #92/#93, `2.1.0+55`), the owner executed this whole section, and both projects now
> answer `external.google: true`. **Verify it in one command, and prefer this over reading the
> console** — it is the exact question the app asks, so it can never disagree with what the
> user sees:
>
> ```
> curl -s -H "apikey: <publishable key>" https://<ref>.supabase.co/auth/v1/settings
> ```
>
> **What is live where, because the two channels are NOT in the same state:**
>
> | Channel | State |
> |---|---|
> | Web (`web.entrelares.app`) | Button live from the merge — the web build follows `main` |
> | Android | **No button until a Play promotion of a bundle ≥ `2.1.2+57`.** What is on the store predates F-57 and has no such code — this is not a config problem and no console change fixes it |
>
> **Enabling prod before T-61 was deliberate, not an oversight.** T-61 (the consent screen and
> Google's summary e-mail both naming `<ref>.supabase.co` instead of Entrelares) is a blocker
> for the PUBLIC rollout (T-59), and the product is still in closed alpha — so this puts the
> flow in front of exactly the testers whose feedback created F-57, while the branding fix
> lands before it reaches strangers. When T-61 is done, the auth host changes and the redirect
> URI moves with it: existing identities are untouched (they live in `auth.identities`), but
> sign-ins IN FLIGHT during the switch will fail, so do it in a quiet window.

The code shipped dormant on purpose: **the switch IS the provider config.**
The app asks GoTrue's public settings endpoint (`/auth/v1/settings`) whether
`google` is enabled and only then renders the button — so there is no
`app_settings` flag to flip, nothing that can disagree with the real config,
and each project (dev / prod) arms itself independently. Until you finish this
section on a project, that project's builds simply have no Google button.

**9-ter.0 GCP — one OAuth client, once.** In a Google Cloud project owned by
the product account (ours is `entrelares-506400`). Google reorganised this
console in 2026: what used to be *APIs & Services → OAuth consent screen* is
now its own product, **Google Auth Platform** (`console.cloud.google.com/auth`),
split into Branding / Audience / Clients / Data Access. The old
*APIs & Services → Credentials* page still exists and still LISTS the client
afterwards — it just no longer creates it.

1. *Google Auth Platform → **Branding***: app name **Entrelares**, support
   e-mail, the `entrelares.app` authorized domain.
2. *Google Auth Platform → **Audience***: **External**, and **publish it** —
   the "Testing" state caps sign-ins to a listed set of accounts and expires
   refresh tokens after 7 days. Left in Testing, this surfaces as users being
   silently signed out a week later, which reads like an app bug and is not.
3. *Google Auth Platform → **Clients** → Create OAuth client → Application
   type: **Web application*** (WEB, even for Android: the device never talks to
   Google directly — GoTrue does the code exchange server-side). Name it for
   the console's own benefit (`Entrelares — Supabase GoTrue`). Leave
   *Authorized JavaScript origins* EMPTY — this is a redirect flow, not a
   browser-implicit one. Under **Authorized redirect URIs**, BOTH projects'
   GoTrue callbacks:
   - `https://buroanotfjcgvbfmacuh.supabase.co/auth/v1/callback` (dev)
   - `https://jptqbwfziyzlhlmoekzu.supabase.co/auth/v1/callback` (prod)

   The create screen warns that settings take **5 minutes to a few hours** to
   take effect. Believe it: a `redirect_uri_mismatch` in the first minutes
   after saving is propagation, not a typo — re-check the URI once, then wait
   rather than "fixing" a correct value.
4. Keep the **Client ID** and **Client secret** — the next step wants them.
   One client for both projects is fine; the secret lives only in the Supabase
   consoles (never in this repo — Rule 1).

**9-ter.1 Supabase — per project, DEV first.** *Authentication → **Sign In /
Providers*** (the entry called plain "Providers" until 2026) → **Google**:
enable, paste Client ID + secret, save.

> Do NOT confuse it with its two neighbours, which read like the right thing
> and are its mirror image: **OAuth Apps** (under MANAGE) and **OAuth Server
> (BETA)** are Supabase acting AS an OAuth provider for third parties. What
> this section configures is Supabase CONSUMING Google.

Then *Authentication → URL Configuration → Redirect URLs*, add the app's
return addresses:

| Project | Add to Redirect URLs |
|---|---|
| dev | `com.entrelares.flutter://login-callback` (Android dev flavor) — plus `http://localhost:*` patterns if web QA runs locally |
| prod | `com.entrelares.app://login-callback` (Android prod) and `https://web.entrelares.app` (web channel return) |

The custom schemes match the manifest's `${applicationId}` intent filter and
`DeepLinkUrls.oauthCallback` — per flavor so a device carrying both apps never
opens a chooser. Nothing here requires a redeploy: the S-16 ordering trap does
not apply because no Edge Function reads this config.

> **Do NOT test the invitation half from the e-mail on dev — it cannot work,
> and the way it fails is a trap.** `send-swap-email` builds the invite link
> from the `APP_URL` secret, and **dev has had no web target since T-56**: the
> Blazor QA deployment died with the cutover. The secret still said
> `qa.entrelares.app`, a host that did not stop resolving — it became a GHOST,
> answering with a stale build, so the link opened a real-looking page with no
> Google button and nothing about it said "wrong app" (measured 27/08/2026).
> **Already fixed the same day:** dev's `APP_URL` now carries
> `https://web.entrelares.app`, the same value prod does — the ghost is strictly
> worse than pointing at a live host, because a stale build that answers is the
> failure mode that lies quietly.
>
> Know what that costs, though: a DEV invite e-mail then points at the
> PRODUCTION web app, whose database has no such token, so it answers
> "convite inválido". That is honest and harmless — a dev token can do nothing
> in prod — but it means **dev invite testing happens inside the app**, never
> from the inbox: use "Copiar link" on the Família screen, or push the link
> straight in with
> `adb shell am start -a android.intent.action.VIEW -d "https://web.entrelares.app/register?invite=<token>" com.entrelares.flutter`.
> A debug build never verifies App Links (per-machine certificate), so the
> e-mail link would land in the browser regardless of the secret's value.
> Giving dev a web deployment again is the only real fix, and it is its own
> scope.

**9-ter.2 Verify on DEV before touching prod.** A dev-flavor build
(`workflow_dispatch → build-apk`) on a real device: the button appears on
`/login` (it was absent before — that is the fail-closed switch working), a
NEW Google account lands on `/onboarding`, completes the form and reaches the
calendar; an invited e-mail tapping "continuar com Google" from the register
screen lands on the claim variant. On the dev project, confirm the profile
row carries `consent_policy_version` = current and `joined_via_invite`
matching the path taken.

**9-ter.3 Prod.** Repeat 9-ter.1 on the prod project. The button reaches real
users on the WEB immediately; on Android it waits for the next Play promotion
(the manifest's scheme filter ships with `2.1.0+55`+).

> **Correction (27/08/2026, during the go-live).** This step used to warn that
> enabling prod before the store carried the F-57 build would strand an
> Android user in the browser. Checked against the code, that scenario cannot
> happen: the build currently on Play predates F-57 and has no button to tap,
> and an Android user browsing `web.entrelares.app` returns through the web
> origin (`Uri.base.origin`), never the scheme. The real constraint is the
> other one, and 9-ter.1 already satisfies it: **prod's Redirect URLs must
> already list `com.entrelares.app://login-callback` when a build ≥`2.1.0+55`
> reaches the store** — provider and redirect URL are configured together, so
> they cannot drift apart. Enabling prod is therefore safe for the web channel
> at any time; what gates it is 9-ter.2, not the store.

**Do not skip 9-ter.2 to get here faster.** Every automated layer (237 gate
tests, the widget suites, `web-e2e`) exercises the RULES; none of them
executes an actual OAuth round trip, because there is no Google to redirect to
in CI. Until the dev APK run happens, the redirect, the scheme return and a
profile created from a real Google identity have never run once — and dev has
no web deployment (T-56), so that APK is the only place they can run before
real users meet them.

**Account linking posture (decided 27/08/2026):** GoTrue's automatic linking
stays ON — Google e-mails arrive verified, so a Google sign-in with an
existing password account's e-mail lands on the SAME user (one profile, one
family). The gate pins the consequences: `oauth_onboarding` /
`claim_invitation` suites.

**Rolling back:** disable the provider on the project — the button vanishes on
the next app boot, password sign-in never depended on any of this. Sessions
already created by Google keep working (they are ordinary GoTrue sessions);
disabling only closes the door for NEW sign-ins.


## 10. S-16 — migração das chaves de API e da assinatura JWT

Duas migrações **independentes**, nesta ordem: primeiro as chaves de API
(`anon`/`service_role` → `sb_publishable_…`/`sb_secret_…`), depois a assinatura
JWT (HS256 → ES256). A segunda é o que quebrou o cadastro por convite em julho;
ela só é segura **depois** que nada mais depende de chave legada, porque as
legadas são JWTs assinados com o *JWT secret* do projeto — as novas não são.

Links diretos por projeto (o Dashboard usa o *ref*, não o nome):

| | DEV (`Entrelares-Dev`) | PROD |
|---|---|---|
| API Keys | [`/project/buroanotfjcgvbfmacuh/settings/api-keys`](https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/settings/api-keys) | [`/project/jptqbwfziyzlhlmoekzu/settings/api-keys`](https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/settings/api-keys) |
| Segredos das Functions | [`/functions/secrets`](https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/functions/secrets) | [`/functions/secrets`](https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/functions/secrets) |
| JWT Keys | [`/settings/jwt`](https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/settings/jwt) | [`/settings/jwt`](https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/settings/jwt) |
| Cron | [`/integrations/cron/jobs`](https://supabase.com/dashboard/project/buroanotfjcgvbfmacuh/integrations/cron/jobs) | [`/integrations/cron/jobs`](https://supabase.com/dashboard/project/jptqbwfziyzlhlmoekzu/integrations/cron/jobs) |

> **Ordem obrigatória.** As Edge Functions leem `SUPABASE_SECRET_KEYS`/
> `SUPABASE_PUBLISHABLE_KEYS` e **falham sem elas**. O CI redeploya as 8 funções
> a cada push em `dev` e a cada promoção em `master`, então **10.1 tem de estar
> feito no projeto ANTES do deploy chegar nele** — em DEV antes do merge, em PROD
> antes da promoção.

### 10.1 Criar as chaves novas (uma vez por projeto)

1. Abra a página **API Keys** do projeto (links acima). O menu é
   **Project Settings → API Keys** (ícone de engrenagem na barra lateral).
2. Selecione a aba **"Publishable and secret API keys"** (a outra aba,
   *"Legacy API keys"*, é onde vivem `anon` e `service_role` — não mexa nela agora).
3. Se aparecer o botão **"Create new API keys"**, clique. Ele cria **duas** chaves
   de uma vez, ambas com o nome **`default`**:
   - **`sb_publishable_…`** — substitui a `anon` (pública, vai no app).
   - **`sb_secret_…`** — substitui a `service_role` (bypassa RLS; **nunca** no cliente).
4. **Nomes importam.** O helper `_shared/keys.ts` procura a chave chamada
   `default`; se não houver `default`, aceita quando existe **uma só**; e **recusa
   escolher** se houver várias sem `default`. O DEV já tem uma publishable chamada
   **`github_key`** (criada em julho) — deixe-a lá: com a `default` nova convivendo,
   o helper usa a `default`. Não renomeie nada.
5. Copie os dois valores agora (a secret só é exibida por inteiro na criação;
   depois fica mascarada). Guarde-os fora do repositório.

**Verificação (obrigatória antes de seguir):** abra a página **Edge Functions →
Secrets** (link acima) e confirme que a lista mostra `SUPABASE_PUBLISHABLE_KEYS`
e `SUPABASE_SECRET_KEYS`. São injetadas pela plataforma — você **não** as cria à
mão. Se não aparecerem, o passo 3 não completou; sem elas todas as funções
respondem 500 no primeiro deploy.

### 10.2 Provar, antes de rotacionar nada, que a chave nova funciona

O gateway do Supabase resolve o papel a partir do header **`apikey`** e recusa a
chave nova em `Authorization` (ela não é JWT). Dois comandos no **PowerShell**
respondem se a nossa suíte sobrevive à troca — rode-os **antes** de tocar nos
secrets do GitHub. Substitua o valor entre aspas pela secret key do DEV.

```powershell
$key = "sb_secret_COLE_AQUI"
$url = "https://buroanotfjcgvbfmacuh.supabase.co/rest/v1/roles?select=id&limit=1"
$ua  = "guarda-compartilhada-probe/1.0"
```

> **⚠️ O `-UserAgent` não é enfeite (custou uma rodada, ago/2026).** A secret key
> tem uma proteção a mais que a `service_role` legada nunca teve: o gateway
> **recusa** a chave quando o `User-Agent` parece navegador — *"Forbidden use of
> secret API key in browser"*. O `Invoke-RestMethod` do PowerShell 5.1 manda
> `Mozilla/5.0 (Windows NT…) WindowsPowerShell/5.1`, que casa com a regra, então
> a sonda falha mesmo com a chave correta. Ironicamente a mensagem **prova** que a
> chave é válida (o gateway a reconheceu para poder recusá-la). Nenhum chamador
> real nosso cai nisso — `HttpClient` do .NET não manda UA, o `curl` do keepalive
> manda `curl/8.x`, o `pg_net` e o Deno das functions mandam o próprio —, é uma
> armadilha exclusiva de quem testa à mão.

**Teste A — só `apikey` (é assim que os crons e as chamadas função→função ficam):**
```powershell
Invoke-RestMethod -Uri $url -Headers @{ apikey = $key } -UserAgent $ua
```
Esperado: **uma linha de `roles`**. Se vier 401, confira se copiou a *secret* (não
a publishable); se vier a mensagem de *browser*, faltou o `-UserAgent`.

**Teste B — `apikey` + `Authorization` (é o que o SDK C# faz sozinho, e o que eu
não consegui verificar daqui):**
```powershell
Invoke-RestMethod -Uri $url -Headers @{ apikey = $key; Authorization = "Bearer $key" } -UserAgent $ua
```

O PowerShell 5.1 esconde o corpo da resposta em erro; para ver status + mensagem:
```powershell
try { Invoke-RestMethod -Uri $url -Headers @{ apikey = $key; Authorization = "Bearer $key" } -UserAgent $ua }
catch { $_.Exception.Response.StatusCode.value__; (New-Object IO.StreamReader $_.Exception.Response.GetResponseStream()).ReadToEnd() }
```
- **Se retornar a linha:** a plataforma tolera o Bearer e a rotação do secret de
  CI é segura — siga para 10.3.
- **Se retornar 401:** o fixture dos testes (`E2EFamilyFixture.Service`, que usa o
  SDK e não permite omitir o `Authorization`) vai quebrar. Nesse caso **não
  rotacione** `SUPABASE_SERVICE_ROLE_DEV`: mantenha a `service_role` legada (válida
  até o fim de 2026), pule para 10.4 e **não faça o 10.5** — o ES256 é justamente o
  que invalida chave legada.

> **Resultado no DEV (03/08/2026): A e B verdes**, ambos devolvendo a linha de
> `roles`. Ou seja, **a plataforma ACEITA a secret key no `Authorization`**, ao
> contrário do que a doc oficial afirma em *Known limitations* ("You can't send a
> publishable or secret key in the `Authorization: Bearer` header"). É o mesmo
> descompasso já observado com a publishable, que roda no DEV desde julho com a
> suíte verde. Consequência prática: o SDK C# — que monta o `Authorization`
> sozinho e não deixa omitir — continua funcionando, então a rotação do secret de
> CI está liberada. **O código continua mandando só `apikey` onde controlamos o
> header**: seguir o contrato documentado é o que nos protege se a plataforma um
> dia passar a aplicar o que ela própria documenta.

**Teste C — a Admin API do GoTrue, com `apikey` sozinho.** Os testes A e B cobrem
o PostgREST; este cobre o outro caminho privilegiado que a suíte usa: o
`AdminApi` cria e apaga os usuários descartáveis da família E2E em
`/auth/v1/admin/users`, e desde o S-16 manda a chave nova **só** no `apikey`.
```powershell
Invoke-RestMethod -Uri "https://buroanotfjcgvbfmacuh.supabase.co/auth/v1/admin/users?page=1&per_page=1" -Headers @{ apikey = $key } -UserAgent $ua
```
Esperado: um objeto com a lista `users` (pode vir vazia — o que importa é **não**
ser 401). Um 401 aqui significaria que o GoTrue não aceita a chave nova sem um JWT
no `Authorization`, e aí o `AdminApi` precisaria mandá-la nos dois headers (o Teste
B já provou que a plataforma tolera) antes de rotacionar o secret.

> **Resultado no DEV (03/08/2026): C verde** — a Admin API devolveu a lista de
> usuários com a chave **só** no `apikey`. Com A, B e C verdes, os três caminhos
> privilegiados que a suíte usa estão cobertos (PostgREST nos dois formatos de
> header e a Admin API do GoTrue), e a rotação do `SUPABASE_SERVICE_ROLE_DEV`
> está liberada sem mudança de código.

### 10.3 Rotacionar os secrets do GitHub

Repositório `irineus/Entrelares` → **Settings** → **Secrets and
variables** → **Actions** → aba *Secrets* → no secret existente, botão de lápis
(*Update*) → cole o novo valor → **Update secret**. Os nomes exatos:

| Secret | Novo valor | Situação |
|---|---|---|
| `SUPABASE_ANON_KEY_DEV` | publishable do DEV | **já rotacionado** em jul/2026 |
| `SUPABASE_SERVICE_ROLE_DEV` | secret key do DEV | só se o Teste B passou |
| `SUPABASE_ANON_KEY_PROD` | publishable do PROD | fazer antes da promoção |

Não existe secret `SUPABASE_SERVICE_ROLE_PROD` — a suíte roda **sempre** contra o
DEV, inclusive em `master`, então a chave privilegiada de prod nunca entra no CI.
Em prod a secret key só é usada pelas Edge Functions (injetada pela plataforma) e
pelos crons (via Vault, passo 10.4).

No seu ambiente local, o arquivo git-ignored `e2e.local.env` na raiz do repo
recebe a **secret key do DEV** em `E2E_SUPABASE_SERVICE_ROLE_KEY` (nunca a de prod).

### 10.4 Migrar os crons para o header `apikey`

Os dois jobs criados nas seções 4.4/4.5 mandam a chave em `Authorization: Bearer`
— **chave nova é recusada ali**. Por projeto:

1. **SQL Editor** → guarde a secret key no Vault (nome exato `secret_key`):
   ```sql
   select vault.create_secret('sb_secret_COLE_AQUI', 'secret_key');
   ```
   Confirme (não imprime o valor):
   ```sql
   select name from vault.secrets where name = 'secret_key';
   ```
2. **Integrations → Cron → Jobs**: edite o job **`auto-approve-expired-hourly`** e
   depois **`purge-deleted-daily`**. Em cada um, no campo do comando SQL, troque o
   bloco `headers` por:
   ```sql
   headers := jsonb_build_object(
     'Content-Type', 'application/json',
     'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'secret_key')),
   ```
   O resto do comando (`url`, `body`, `timeout_milliseconds := 30000`) fica igual.
3. **Verificação:** espere a próxima hora cheia e abra **Edge Functions →
   `auto-approve-expired` → Logs**. Sucesso = uma execução registrada. Se o job
   ainda estiver com o header antigo, o log mostra
   `refused — caller did not present the secret key` (a função agora recusa no
   próprio código, então o erro **aparece** — antes o gate da plataforma barrava
   antes da função e não sobrava log nenhum).

### 10.5 Validar em DEV antes de tocar em prod

GitHub → aba **Actions** → workflow **"Deploy to Cloudflare Pages"** → botão
**Run workflow** → escolha a branch **`dev`** → *Run workflow*. O `workflow_dispatch`
roda o pacote E2E **completo** (o push normal em `dev` roda só o `pack=p0`), que é
onde o cadastro por convite e a `EdgeFunctionAuthTests` de fato exercitam as chaves.
Verde aqui é o pré-requisito de qualquer passo em prod.

### 10.6 Promover o ES256 (a segunda migração)

Só depois de 10.1–10.5 verdes. Página **JWT Keys** → aba **"JWT Signing Keys"**
(links no topo).

> **Os nossos projetos NÃO começam do zero aqui** (constatado no DEV, 03/08/2026).
> A doc do Supabase descreve um botão **"Migrate JWT secret"** para quem ainda está
> só no segredo legado — ele **não aparece** nos nossos, porque o incidente de julho
> já passou por essa etapa: a plataforma criou a chave **ECC (P-256)** e a promoveu
> sozinha, e o nosso rollback a rebaixou. Então a tela mostra **HS256 como
> *CURRENT KEY*** e a **ECC (P-256) em *Previously used keys*** ("last rotated"
> ≈ a data do incidente). O caminho é *reaproveitar* essa chave, não criar outra:

1. Na tabela **"Previously used keys"**, na linha da chave **ECC (P-256)**, abra o
   menu **⋮** da coluna *ACTIONS* → **"Move to standby"**. A chave sobe para o
   painel de standby. **Nada muda em runtime neste passo.**
   *Não* clique em **"Create Standby Key"** — isso geraria uma chave nova e
   desnecessária; a ECC que já está lá serve.
2. Aguarde ~5 minutos (a plataforma limita mudanças de estado) e clique em
   **"Rotate keys"**. A ECC/ES256 vira *CURRENT KEY* e a HS256 desce para
   *Previously used*. **Ninguém é deslogado**: os tokens já emitidos continuam
   aceitos até expirar.
3. Deixe a HS256 em *Previously used* — a revogação dela é o 10.7, e só depois de
   desativar as chaves de API legadas.
4. Faça no **DEV primeiro** e repita o dispatch full-pack (10.5). O ES256 antes da
   promoção é deliberado: se a contingência abaixo se confirmar, ela é uma mudança
   de CÓDIGO, e código só chega em produção pela promoção — fazendo o DEV primeiro,
   a correção pega carona na mesma; na ordem inversa, exigiria uma segunda.
5. **Contingência conhecida:** a doc do Supabase avisa que funções com *Verify JWT*
   ligado podem quebrar na rotação. Cinco das nossas já rodam sem o gate (S-16);
   sobram **`elevate`** e **`billing-checkout`**. Se elas passarem a responder 401
   depois da rotação, a correção é barata e já está meio pronta: ambas **já
   validam o JWT do usuário no próprio código** (`admin.auth.getUser(jwt)` /
   `userClient.auth.getUser()`), então basta acrescentá-las ao `config.toml` com
   `verify_jwt = false` e ao `deploy.yml` com `--no-verify-jwt`, como as outras.

> **Resultado no DEV (03/08/2026): rotação feita, full-pack VERDE** (run #261,
> 18min26s, com a ECC/ES256 como *Current*). O que ele prova, item a item:
> `register-invitee`/`admin.createUser` — **a primeira vítima de julho** — passou;
> `SudoElevationTests` e `BillingCheckoutTests` passaram, ou seja **a contingência
> acima NÃO se materializou**: o gate `verify_jwt` da plataforma valida tokens de
> usuário ES256 normalmente (o aviso da doc vale para quem verifica JWT contra o
> *segredo legado* no próprio código, que não é o nosso caso); e o `service_role`
> da CI, já no formato `sb_secret_`, operou contra um projeto em ES256. O JWKS
> passou a publicar `alg=ES256` com o `kid` da chave promovida — e lista **só** ela,
> porque a HS256 é segredo compartilhado e não tem contraparte pública (continua
> aceita na verificação até ser revogada no 10.7).
>
> **PROD seguiu no mesmo dia, logo após a promoção da `1.7.1`** e com o mesmo
> desenho de tela (HS256 *Current*, ECC `E2CB7F04…` em *Previous* há 11 dias): sonda
> das functions verde (`{processed:0, emailsFailed:0}` com a chave, **401** sem),
> crons migrados, verificação humana no app real, e então *Move to standby* +
> *Rotate keys*. O JWKS de prod passou a publicar `alg=ES256`. **Os dois ambientes
> estão migrados** — o que falta é só o 10.7, agora rastreado como **S-17**.

### 10.7 Desativar as chaves legadas — item de backlog **S-17**

> Este passo **não** é um resto de tarefa: ele espera por construção (tokens
> assinados com HS256 valem por 1 h, e a plataforma recusa revogar o segredo
> enquanto as chaves que derivam dele estiverem ativas), então virou item próprio.
> Registro e critérios de verificação em [`backlog/security.md`](../backlog/security.md).

Página **API Keys** → aba **"Legacy API keys"** → use os indicadores de *last used*
para confirmar que `anon` e `service_role` não são mais chamadas → **Disable**.
É reversível (dá para reativar se aparecer um cliente esquecido). Só depois disso
o segredo HS256 pode ser revogado na página JWT Keys — e a própria plataforma
**exige** essa ordem, porque `anon`/`service_role` são JWTs assinados por ele.
Espere ao menos **1h15** após a rotação antes de revogar (o access token dura 1h;
revogar antes desloga quem estiver com sessão ativa).
