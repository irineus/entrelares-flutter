import 'package:entrelares_core/entrelares_core.dart';

import 'package:entrelares_db_contracts/models/member.dart';
import 'custody_data_source.dart';

/// U-23 — reads the facts the activation checklist is decided from. Port of
/// `Entrelares/Services/OnboardingService.cs`.
///
/// The rules live in core ([OnboardingSteps]); this only gathers evidence, and
/// it is written to be CHEAP because the calendar is the hottest screen in the
/// app: a member who already dismissed the card costs zero queries, and the two
/// optional reads are skipped whenever an earlier fact already settles the step.
class OnboardingService {
  final CustodyDataSource _dataSource;

  OnboardingService(this._dataSource);

  /// Session-scoped, deliberately not persisted: "show it again" is a request
  /// for THIS session, not a new stored preference.
  bool checklistReopened = false;
  bool tourReplayRequested = false;

  /// [members] and [invitationsPending] are already in the caller's hands, so
  /// they are passed in rather than re-fetched.
  Future<OnboardingSignals> loadSignals({
    required Member me,
    required List<Member> members,
    bool force = false,
  }) async {
    final dismissed = me.onboardingDismissedAt != null;
    // The whole point of the short-circuit: a dismissed card asks nothing of
    // the network on every calendar open.
    if (dismissed && !force && !checklistReopened) {
      return const OnboardingSignals(checklistDismissed: true);
    }

    final hasOther = members.any((m) => m.id != me.id && m.isActiveMember);
    // Only worth asking when nobody holds the second seat yet.
    final hasInvitation =
        hasOther ? false : await _dataSource.hasOpenInvitation();

    final explained = me.onboardingSwapExplainedAt != null;
    final facts = await _dataSource.fetchOnboardingFacts(
      myProfileId: me.id,
      // Comprehension is not a row; participation is. Skip the second read
      // whenever the explanation already settles the step.
      includeSwapParticipation: !explained,
    );

    return OnboardingSignals(
      hasOtherActiveMember: hasOther,
      hasOpenInvitation: hasInvitation,
      hasAnyPlannedDay: facts.hasAnyPlannedDay,
      hasOpenedSwapExplanation: explained,
      hasTakenPartInASwap: facts.hasTakenPartInASwap,
      checklistDismissed: dismissed,
    );
  }

  /// Opening the explanation IS completing step 3 — stamped before the sheet
  /// renders, as in the web.
  Future<void> markSwapExplanationSeen() =>
      _dataSource.stampOnboarding(OnboardingStamp.swapExplained);

  Future<void> markTourSeen() =>
      _dataSource.stampOnboarding(OnboardingStamp.tourSeen);

  Future<void> markChecklistDismissed() =>
      _dataSource.stampOnboarding(OnboardingStamp.dismissed);

  /// The permanent door back in, from the profile page. It raises the
  /// session flag AND clears the stored dismissal — a guide you can only read
  /// once, by accident, is not a guide.
  Future<void> reopenChecklist() async {
    checklistReopened = true;
    await _dataSource.clearChecklistDismissal();
  }
}
