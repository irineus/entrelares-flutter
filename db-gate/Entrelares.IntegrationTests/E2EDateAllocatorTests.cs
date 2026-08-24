namespace Entrelares.IntegrationTests
{
    // The allocator that hands day-cell tests their dates is pure, and it has
    // already taken the master gate down twice near a month end — first by
    // clamping an overflow onto a PAST day (immutable per V008, plus a UNIQUE
    // violation on every repeat), then by handing out the LAST grid row, which
    // the fixed selection action bar covers, so the press landed on the bar.
    // Both are invisible for most of the month, which is exactly why they are
    // pinned here instead of being rediscovered during a promotion.
    [Trait("pack", "p0")]
    public class E2EDateAllocatorTests
    {
        // Mirror of the calendar's own layout, Sunday-first (Home.razor builds
        // the grid with blankDaysBefore = (int)firstDayOfMonth.DayOfWeek).
        private static int Blanks(DateOnly d) => (int)new DateOnly(d.Year, d.Month, 1).DayOfWeek;
        private static int Row(DateOnly d) => (Blanks(d) + d.Day - 1) / 7;
        private static int LastRow(DateOnly d) => (Blanks(d) + DateTime.DaysInMonth(d.Year, d.Month) - 1) / 7;

        [Theory]  // Every block: one month, above the last row, always forward.
        [InlineData(1)]
        [InlineData(2)]
        [InlineData(3)]
        public void NextVisibleDays_StaysInOneMonth_AndOffTheLastGridRow(int count)
        {
            var fx = new E2EFamilyFixture();
            var previous = DateOnly.MinValue;

            // Enough blocks to walk more than a year of month shapes, so the
            // 28-day February and the 31-day month that starts on a Saturday
            // (the shape that failed on 24/08/2026) are both covered.
            for (var i = 0; i < 200; i++)
            {
                var block = fx.NextVisibleDays(count);
                Assert.Equal(count, block.Count);

                Assert.All(block, d => Assert.Equal(block[0].Month, d.Month));
                Assert.All(block, d => Assert.True(Row(d) < LastRow(d),
                    $"{d:yyyy-MM-dd} is on the last grid row (row {Row(d)} of {LastRow(d)})"));

                // Only ever forward: the UNIQUE (family_id, schedule_date)
                // constraint is what the whole allocator exists to respect.
                Assert.True(block[0] > previous, $"{block[0]:yyyy-MM-dd} does not follow {previous:yyyy-MM-dd}");
                previous = block[^1];
            }
        }

        [Fact]  // A block that no month can hold fails loudly instead of spinning.
        public void NextVisibleDays_RefusesABlockNoMonthCanHold()
        {
            var fx = new E2EFamilyFixture();
            Assert.Throws<ArgumentOutOfRangeException>(() => fx.NextVisibleDays(22));
            Assert.Throws<ArgumentOutOfRangeException>(() => fx.NextVisibleDays(0));
        }
    }
}
