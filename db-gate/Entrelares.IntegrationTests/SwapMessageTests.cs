using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-44 — the requester message (set at creation) and the approver note
    // (set on approval) persist on swap_requests and are readable by the OTHER
    // party through the family-scoped RLS, exactly as the app's panels need
    // them. Requests are written through the authenticated user clients, so
    // the same policies the real workflow hits are the ones under test.
    [Collection("e2e-family")]
    public class SwapMessageTests(E2EFamilyFixture fx)
    {
        [Fact] // The approver (target) reads the requester's message on the pending row.
        public async Task RequestMessage_PersistsAndIsVisibleToTheTarget()
        {
            var date = fx.NextFutureDate();

            var request = (await fx.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow,
                RequestMessage = "Tenho consulta médica nesse dia"
            })).Models!.First();

            var seenByTarget = (await fx.Founder.From<SwapRequest>()
                .Where(r => r.Id == request.Id)
                .Get()).Models!.Single();

            Assert.Equal("Tenho consulta médica nesse dia", seenByTarget.RequestMessage);
            Assert.Null(seenByTarget.ApprovalNote);
        }

        [Fact] // Approval writes the note alongside the status flip (full-row
               // update, like SwapRequestService.ApproveAsync) and the requester
               // reads it back on the resolved row.
        public async Task ApprovalNote_PersistsOnApproval_AndIsVisibleToTheRequester()
        {
            var date = fx.NextFutureDate();

            var request = (await fx.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow,
                RequestMessage = "Viagem de trabalho"
            })).Models!.First();

            var toApprove = (await fx.Founder.From<SwapRequest>()
                .Where(r => r.Id == request.Id)
                .Get()).Models!.Single();
            toApprove.Status = "approved";
            toApprove.ApprovalNote = "Combinado, busco às 18h";
            toApprove.ResolvedAt = DateTime.UtcNow;
            toApprove.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<SwapRequest>().Update(toApprove);

            var seenByRequester = (await fx.Member.From<SwapRequest>()
                .Where(r => r.Id == request.Id)
                .Get()).Models!.Single();

            Assert.Equal("approved", seenByRequester.Status);
            Assert.Equal("Combinado, busco às 18h", seenByRequester.ApprovalNote);
            // The creation message survives resolution untouched.
            Assert.Equal("Viagem de trabalho", seenByRequester.RequestMessage);
        }
    }
}
