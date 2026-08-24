// T-49 — do not spend the Resend allowance on the test suite.
//
// The E2E/integration packs drive the REAL flows against the DEV project, so
// every run makes the app call the e-mail functions for real. Their recipients
// are the fixture's throwaway addresses on Resend's own test domain
// (`delivered+e2e-<run>-<who>@resend.dev` — see `TestEnv.E2eEmailDomain`):
// nobody ever reads them, and yet each one spent a unit of the Resend
// account's 100/day allowance. Measured in Aug 2026: ~86 e-mails in one day,
// 100% of them from CI, on an account SHARED with production (one team, one
// verified domain, six API keys). A busy CI day could therefore exhaust the
// quota and leave a real invitation, a real swap notice — or a sign-up
// confirmation, since prod's GoTrue custom SMTP is the same account — silently
// undelivered.
//
// The rule is unconditional rather than an environment flag because
// `resend.dev` is Resend's own reserved test domain: no real user can hold a
// mailbox there, so there is nothing to get wrong per environment, and no
// switch anyone has to remember to set on a new project.
//
// It suppresses the OUTBOUND HTTP CALL ONLY. Recipient resolution, the
// templates, the F-38 quota accounting (`consume_email_quota`, which runs
// before the dispatch) and the function's own response all behave exactly as in
// production, so the suites keep covering everything they covered before. What
// they never covered — before or after this change — is that Resend ACCEPTS the
// message: the app dispatches e-mail fire-and-forget inside a try/catch and
// ignores the response, so a rejected send has never failed a test.
export const TEST_RECIPIENT_DOMAIN = "@resend.dev";

/**
 * True when this recipient belongs to the test suite and must never be handed
 * to Resend. Callers treat it as a successful no-op, never as a failure.
 */
export function isTestRecipient(to: string): boolean {
	return to.trim().toLowerCase().endsWith(TEST_RECIPIENT_DOMAIN);
}
