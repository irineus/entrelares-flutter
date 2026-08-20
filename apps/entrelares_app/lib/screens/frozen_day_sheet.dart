import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

import '../models/member.dart';
import '../models/swap_request.dart';
import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';

/// What the panel did — the caller picks the toast, mirroring the six success
/// paths of `Home.razor`'s frozen-panel handlers.
enum FrozenDayOutcome {
  approved,
  rejected,
  cancelled,
  revertConfirmed,
  revertRejected,
  revertCancelled,
}

/// The toast key for each outcome (web: ToastSwapApproved … ToastRevertCancelled).
String frozenOutcomeToastKey(FrozenDayOutcome outcome) => switch (outcome) {
      FrozenDayOutcome.approved => K.toastSwapApproved,
      FrozenDayOutcome.rejected => K.toastSwapRejected,
      FrozenDayOutcome.cancelled => K.toastRequestCancelled,
      FrozenDayOutcome.revertConfirmed => K.toastRevertConfirmed,
      FrozenDayOutcome.revertRejected => K.toastRevertRejected,
      FrozenDayOutcome.revertCancelled => K.toastRevertCancelled,
    };

/// The frozen-day panel (F-12) — port of `FrozenDayPanel.razor` as a native
/// bottom sheet. Tapping a day with an open request lands here instead of the
/// editor; the three roles see three different panels: the TARGET approves or
/// rejects (with the dual-purpose F-44 note), the REQUESTER cancels, everyone
/// else observes. The database enforces every transition regardless.
Future<FrozenDayOutcome?> showFrozenDaySheet({
  required BuildContext context,
  required SwapRequest request,
  required List<Member> allProfiles,
  required int? ownProfileId,
  required CustodyDataSource dataSource,
}) {
  return showModalBottomSheet<FrozenDayOutcome>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _FrozenDaySheet(
      request: request,
      allProfiles: allProfiles,
      ownProfileId: ownProfileId,
      dataSource: dataSource,
    ),
  );
}

class _FrozenDaySheet extends StatefulWidget {
  final SwapRequest request;
  final List<Member> allProfiles;
  final int? ownProfileId;
  final CustodyDataSource dataSource;

  const _FrozenDaySheet({
    required this.request,
    required this.allProfiles,
    required this.ownProfileId,
    required this.dataSource,
  });

  @override
  State<_FrozenDaySheet> createState() => _FrozenDaySheetState();
}

class _FrozenDaySheetState extends State<_FrozenDaySheet> {
  // F-44: one dual-purpose field — sent as the approval note on approve and
  // as the rejection reason on reject (web decision: no second input).
  late final TextEditingController _approverNote;
  bool _acting = false;

  /// Which button carries the spinner while [_acting] disables them all.
  String? _pendingAction;
  String? _error;

  @override
  void initState() {
    super.initState();
    _approverNote = TextEditingController();
  }

  @override
  void dispose() {
    _approverNote.dispose();
    super.dispose();
  }

  String? _nameOf(int? id) {
    for (final p in widget.allProfiles) {
      if (p.id == id) return p.fullName;
    }
    return null;
  }

  /// Web parity: blank collapses to null here, but the text goes through RAW
  /// — the service normalizes the approval note itself, while the rejection
  /// reason lands on the row exactly as typed.
  String? get _note =>
      _approverNote.text.trim().isEmpty ? null : _approverNote.text;

  Future<void> _run(
    String actionKey,
    String errorKey,
    Future<FrozenDayOutcome> Function() action,
  ) async {
    final l = AppL10n.of(context).l;
    setState(() {
      _acting = true;
      _pendingAction = actionKey;
      _error = null;
    });
    try {
      final outcome = await action();
      if (mounted) Navigator.of(context).pop(outcome);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _acting = false;
        _pendingAction = null;
        _error = isSessionExpired(e.toString())
            ? sessionExpiredMessage(l)
            : l.format(errorKey, [e.toString()]);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    final request = widget.request;
    final isRevert = request.status == 'revert_pending';
    final iAmRequester = widget.ownProfileId == request.requestingProfileId;
    final iAmTarget = widget.ownProfileId == request.targetProfileId;
    // F-20: computed at render time — the panel always shows a pending request.
    final tag = request.toView().priorityTag(DateTime.now());

    final requesterName = _nameOf(request.requestingProfileId);
    final targetName = _nameOf(request.targetProfileId);
    final proposedName = _nameOf(request.proposedActualParentId);

    final headerIcon = switch (tag) {
      SwapPriorityTag.overdue => '⏰',
      SwapPriorityTag.urgent => '⚠️',
      SwapPriorityTag.none => isRevert ? '↩️' : '⏳',
    };

    final handoff = parseTimeOfDay(request.proposedHandoffTime);
    final createdAtLocal = request.createdAt == null
        ? null
        : DateTime.tryParse(request.createdAt!)?.toLocal();

    Widget infoRow(String labelKey, String value, {bool isMessage = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                  child: Text(l[labelKey],
                      style: Theme.of(context).textTheme.bodySmall)),
              Expanded(
                child: Text(value,
                    textAlign: TextAlign.end,
                    style: isMessage
                        ? Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontStyle: FontStyle.italic)
                        : Theme.of(context).textTheme.bodyMedium),
              ),
            ],
          ),
        );

    Widget actionButton({
      required String actionKey,
      required String labelKey,
      required VoidCallback onPressed,
      bool filled = false,
      bool destructive = false,
    }) {
      final child = _pendingAction == actionKey
          ? const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(l[labelKey]);
      if (filled) {
        return FilledButton(onPressed: _acting ? null : onPressed, child: child);
      }
      if (destructive) {
        return OutlinedButton(
          onPressed: _acting ? null : onPressed,
          style: OutlinedButton.styleFrom(
              foregroundColor: context.tokens.danger.onContainer),
          child: child,
        );
      }
      return OutlinedButton(onPressed: _acting ? null : onPressed, child: child);
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(headerIcon, style: const TextStyle(fontSize: 24)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        l[isRevert ? K.frozenRevertTitle : K.frozenSwapTitle],
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
              if (tag != SwapPriorityTag.none) ...[
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: (tag == SwapPriorityTag.overdue
                            ? context.tokens.danger
                            : context.tokens.warning)
                        .container,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Text(
                    l[tag == SwapPriorityTag.overdue
                        ? K.frozenOverdue
                        : K.frozenUrgent],
                    style: TextStyle(
                        color: (tag == SwapPriorityTag.overdue
                                ? context.tokens.danger
                                : context.tokens.warning)
                            .onContainer),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                  l.format(
                      K.frozenDay, [l.formatDate(request.scheduleDate)]),
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              infoRow(K.frozenRequester, requesterName ?? '—'),
              infoRow(isRevert ? K.frozenRevertTo : K.frozenProposedParent,
                  proposedName ?? '—'),
              if (handoff != null)
                infoRow(
                    K.frozenProposedTime,
                    '${handoff.hour.toString().padLeft(2, '0')}:'
                    '${handoff.minute.toString().padLeft(2, '0')}'),
              // F-44: the requester's message travels with the request.
              if ((request.requestMessage ?? '').isNotEmpty)
                infoRow(K.frozenRequesterMessage, request.requestMessage!,
                    isMessage: true),
              if (createdAtLocal != null)
                infoRow(K.frozenRequestedAt, l.formatDateTime(createdAtLocal)),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text('⚠️ $_error',
                    style: TextStyle(
                        color: context.tokens.danger.onContainer)),
              ],
              const SizedBox(height: 12),
              if (iAmTarget) ...[
                Text.rich(TextSpan(children: [
                  TextSpan(text: l[K.frozenNoteLabel]),
                  TextSpan(
                      text: ' ${l[K.frozenNoteHint]}',
                      style: Theme.of(context).textTheme.bodySmall),
                ])),
                const SizedBox(height: 4),
                TextField(
                  controller: _approverNote,
                  maxLength: 200,
                  enabled: !_acting,
                  decoration: InputDecoration(
                    hintText: l[K.frozenNotePlaceholder],
                    border: const OutlineInputBorder(),
                    isDense: true,
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: isRevert
                          ? actionButton(
                              actionKey: 'approve',
                              labelKey: K.frozenConfirmRevert,
                              filled: true,
                              onPressed: () => _run(
                                  'approve',
                                  K.errConfirmRevertFailed,
                                  () async {
                                    await widget.dataSource.approveRevert(
                                        request.id,
                                        approvalNote: _note,
                                        allProfiles: widget.allProfiles);
                                    return FrozenDayOutcome.revertConfirmed;
                                  }),
                            )
                          : actionButton(
                              actionKey: 'approve',
                              labelKey: K.frozenApprove,
                              filled: true,
                              onPressed: () => _run(
                                  'approve',
                                  K.errApproveFailed,
                                  () async {
                                    await widget.dataSource.approveSwap(
                                        request.id,
                                        approvalNote: _note,
                                        allProfiles: widget.allProfiles);
                                    return FrozenDayOutcome.approved;
                                  }),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: actionButton(
                        actionKey: 'reject',
                        labelKey: K.frozenRejectAction,
                        onPressed: () => _run(
                            'reject',
                            isRevert
                                ? K.errRejectRevertFailed
                                : K.errRejectFailed,
                            () async {
                              if (isRevert) {
                                await widget.dataSource.rejectRevert(
                                    request.id,
                                    reason: _note,
                                    allProfiles: widget.allProfiles);
                                return FrozenDayOutcome.revertRejected;
                              }
                              await widget.dataSource.rejectSwap(request.id,
                                  reason: _note,
                                  allProfiles: widget.allProfiles);
                              return FrozenDayOutcome.rejected;
                            }),
                      ),
                    ),
                  ],
                ),
              ] else if (iAmRequester)
                actionButton(
                  actionKey: 'cancel',
                  labelKey:
                      isRevert ? K.frozenCancelRevert : K.frozenCancelRequest,
                  destructive: true,
                  onPressed: () => _run(
                      'cancel',
                      isRevert ? K.errCancelRevertFailed : K.errCancelFailed,
                      () async {
                        if (isRevert) {
                          await widget.dataSource.cancelRevert(request.id,
                              allProfiles: widget.allProfiles);
                          return FrozenDayOutcome.revertCancelled;
                        }
                        await widget.dataSource.cancelSwap(request.id,
                            allProfiles: widget.allProfiles);
                        return FrozenDayOutcome.cancelled;
                      }),
                )
              else
                Text(
                  l.format(K.frozenObserver,
                      [targetName ?? l[K.calOtherCaregiver]]),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
