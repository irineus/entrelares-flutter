import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../deep_link_urls.dart';
import '../models/family.dart';
import '../models/family_invitation.dart';
import '../models/member.dart';
import '../models/role.dart';
import '../services/admin_mode.dart';
import '../services/custody_data_source.dart';
import '../services/sudo_service.dart';
import '../widgets/app_l10n.dart';
import '../widgets/app_snack.dart';
import '../widgets/sudo_sheet.dart';

/// `/family` — port of `FamilyPage.razor`.
///
/// **The page is a roster, not an editor** (F-16): tapping a member opens their
/// profile, where the name, the role and the admin flag actually change. That
/// split is the web's and it survives here, because the profile page is also
/// where e-mail, password, LGPD export and leaving the family live.
///
/// Deliberately NOT here yet: the premium/billing block (lote 5 by the parity
/// map's order — and the store build must never carry an external checkout
/// link, T-38).
///
/// The S-11 family-deletion panel DOES live here, and its rule is unusual
/// enough to state: unanimity means every voter has an explicit `agreed` row.
/// A missing answer is not consent — silence never deletes a family — and one
/// refusal ends the request outright.
class FamilyScreen extends StatefulWidget {
  final CustodyDataSource dataSource;
  final AdminMode adminMode;
  final SudoService sudo;

  /// Opens the F-41 page. Null hides the link (nothing to navigate to).
  final VoidCallback? onOpenCustomRoles;

  /// Opens a member's profile — own card or, for an admin, anyone's (F-16).
  /// Null leaves the cards inert.
  final void Function(Member member, bool isOwn)? onOpenProfile;

  /// Called when the family is gone — every session must end.
  final Future<void> Function()? onFamilyDeleted;

  const FamilyScreen({
    super.key,
    required this.dataSource,
    required this.adminMode,
    required this.sudo,
    this.onOpenCustomRoles,
    this.onOpenProfile,
    this.onFamilyDeleted,
  });

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  bool _loading = true;
  String? _loadErrorKey;

  Family? _family;
  Member? _me;
  List<Member> _members = const [];
  List<Role> _roles = const [];
  List<FamilyInvitation> _invitations = const [];
  PublicSettings _settings = PublicSettings.unloaded;

  // Rename
  bool _editingName = false;
  final _nameDraft = TextEditingController();

  // Invite form
  final _inviteEmail = TextEditingController();
  int _inviteRoleId = 0;
  String? _inviteErrorKey;
  bool _sendingInvite = false;

  // S-11 family deletion
  PendingFamilyDeletion? _deletion;
  bool _confirmingRequest = false;
  bool _confirmingExecute = false;
  bool _deletionBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameDraft.dispose();
    _inviteEmail.dispose();
    super.dispose();
  }

  bool get _isAdmin => _me?.isAdmin == true;

  int get _activeMemberCount =>
      _members.where((m) => m.isActiveMember).length;

  int get _pendingInvitationCount {
    final now = DateTime.now().toUtc();
    return _invitations.where((i) => i.isPending(now)).length;
  }

  int get _seatsTaken => seatsTaken(
      activeMembers: _activeMemberCount,
      pendingInvitations: _pendingInvitationCount);

  bool get _isPremium =>
      Family.isPremiumFamily(_family, DateTime.now().toUtc());

  bool get _atFreeCap => atFreeCaregiverCap(
      isPremium: _isPremium,
      seatsTaken: _seatsTaken,
      freeLimit: _settings.freeCaregivers);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadErrorKey = null;
    });
    try {
      final results = await Future.wait([
        widget.dataSource.fetchOwnFamily(),
        widget.dataSource.fetchMembers(),
        widget.dataSource.fetchRoles(),
        widget.dataSource.fetchOwnProfile(),
        widget.dataSource.fetchPublicSettings(),
      ]);
      final family = results[0] as Family?;
      final members = (results[1] as List<Member>).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final settings = PublicSettings(results[4] as Map<String, String>);

      // Web parity: the list is only fetched while there is a seat to fill —
      // it also feeds the seat arithmetic, so an empty list at the cap is
      // deliberate, not a bug.
      final active = members.where((m) => m.isActiveMember).length;
      final invitations = active < settings.maxCaregivers
          ? await widget.dataSource.fetchOpenInvitations()
          : <FamilyInvitation>[];
      final deletion = await widget.dataSource.fetchPendingFamilyDeletion();

      if (!mounted) return;
      setState(() {
        _deletion = deletion;
        _family = family;
        _members = members;
        _roles = results[2] as List<Role>;
        _me = results[3] as Member?;
        _settings = settings;
        _invitations = invitations;
        _nameDraft.text = family?.name ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadErrorKey = isSessionExpired(e.toString())
            ? KApp.sessionExpired
            : KApp.errCalendarLoad;
      });
    }
  }

  String _roleLabel(int? roleId, AppLanguage language) {
    if (roleId == null) return '';
    for (final role in _roles) {
      if (role.id == roleId) return role.displayLabel(language);
    }
    return '';
  }

  Future<void> _saveName(Localization l) async {
    final name = _nameDraft.text.trim();
    if (name.isEmpty) {
      showAppSnack(context, l[K.famErrFamilyNameRequired],
          type: AppSnackType.error);
      return;
    }
    // No-op short-circuit, as the web does — a rename that changes nothing
    // should not write an audit row.
    if (name == _family?.name) {
      setState(() => _editingName = false);
      return;
    }
    try {
      await widget.dataSource.renameFamily(name);
      if (!mounted) return;
      setState(() => _editingName = false);
      showAppSnack(context, l[K.famToastRenamed]);
      await _load();
    } catch (e) {
      if (!mounted) return;
      // The RPC's own PT-BR refusal is the useful text here.
      showAppSnack(context, translateSaveError(e.toString(), l[K.errSaveFailed], l),
          type: AppSnackType.error);
    }
  }

  Future<void> _sendInvite(Localization l) async {
    final errorKey = InviteFormRules.validationErrorKey(
      email: _inviteEmail.text,
      myEmail: _me?.email,
      roleId: _inviteRoleId,
    );
    if (errorKey != null) {
      setState(() => _inviteErrorKey = errorKey);
      return;
    }
    setState(() {
      _sendingInvite = true;
      _inviteErrorKey = null;
    });
    try {
      final id = await widget.dataSource
          .createInvitation(email: _inviteEmail.text.trim(), roleId: _inviteRoleId);
      final mailed = await widget.dataSource.sendInvitationEmail(id);
      if (!mounted) return;
      _inviteEmail.clear();
      setState(() {
        _inviteRoleId = 0;
        _sendingInvite = false;
      });
      showAppSnack(
          context, l[mailed ? K.famInviteEmailSent : K.famInviteEmailFailed],
          type: mailed ? AppSnackType.success : AppSnackType.info);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingInvite = false);
      // Every cap and permission refusal is the RPC's own sentence — it says
      // exactly which limit was hit, which no generic message could.
      showAppSnack(context, translateSaveError(e.toString(), l[K.errSaveFailed], l),
          type: AppSnackType.error);
    }
  }

  Future<void> _resendInvite(FamilyInvitation invitation, Localization l) async {
    try {
      // Resend semantics live entirely in the RPC: it revokes the previous
      // open invitation for this address before counting seats, so this never
      // trips its own cap.
      final id = await widget.dataSource
          .createInvitation(email: invitation.email, roleId: invitation.roleId);
      final mailed = await widget.dataSource.sendInvitationEmail(id);
      if (!mounted) return;
      showAppSnack(
          context,
          l[mailed ? K.famInviteResent : K.famInviteRenewedEmailFailed],
          type: mailed ? AppSnackType.success : AppSnackType.info);
      await _load();
    } catch (_) {
      if (!mounted) return;
      showAppSnack(context, l[K.famErrResendInvite], type: AppSnackType.error);
    }
  }

  Future<void> _revokeInvite(FamilyInvitation invitation, Localization l) async {
    try {
      await widget.dataSource.revokeInvitation(invitation.id);
      if (!mounted) return;
      showAppSnack(context, l[K.famInviteRevoked]);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppSnack(context, translateSaveError(e.toString(), l[K.errSaveFailed], l),
          type: AppSnackType.error);
    }
  }

  Future<void> _copyLink(FamilyInvitation invitation, Localization l) async {
    final link =
        InviteFormRules.inviteLink(DeepLinkUrls.webOrigin, invitation.token);
    try {
      await Clipboard.setData(ClipboardData(text: link));
      if (!mounted) return;
      showAppSnack(context, l[K.famLinkCopied]);
    } catch (_) {
      if (!mounted) return;
      showAppSnack(context, l[K.famErrCopy], type: AppSnackType.error);
    }
  }

  /// The native improvement over the web's "copy it and send on WhatsApp"
  /// hint: the system share sheet already knows every app this person uses.
  Future<void> _shareLink(FamilyInvitation invitation) async {
    final link =
        InviteFormRules.inviteLink(DeepLinkUrls.webOrigin, invitation.token);
    await Share.shareUri(Uri.parse(link));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(l[K.famHeading])),
        body: Center(child: Text(l[K.famLoading])),
      );
    }
    if (_loadErrorKey != null) {
      return Scaffold(
        appBar: AppBar(title: Text(l[K.famHeading])),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l[_loadErrorKey!]),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: Text(l[K.layoutErrorReload])),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l[K.famHeading])),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _familyNameBlock(l),
            const SizedBox(height: 24),
            _sectionTitle(l[K.famCaregivers]),
            const SizedBox(height: 8),
            ..._members.map((m) => _memberCard(m, l)),
            const SizedBox(height: 24),
            _inviteSection(l),
            if (_isAdmin) ...[
              const SizedBox(height: 24),
              _adminModeSection(l),
            ],
            const SizedBox(height: 24),
            _deletionSection(l),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text,
      style: Theme.of(context).textTheme.titleMedium);

  Widget _familyNameBlock(Localization l) {
    if (!_editingName) {
      return Row(
        children: [
          Expanded(
            child: Text(_family?.name ?? '',
                style: Theme.of(context).textTheme.headlineSmall),
          ),
          if (_isAdmin)
            IconButton(
              tooltip: l[K.famRename],
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => setState(() {
                _nameDraft.text = _family?.name ?? '';
                _editingName = true;
              }),
            ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _nameDraft,
            maxLength: RegisterRules.maxNameLength,
            decoration: InputDecoration(
              labelText: l[K.registerFamilyName],
              counterText: '',
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.check),
          onPressed: () => _saveName(l),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _editingName = false),
        ),
      ],
    );
  }

  Widget _memberCard(Member member, Localization l) {
    final theme = Theme.of(context);
    final role = _roleLabel(member.roleId, l.current);
    final isOwn = member.id == _me?.id;
    // Web parity: my own card always opens; anyone else's only for an admin.
    final canOpen =
        widget.onOpenProfile != null && (isOwn || _isAdmin);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: canOpen ? () => widget.onOpenProfile!(member, isOwn) : null,
        // The label the web puts on the clickable card, for screen readers.
        subtitleTextStyle: theme.textTheme.bodyMedium,
        leading: CircleAvatar(child: Text(member.initial)),
        title: Row(
          children: [
            Flexible(child: Text(member.fullName)),
            if (member.id == _me?.id) ...[
              const SizedBox(width: 6),
              Text(l[K.famYou], style: theme.textTheme.bodySmall),
            ],
          ],
        ),
        subtitle: role.isEmpty ? null : Text(role),
        trailing: Wrap(
          spacing: 6,
          children: [
            if (!member.isActiveMember)
              Chip(
                label: Text(l[K.famLeftBadge]),
                visualDensity: VisualDensity.compact,
              ),
            if (member.isAdmin)
              Chip(
                label: Text(l[K.famAdminBadge]),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }

  Widget _inviteSection(Localization l) {
    // Web parity: the whole block disappears once every seat is filled by a
    // live member — there is nothing to offer and nothing to revoke.
    if (_activeMemberCount >= _settings.maxCaregivers) {
      return const SizedBox.shrink();
    }

    final now = DateTime.now().toUtc();
    final pending = _invitations.where((i) => i.isPending(now)).toList();
    final expired = _invitations.where((i) => i.isExpired(now)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(l[K.famInviteSection]),
        const SizedBox(height: 8),
        if (!_isAdmin)
          Text(l[K.famOnlyAdminsInvite],
              style: Theme.of(context).textTheme.bodySmall)
        else ...[
          ...pending.map((i) => _invitationCard(i, l, expired: false)),
          ...expired.map((i) => _invitationCard(i, l, expired: true)),
          if (_atFreeCap)
            // F-37 without the upsell CTA: the checkout surface is lote 5, and
            // the store build must not carry an external checkout link (T-38).
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(l[K.famFreeCapNotice]),
              ),
            )
          else if (_seatsTaken < _settings.maxCaregivers)
            _inviteForm(l)
          else if (pending.isEmpty && expired.isEmpty)
            Text(l.format(K.famSeatsFull, [_settings.maxCaregivers])),
        ],
      ],
    );
  }

  Widget _invitationCard(FamilyInvitation invitation, Localization l,
      {required bool expired}) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(invitation.email)),
                Text(
                    expired
                        ? l[K.famInviteExpiredBadge]
                        : l[K.famInviteSentBadge],
                    style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(_roleLabel(invitation.roleId, l.current),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            if (expired)
              Text(l[K.famInviteExpiredHint], style: theme.textTheme.bodySmall)
            else
              Text(
                  l.format(K.famInviteValidUntil,
                      [l.formatDate(invitation.expiresAt.toLocal())]),
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (!expired) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(l[K.famCopyLink]),
                    onPressed: () => _copyLink(invitation, l),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: Text(l[KApp.commonShare]),
                    onPressed: () => _shareLink(invitation),
                  ),
                ],
                TextButton(
                  onPressed: () => _resendInvite(invitation, l),
                  child: Text(l[K.famResendInvite]),
                ),
                TextButton(
                  onPressed: () => _revokeInvite(invitation, l),
                  child: Text(l[K.famRevoke]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _inviteForm(Localization l) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.format(K.famInviteWhoHelps, [_settings.maxCaregivers]),
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        TextField(
          controller: _inviteEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: l[K.commonEmail],
            hintText: l[K.famInviteEmailPlaceholder],
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: _inviteRoleId == 0 ? null : _inviteRoleId,
          decoration: InputDecoration(labelText: l[K.famRoleInFamily]),
          items: [
            for (final role in _roles)
              DropdownMenuItem(
                value: role.id,
                child: Text(role.displayLabel(l.current)),
              ),
          ],
          onChanged: (value) => setState(() => _inviteRoleId = value ?? 0),
        ),
        if (widget.onOpenCustomRoles != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: widget.onOpenCustomRoles,
              child: Text(l[K.famCustomRolesLink]),
            ),
          ),
        if (_inviteErrorKey != null) ...[
          const SizedBox(height: 8),
          Text(l[_inviteErrorKey!],
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _sendingInvite ? null : () => _sendInvite(l),
          child: Text(_sendingInvite ? l[K.famSending] : l[K.famSendInvite]),
        ),
        const SizedBox(height: 8),
        Text(l[K.famInviteWhatsapp], style: theme.textTheme.bodySmall),
      ],
    );
  }

  // ── S-11: deleting the whole family ──────────────────────────────────────

  List<LifecycleMember> get _lifecycleMembers => _members
      .map((m) => LifecycleMember(
          id: m.id, isActiveMember: m.isActiveMember, isAdmin: m.isAdmin))
      .toList();

  List<DeletionVote> get _votes =>
      (_deletion?.responses ?? const [])
          .map((r) => DeletionVote(profileId: r.profileId, agreed: r.agreed))
          .toList();

  bool get _allAgreed {
    final deletion = _deletion;
    if (deletion == null) return false;
    return FamilyLifecycleRules.allAgreed(
      members: _lifecycleMembers,
      requesterProfileId: deletion.request.requestedBy,
      votes: _votes,
    );
  }

  Future<void> _runDeletionAction(
    Localization l, {
    required Future<void> Function() action,
    required bool sudo,
    String? successKey,
  }) async {
    if (_deletionBusy) return;
    setState(() => _deletionBusy = true);
    try {
      final ran = sudo
          ? await runWithSudo(
              context: context, sudo: widget.sudo, action: action)
          : await action().then((_) => true);
      if (!mounted) return;
      setState(() {
        _deletionBusy = false;
        _confirmingRequest = false;
        _confirmingExecute = false;
      });
      if (!ran) return;
      if (successKey != null) showAppSnack(context, l[successKey]);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletionBusy = false);
      showAppSnack(
          context, translateSaveError(e.toString(), l[K.errSaveFailed], l),
          type: AppSnackType.error);
    }
  }

  Future<void> _executeNow(Localization l) async {
    if (_deletionBusy) return;
    setState(() => _deletionBusy = true);
    try {
      final ran = await runWithSudo(
        context: context,
        sudo: widget.sudo,
        action: widget.dataSource.executeFamilyDeletion,
      );
      if (!mounted) return;
      if (!ran) {
        setState(() => _deletionBusy = false);
        return;
      }
      // Best-effort: the row is already scheduled for now, so the cron would
      // finish the job anyway — this just makes it immediate.
      await widget.dataSource.purgeNow();
      // Every session ends here, including this one: the family is gone.
      await widget.onFamilyDeleted?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletionBusy = false);
      showAppSnack(
          context, translateSaveError(e.toString(), l[K.errSaveFailed], l),
          type: AppSnackType.error);
    }
  }

  Widget _deletionSection(Localization l) {
    final deletion = _deletion;
    if (deletion != null) return _deletionPendingPanel(l, deletion);

    // Nothing pending: an admin with company may open one. A lone member
    // deletes the family by LEAVING, which is the profile page's flow.
    if (!FamilyLifecycleRules.canRequestFamilyDeletion(
        isAdmin: _isAdmin, activeMemberCount: _activeMemberCount)) {
      return const SizedBox.shrink();
    }
    return _deletionRequestPanel(l);
  }

  Widget _deletionRequestPanel(Localization l) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(l[K.famDelReqTitle]),
        const SizedBox(height: 8),
        Text(l[K.famDelReqIntro], style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        for (final consequence in [
          K.famDelReqConsequenceData,
          K.famDelReqConsequenceNotice,
          K.famDelReqConsequenceUnanimity,
          K.famDelReqConsequenceWithdraw,
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• ${l[consequence]}',
                style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        if (!_confirmingRequest)
          OutlinedButton(
            onPressed: () => setState(() => _confirmingRequest = true),
            child: Text(l[K.famDelReqOpen]),
          )
        else ...[
          // Two steps on purpose: the first press opens a question, the second
          // answers it. Nothing destructive is one tap away.
          Text(l[K.famDelReqConfirmText]),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _deletionBusy
                ? null
                : () => _runDeletionAction(
                      l,
                      sudo: true,
                      successKey: K.famToastDeletionRequested,
                      action: () async {
                        await widget.dataSource.requestFamilyDeletion();
                        await widget.dataSource
                            .sendAccountEmail('family_deletion_requested');
                      },
                    ),
            child: Text(l[K.famDelReqConfirm]),
          ),
          TextButton(
            onPressed: () => setState(() => _confirmingRequest = false),
            child: Text(l[K.famDelReqKeep]),
          ),
        ],
      ],
    );
  }

  Widget _deletionPendingPanel(
      Localization l, PendingFamilyDeletion deletion) {
    final theme = Theme.of(context);
    final request = deletion.request;
    final iAmRequester = request.requestedBy == _me?.id;
    final allAgreed = _allAgreed;
    final myVote =
        _me == null ? null : FamilyLifecycleRules.voteOf(_votes, _me!.id);
    final requesterName = _members
            .where((m) => m.id == request.requestedBy)
            .map((m) => m.fullName)
            .firstOrNull ??
        l[K.famRequesterFallback];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(l[K.famDelTitle]),
        const SizedBox(height: 8),
        if (allAgreed) ...[
          Text(l.format(K.famDelAllAgreed,
              [l.formatDate(request.scheduledFor.toLocal())])),
          const SizedBox(height: 4),
          Text(_isAdmin ? l[K.famDelAllAgreedAdmin] : l[K.famDelAllAgreedMember],
              style: theme.textTheme.bodySmall),
        ] else
          Text(l.format(K.famDelRequested, [
            requesterName,
            l.formatDateShort(request.requestedAt.toLocal()),
            l.formatDate(request.scheduledFor.toLocal()),
          ])),
        const SizedBox(height: 12),
        for (final consequence in [
          K.famDelConsequenceSilence,
          K.famDelConsequenceUnanimity,
          K.famDelConsequenceBlocked,
          K.famDelConsequenceExport,
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• ${l[consequence]}',
                style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        // Who said what — an absent row reads "aguardando", never "concordou".
        for (final voter in FamilyLifecycleRules.voters(
            _lifecycleMembers, request.requestedBy))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${_members.where((m) => m.id == voter.id).map((m) => m.fullName).firstOrNull ?? ''}'
              ' — ${switch (FamilyLifecycleRules.voteOf(_votes, voter.id)) {
                true => l[K.famDelVoteAgreed],
                false => l[K.famDelVoteRefused],
                null => l[K.famDelVoteWaiting],
              }}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 12),
        if (iAmRequester)
          OutlinedButton(
            onPressed: _deletionBusy
                ? null
                : () => _runDeletionAction(
                      l,
                      sudo: true,
                      successKey: K.famToastWithdrawn,
                      action: () async {
                        await widget.dataSource.withdrawFamilyDeletion();
                        await widget.dataSource
                            .sendAccountEmail('family_deletion_withdrawn');
                      },
                    ),
            child: Text(l[K.famDelWithdraw]),
          )
        else ...[
          // Refusing is NOT sudo-gated: it is the safe answer, and putting a
          // password in front of "keep my family" would be backwards.
          OutlinedButton(
            onPressed: _deletionBusy
                ? null
                : () => _runDeletionAction(
                      l,
                      sudo: false,
                      successKey: K.famToastRefused,
                      action: () async {
                        await widget.dataSource.respondFamilyDeletion(false);
                        await widget.dataSource
                            .sendAccountEmail('family_deletion_refused');
                      },
                    ),
            child: Text(l[K.famDelRefuseKeep]),
          ),
          const SizedBox(height: 8),
          if (myVote == true)
            TextButton(
              onPressed: _deletionBusy
                  ? null
                  : () => _runDeletionAction(
                        l,
                        sudo: false,
                        successKey: K.famToastAgreementUndone,
                        // A null answer REMOVES the row — back to waiting,
                        // which is not the same as refusing.
                        action: () =>
                            widget.dataSource.respondFamilyDeletion(null),
                      ),
              child: Text(l[K.famDelUndoAgreement]),
            )
          else
            TextButton(
              onPressed: _deletionBusy
                  ? null
                  : () => _runDeletionAction(
                        l,
                        sudo: false,
                        successKey: K.famToastAgreed,
                        action: () =>
                            widget.dataSource.respondFamilyDeletion(true),
                      ),
              child: Text(l[K.famDelAgree]),
            ),
        ],
        if (FamilyLifecycleRules.canExecuteNow(
            isAdmin: _isAdmin, allAgreed: allAgreed)) ...[
          const SizedBox(height: 12),
          if (!_confirmingExecute)
            OutlinedButton(
              onPressed: () => setState(() => _confirmingExecute = true),
              child: Text(l[K.famDelExecuteNowOpen]),
            )
          else ...[
            Text(l[K.famDelExecuteConfirmText],
                style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _deletionBusy ? null : () => _executeNow(l),
              child: Text(l[K.famDelExecuteNow]),
            ),
            TextButton(
              onPressed: () => setState(() => _confirmingExecute = false),
              child: Text(l[K.famDelBack]),
            ),
          ],
        ],
      ],
    );
  }

  Widget _adminModeSection(Localization l) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.adminMode,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle(l[K.famAdminSection]),
          const SizedBox(height: 8),
          Text(
              widget.adminMode.isActive
                  ? l[K.famAdminActiveNote]
                  : l[K.famAdminInactiveNote],
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          // F-40 is tier-aware, and saying so here is what stops a free-plan
          // admin from discovering the limit only when the trigger refuses.
          Text(
              _isPremium
                  ? l.format(K.famAdminTierPremium,
                      [_settings.overridePremiumMonths])
                  : l.format(K.famAdminTierFree, [
                      _settings.overrideFreeDays,
                      _settings.overridePremiumMonths
                    ]),
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          widget.adminMode.isActive
              ? OutlinedButton(
                  onPressed: widget.adminMode.deactivate,
                  child: Text(l[K.famAdminDeactivate]),
                )
              : FilledButton(
                  onPressed: widget.adminMode.toggle,
                  child: Text(l[K.famAdminActivate]),
                ),
        ],
      ),
    );
  }
}
