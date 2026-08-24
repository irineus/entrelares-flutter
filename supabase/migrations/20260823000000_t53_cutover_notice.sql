-- T-53 stage 4 — the dated cutover notice.
--
-- The Blazor client announces the web cutover to the people already using it.
-- The DATE is a public app_setting rather than a constant in the client for
-- one reason: it WILL move (it depends on QA and on a Cloudflare domain move),
-- and the Blazor app is frozen — re-releasing a frozen client to shift a date
-- is exactly the kind of movement the freeze exists to avoid.
--
-- It ships EMPTY on purpose: an empty (or unparseable) value shows no banner
-- at all. The announcement only exists once someone deliberately writes a date,
-- which is the same fail-closed shape `billing.store_enabled` has.
--
-- Nothing reads this but the Blazor client: the Flutter app ignores it, and no
-- server rule depends on it, so it is inert to both stacks (rollback plan,
-- item 1: no stage-3/4 change may introduce schema the other client cannot
-- tolerate).

INSERT INTO public.app_settings (key, value, value_type, category, description, is_public) VALUES
	-- 'string', not 'text': app_settings_value_type_check accepts exactly
	-- int/decimal/bool/string/json, and the row is refused otherwise.
	('cutover.web_date', '', 'string', 'cutover',
	 'T-53 stage 4: the date (yyyy-MM-dd) on which web.entrelares.app starts serving the Flutter app. Read ONLY by the legacy Blazor client, to show its dated notice. Empty = no notice.',
	 true)
ON CONFLICT (key) DO NOTHING;
