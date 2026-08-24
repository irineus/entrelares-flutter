# Backlog — Security (pending)

Active security items. Completed records live in [`archive/`](archive/). Conventions and the forward plan: [`README.md`](README.md). Live status: the [Notion board](https://app.notion.com/p/3ae2f3f4b9b28169acd9e642ad4760aa).

---

_S-11 (Phase 5 item 5.11) was completed in July 2026 (v1.5.11–v1.5.29, QA approved; shipped to production in v1.6.0) — its full decision record lives in [`archive/phase-5.md`](archive/phase-5.md). Both operations delivered: individual exit (grace, tombstone, succession, freeze, colors, cross-family migration) and whole-family deletion by consent (unanimity fast-path, undo, D-3 reminder, purge + farewell). Deferred follow-up: **F-30** (multi-family membership)._

_**S-14** (drop the legacy always-true RLS policies — the sweep found the cross-family leak on `care_schedules`, `activity_logs` and `profiles`) was completed in Phase 6 (v1.6.14) — record in [`archive/phase-6.md`](archive/phase-6.md)._

---

_**S-15** (legal review of the policies + re-consent flow on policy change) was completed in
Phase 6 (v1.6.34–v1.6.39) — full record, including the three rounds of legal opinion, the 19
findings and every design decision, in [`archive/phase-6.md`](archive/phase-6.md). All 19 are
implemented across five deliveries: the re-consent gate (B-4), the `joined_via_invite` marker,
the MATERIAL pair A-1 + A-5 with the policy bump, the eight non-material texts + C-7, and the
code half (A-4 invite purge, B-3 grace warning, C-6 opt-in log). **Open for the promotion:**
`PolicyVersions.EnforceFrom` is provisionally `2026-09-30` — a one-line corrective migration
must set `policy.enforce_from` AND the client constant to *promotion date + 15* in the same
delivery, or `ReconsentGateTests.EnforceFromConstant_MatchesServerSetting` turns red._

---

_**S-16** (coordinated migration off the legacy static keys) was completed in Phase 7 (`1.7.1`)
— full record, including why the API-key and the JWT-signing migrations are two independent
steps and why five functions had to trade `verify_jwt` for in-code authorization, in
[`archive/phase-7.md`](archive/phase-7.md). The repo side is delivered; the key rotation itself
is owner ops, sequenced in [section 10 of the deploy runbook](../supabase/README.md#10-s-16--migração-das-chaves-de-api-e-da-assinatura-jwt)._

---

### S-17 — Disable the legacy API keys and revoke the HS256 JWT secret

| Field | Value |
|---|---|
| **Status** | `pending` |
| **Priority** | `medium` |
| **Complexity** | `low` |
| **Impact** | `medium` |

**Context — what S-16 left deliberately unfinished.**
S-16 (`1.7.1`, 03/08/2026) moved everything onto the new publishable/secret keys and
promoted **ES256** on both projects: the app, the CI secrets, the Edge Functions and
the two crons no longer touch a legacy key. But the legacy `anon`/`service_role`
keys are **still enabled** on both projects, and the HS256 shared secret still sits
in *Previously used* on the JWT Keys page. Until they are turned off, a leaked
legacy key still opens the project — which is most of the security benefit of the
migration, unrealised.

**Why it is a separate item, not a loose end.**
Two reasons, both about *time* rather than effort:
1. **The platform enforces an order.** The HS256 secret cannot be revoked while the
   legacy keys are enabled — `anon`/`service_role` **are** JWTs signed by it, so
   revoking first would be an inconsistent state the Dashboard refuses.
2. **A grace window is required.** Access tokens issued before the ES256 rotation are
   signed with HS256 and stay valid until they expire (1 h). Revoking earlier
   force-signs-out whoever is active. So the revocation is a *later* action by
   construction, not something to bundle into the cutover.

**What to do** — the procedure is [section 10.7 of the runbook](../supabase/README.md#107-desativar-as-chaves-legadas),
per project (DEV first, then prod):
1. Settings → **API Keys** → tab *Legacy API keys* → read the **last used**
   indicators. They are the only evidence that nothing forgotten still calls with
   them (a mobile build, a local script, an old `e2e.local.env`).
2. **Disable** `anon` and `service_role`. Reversible — re-enable if a caller shows up.
3. Only then, JWT Keys → **revoke** the HS256 key sitting in *Previously used*.

**Verification**
- A probe with a legacy key must come back **401** after step 2 (same PowerShell
  shape as the S-16 probes, `-UserAgent` included).
- A `workflow_dispatch` full-pack on `dev` must stay green — it exercises the whole
  stack on the new keys, so a green run after disabling is the proof that nothing
  depended on the legacy pair.
- Prod: the invite sign-up flow, which is the path that broke in July.

**Risk & rollback**
Low and reversible: re-enabling a legacy key is one click, and the revocation of the
HS256 secret is the only irreversible step (do it last, and only after the two
projects have run for a while with the legacy keys disabled). **Note the standing
emergency procedure disappears with this item**: while a legacy key exists, an auth
incident can be fixed by rolling the signing key back to HS256; once revoked, that
escape hatch is gone — which is the point, but worth doing knowingly.

---

_S-12 (Phase 5 item 5.12) was completed in July 2026 (v1.5.21) — its record lives in [`archive/phase-5.md`](archive/phase-5.md). Key decision: column-level encryption **not adopted** (proportionate posture = platform AES-256 + TLS + bcrypt + RLS + zero anon access); revisit before public availability, alongside S-13._

---

_S-13 (Phase 5 item 5.13) was completed in July 2026 (v1.5.22) — its record lives in [`archive/phase-5.md`](archive/phase-5.md). Consent now recorded per profile (timestamp + policy version); retention implemented (read notifications purged after 6 months); controller + foro designated (the dedicated privacy address is **T-34**); operators/DPAs, art. 14 and the art. 48 breach runbook documented. Pending flags: legal review of the children's-data section and a re-consent flow on policy change — both before public availability._
