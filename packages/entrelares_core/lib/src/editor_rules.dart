/// Client mirrors of the day editor's pure decision rules — ported from the
/// inline logic of `entrelares-app` `Entrelares/Pages/Home.razor`.
library;

/// F-28: who the current user may offer as the day's REAL responsible.
/// Anyone when they are the day's planned parent (scenario A); otherwise only
/// themselves (scenario B) — offering a third member would open a swap on
/// someone else's behalf (scenario C, forbidden; the service throws as the
/// backstop). The planned parent and the current actual stay listed so
/// no-swap and revert saves keep working. Mirror of `Home.CanOfferAsActual`.
bool canOfferAsActual({
  required int candidateId,
  required int? userProfileId,
  required int editingScheduledParentId,
  required int? existingActualParentId,
}) =>
    userProfileId == editingScheduledParentId ||
    candidateId == userProfileId ||
    candidateId == editingScheduledParentId ||
    candidateId == existingActualParentId;

/// S-09: rewriting the planned parent of an already-assigned day is
/// exceptional (admin mode only reaches here — the field is locked otherwise)
/// and requires an explicit confirmation before saving. Mirror of the guard
/// at the top of `Home.SaveChanges`.
bool needsAdminScheduleChangeConfirm({
  required int? existingScheduledParentId,
  required int editingScheduledParentId,
  required bool alreadyConfirmed,
}) =>
    existingScheduledParentId != null &&
    existingScheduledParentId != 0 &&
    editingScheduledParentId != existingScheduledParentId &&
    !alreadyConfirmed;
