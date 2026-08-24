namespace Entrelares.Helpers
{
    /// <summary>Which sentence — if any — this client owes the reader about the
    /// T-53 cutover.</summary>
    public enum CutoverPhase
    {
        /// <summary>Nothing to say: no date is set and this is the live host.</summary>
        None,

        /// <summary>The swap is announced: this address will start serving the
        /// new app on a known date.</summary>
        Upcoming,

        /// <summary>The swap happened: this client is now the way BACK, served
        /// from the legacy host.</summary>
        Legacy
    }

    /// <summary>
    /// T-53 stage 4 — the dated notice the frozen Blazor client shows while the
    /// web channel changes hands. Pure and static so the whole announcement
    /// contract is unit-tested without a browser, a clock or a Supabase client,
    /// like every other rule helper here.
    /// </summary>
    /// <remarks>
    /// Two facts decide the sentence, and they are independent on purpose:
    /// <list type="bullet">
    /// <item>the HOST answers "has it already happened?" — after the cutover
    /// this app is served from <see cref="LegacyHost"/> and says so even if no
    /// date was ever written, which is the phase that must never be silent;</item>
    /// <item>the DATE answers "when will it happen?" — it comes from the public
    /// <see cref="DateSettingKey"/> setting and, when absent or malformed,
    /// produces NO announcement rather than a wrong one.</item>
    /// </list>
    /// </remarks>
    public static class CutoverNotice
    {
        /// <summary>The public app_setting carrying the cutover date
        /// (<c>yyyy-MM-dd</c>, ISO on the wire as every date in this product —
        /// display formatting is the reader's, U-24).</summary>
        public const string DateSettingKey = "cutover.web_date";

        /// <summary>Where the Flutter app answers — the address this client
        /// hands over, and the one the notice points readers to.</summary>
        public const string NewHost = "web.entrelares.app";

        /// <summary>Where THIS client moves at the cutover, and stays as the
        /// documented way back until the last user has migrated.</summary>
        public const string LegacyHost = "legado.entrelares.app";

        /// <summary>The phase for <paramref name="host"/>, given the raw
        /// value of the date setting.</summary>
        public static CutoverPhase Evaluate(string? rawDate, string? host)
        {
            // The way back announces itself regardless of any setting: whoever
            // reached this address after the swap needs to be told where the
            // app went, and that must not depend on a row being filled in.
            if (string.Equals(host, LegacyHost, StringComparison.OrdinalIgnoreCase))
                return CutoverPhase.Legacy;

            // A date the client cannot read is treated as no date: the reader
            // gets silence rather than an announcement with a wrong day in it.
            if (!TryParseDate(rawDate, out _)) return CutoverPhase.None;

            // Note there is no expiry, and hence no clock in this rule. Being
            // served from the LIVE host on or after the announced day means the
            // swap slipped, and "from <date>" is still the true sentence — the
            // notice is retired by the swap itself (which moves this client to
            // the legacy host) or by clearing the setting, never by a date
            // comparison that would silence it exactly when it slipped.
            return CutoverPhase.Upcoming;
        }

        /// <summary>The announced date, for the sentence itself. Null when the
        /// setting is empty or malformed.</summary>
        public static DateOnly? AnnouncedDate(string? rawDate) =>
            TryParseDate(rawDate, out var d) ? d : null;

        /// <summary>ISO-only by contract (U-24): the wire format never depends
        /// on the reader's language, and a value in any other shape is treated
        /// as absent rather than guessed at.</summary>
        private static bool TryParseDate(string? raw, out DateOnly date) =>
            DateOnly.TryParseExact(
                (raw ?? string.Empty).Trim(),
                "yyyy-MM-dd",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None,
                out date);
    }
}
