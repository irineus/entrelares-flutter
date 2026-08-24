namespace Entrelares.Models
{
    // F-33 — the assembled consolidated history report ("relatório do histórico em PDF").
    // Pure data built by ReportPdfService.Build from the family's own RLS-scoped
    // reads; the Razor report view only renders it. No new server surface.
    public sealed class CustodyReport
    {
        public required string FamilyName { get; init; }

        // Optional free-text child name typed at generation (not stored — there
        // is no child entity yet; multi-child is F-07). Omitted when blank.
        public string? ChildName { get; init; }

        public required DateOnly PeriodStart { get; init; }
        public required DateOnly PeriodEnd { get; init; }

        // Device-local time (matches the on-screen audit timeline, which uses
        // ToLocalTime) — honest and consistent; the report footer states it.
        public required DateTime GeneratedAtLocal { get; init; }
        public required string GeneratedBy { get; init; }
        public required string AppVersion { get; init; }

        public required IReadOnlyList<CaregiverStat> Caregivers { get; init; }
        public required int TotalSwaps { get; init; }
        public required IReadOnlyList<ReportAuditEntry> AuditEntries { get; init; }

        // U-20: when true, the report was built with the "considerar trocas
        // futuras já aceitas" option — ProjectedDays is populated and every
        // swap count includes accepted future swaps.
        public required bool IncludesFutureSwaps { get; init; }

        public int TotalDays => PeriodEnd.DayNumber - PeriodStart.DayNumber + 1;
    }

    // Planned-vs-actual per caregiver — same semantics as the on-screen
    // "Resumo do Período" (ReportsSummary) so the numbers match exactly.
    public sealed class CaregiverStat
    {
        public required string Name { get; init; }
        public required string Role { get; init; }
        public required int PlannedDays { get; init; }
        public required int ActualDays { get; init; }

        // U-20: realized past days + future days with actual ?? scheduled
        // applied (approval writes actual_parent_id immediately, any date).
        // Null when the report does not include future swaps.
        public int? ProjectedDays { get; init; }

        // U-07: days this caregiver gave away (scheduled = them, actual =
        // someone else) and days they received (actual = them, scheduled =
        // someone else). Realized only, unless IncludesFutureSwaps.
        public required int SwapsGiven { get; init; }
        public required int SwapsReceived { get; init; }
    }

    // One audit-log row over the period, with the field-level diff (F-02)
    // produced by AuditService.ComputeDiff.
    public sealed class ReportAuditEntry
    {
        public required DateOnly AffectedDate { get; init; }
        public required DateTime TimestampLocal { get; init; }
        public required string ActionLabel { get; init; }
        public required string PerformedBy { get; init; }
        public required IReadOnlyList<AuditFieldChange> Changes { get; init; }

        // F-45: when the change was produced by a swap workflow, the origin
        // sentence (requester/approver or auto-approval) and the F-44 texts —
        // the motivation that makes the paid report genuinely richer. Null for
        // manual edits.
        public string? OriginText { get; init; }
        public string? OriginMessage { get; init; }
        public string? OriginNote { get; init; }
    }
}
