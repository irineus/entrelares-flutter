// U-23's promised gate, cashed in at the close of lote 6 (README: "o teste
// 'toda chave declarada tem call site' só faz sentido com as telas todas
// portadas — entra no fechamento do lote 6").
//
// The catalogs were ported WHOLE in lote 1, so they carry entries for screens
// this stack does not have (and some it will never have). A key with no call
// site is therefore not automatically a bug — but an UNCLASSIFIED one is: it
// means someone catalogued a sentence and forgot to show it.
//
// The lists below are the inventory. Both directions are asserted: a new
// orphan fails, and so does a stale entry — so when lote 5 lands, the billing
// list must shrink or this test goes red.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the keys are declared; also the files whose own references do NOT
/// count as call sites (a catalog naming its keys proves nothing).
const _catalogFiles = {
  'k.dart',
  'k_app.dart',
  'strings_en.dart',
  'strings_pt_br.dart',
};

/// Lote 5 — premium and billing. The whole block is deliberately out of the
/// app until the T-48 redesign lands; the store build meanwhile shows the
/// neutral paywall (T-38).
const _billing = <String>{
  'K.famActivatePremiumLink',
  'K.famBillingHistoryLoadFailed',
  'K.famInterestRegistered',
  'K.famSeePremium',
  'K.famSubscriptionCancelled',
  'K.famSubscriptionReactivated',
  'K.payActiveBody',
  'K.payActiveTitle',
  'K.payAlmostBody',
  'K.payAlmostHint',
  'K.payAlmostTitle',
  'K.payBackToFamily',
  'K.payConfirmingBody',
  'K.payConfirmingTitle',
  'K.payGuarantee',
  'K.payPageTitle',
  'K.premActiveRenews',
  'K.premActiveStatus',
  'K.premAdminOnly',
  'K.premAvulsoAnnual',
  'K.premAvulsoLead',
  'K.premAvulsoMonthly',
  'K.premBadgeActive',
  'K.premBadgeForever',
  'K.premBadgeFree',
  'K.premBadgeTrialMany',
  'K.premBadgeTrialOne',
  'K.premBadgeTrialUntil',
  'K.premCancelButton',
  'K.premCancelConfirm',
  'K.premCancelKeep',
  'K.premCancelWarning',
  'K.premCancelWarningUntil',
  'K.premCycleAnnual',
  'K.premCycleMonthly',
  'K.premExpiredPaid',
  'K.premExpiredTrial',
  'K.premExpiringSoonMany',
  'K.premExpiringSoonOne',
  'K.premFeatureAdminMode',
  'K.premFeatureCaregivers',
  'K.premFeatureHorizon',
  'K.premFeaturePdf',
  'K.premFeatureRoles',
  'K.premForeverNote',
  'K.premGuarantee',
  'K.premHistoryEmpty',
  'K.premHistoryLoading',
  'K.premHistoryReceipt',
  'K.premHistoryToggle',
  'K.premInterestDone',
  'K.premInterestHint',
  'K.premInterestKeepTrial',
  'K.premInterestWant',
  'K.premIntro',
  'K.premIntroOffer',
  'K.premIntroWaitlist',
  'K.premOverdueGraceEnded',
  'K.premOverdueInGrace',
  'K.premOverdueInGraceNoDate',
  'K.premPaidUntilAvulso',
  'K.premPaidUntilPeriod',
  'K.premPaymentHint',
  'K.premReactivateButton',
  'K.premReactivateHint',
  'K.premReactivateHintDate',
  'K.premReactivateHintMethod',
  'K.premReactivateHintMethodDate',
  'K.premScheduledCancelButton',
  'K.premScheduledCancelKeep',
  'K.premScheduledCancelWarning',
  'K.premScheduledDetail',
  'K.premScheduledDetailMethod',
  'K.premScheduledStatus',
  'K.premStoreNote',
  'K.premStorePaidUntilAvulso',
  'K.premStorePaidUntilPeriod',
  'K.premStoreTrialUntil',
  'K.premSubscribeAnnual',
  'K.premSubscribeMonthly',
  'K.premTitle',
  'K.premTrialAdditive',
};

/// Web-only by construction, or replaced by a native affordance: document
/// <title> (an app has app bars), the PWA install banner and shell chrome (the
/// map DROPS them), the 404 route, ARIA strings the app expresses through
/// Semantics differently, the month buttons that became a swipe, the "Filtrar"
/// button that became reload-on-change, and the browser print hint the F-33
/// redesign replaced with the share sheet.
const _webOnly = <String>{
  'K.auditPageTitle',
  'K.bulkAriaLabel',
  'K.calAriaCalendarOf',
  'K.calAriaHandoffAt',
  'K.calAriaNoResponsible',
  'K.calAriaNotDefined',
  'K.calAriaRequestAwaitingYou',
  'K.calAriaRequestPending',
  'K.calAriaResponsible',
  'K.calAriaSelected',
  'K.calAriaSwapDone',
  'K.calAriaToday',
  'K.calNextMonth',
  'K.calPrevMonth',
  'K.editorAriaLabel',
  'K.famCopyInviteLink',
  'K.famPageTitle',
  'K.languageHint',
  'K.languageLabel',
  'K.layoutErrorBody',
  'K.layoutErrorTitle',
  'K.layoutInstallAction',
  'K.layoutInstallDismiss',
  'K.layoutInstallHint',
  'K.layoutInstallIosAddToHome',
  'K.layoutInstallIosShare',
  'K.layoutInstallIosTapOn',
  'K.layoutInstallIosThen',
  'K.layoutInstallIosTitle',
  'K.layoutInstallTitle',
  'K.layoutPolicyNoticeHint',
  'K.layoutPolicyNoticeTitle',
  'K.loginDismissNotice',
  'K.loginPageTitle',
  'K.navAdmin',
  'K.notFoundBack',
  'K.notFoundBody',
  'K.notFoundTitle',
  'K.notifFilterAria',
  'K.onbChecklistDismiss',
  'K.onbLauncherOpenAria',
  'K.pdfErrPrint',
  'K.pdfPageTitle',
  'K.pdfPrintHint',
  'K.pdfUpsellButton',
  'K.registerPageTitle',
  'K.repFilter',
  'K.repTabsAria',
  'K.resetPageTitle',
  'K.rolesPageTitle',
  'K.sumPageTitle',
  'K.updatePwdPageTitle',
  'K.wfAriaLabel',
};

/// The app says the same thing with its OWN entry in `k_app.dart` — the web's
/// version stays in the catalog because the catalog is a byte-identical port.
const _appHasItsOwnPhrase = <String>{
  'K.errConcurrentSave',
  'K.errConnection',
  'K.errProfileNotFound',
  'K.famOpenProfileOf',
  'K.homeBackToLogin',
  'K.homeTapToDefine',
  'K.loginPasswordPlaceholder',
  'K.loginSubmitting',
  'K.navNotifications',
  'K.rolesBackToFamily',
  'K.updatePwdConfirmPlaceholder',
  'K.updatePwdNewPasswordPlaceholder',
  'KApp.sheetNote',
  'KApp.sheetSave',
  'KApp.sheetWhoQuestion',
};

/// Honest debt: a sentence the web distinguishes and this app does not (yet).
/// Nothing here is a wrong screen — it is a screen that says something more
/// generic than it could. Shrinking this list is cheap, one key at a time.
const _notWiredYet = <String>{
  'K.authErrEmailChange',
  'K.authErrEmailInUse',
  'K.authErrEmailInvalid',
  'K.authErrEmailNotConfirmed',
  'K.authErrGeneric',
  'K.authErrMissingConfig',
  'K.authErrPasswordUpdate',
  'K.authErrRateLimitedReset',
  'K.authErrSignInFailed',
  'K.bulkClearDaysTitle',
  'K.calEmptyHint',
  'K.calEmptyTitle',
  'K.cardBackToCurrentMonth',
  'K.editorTitle',
  'K.famProgressDeleting',
  'K.homeSystemAlert',
  'K.loginExpiredFamilyDeleted',
  'K.loginExpiredToken',
  'K.notifErrApprove',
  'K.notifErrCancel',
  'K.notifErrCancelRevert',
  'K.notifErrConfirmRevert',
  'K.notifErrReject',
  'K.notifErrRejectRevert',
  'K.policyErrNoSession',
  'K.profErrSaveData',
  'K.repErrInit',
  'K.wizErrToast',
  'KApp.sudoErrNoSession',
};

void main() {
  test('every catalog key is either wired to a screen or classified', () {
    final declared = _declaredKeys();
    final used = _usedKeys();
    final orphans = declared.difference(used);
    final classified = {..._billing, ..._webOnly, ..._appHasItsOwnPhrase, ..._notWiredYet};

    expect(
      orphans.difference(classified),
      isEmpty,
      reason: 'A catalog key with no call site: wire it to a screen, or add it '
          'to one of the lists in this file saying WHY it has none.',
    );

    expect(
      classified.difference(orphans),
      isEmpty,
      reason: 'These keys are listed here as having no call site, but they DO '
          'have one now — remove them from the list.',
    );
  });
}

Set<String> _declaredKeys() {
  final keys = <String>{};
  for (final entry in {'K': 'k.dart', 'KApp': 'k_app.dart'}.entries) {
    final source = File(
            '../../packages/entrelares_core/lib/src/localization/${entry.value}')
        .readAsStringSync();
    for (final match
        in RegExp(r'static const String (\w+)\s*=').allMatches(source)) {
      keys.add('${entry.key}.${match.group(1)}');
    }
  }
  return keys;
}

Set<String> _usedKeys() {
  final used = <String>{};
  final pattern = RegExp(r'\b(K|KApp)\.(\w+)');
  for (final dir in [
    Directory('lib'),
    Directory('../../packages/entrelares_core/lib/src'),
  ]) {
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (_catalogFiles.contains(file.uri.pathSegments.last)) continue;
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        used.add('${match.group(1)}.${match.group(2)}');
      }
    }
  }
  return used;
}
