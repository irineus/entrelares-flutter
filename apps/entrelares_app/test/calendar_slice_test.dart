// The slice against a fake data source: grid painting, the day sheet's write
// path (insert and full-row update), conflict translation, the Realtime
// callback triggering a reload — and, since the U-13 port, that an English
// session renders the same slice in English.
import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:entrelares_app/models/app_notification.dart';
import 'package:entrelares_app/models/care_schedule.dart';
import 'package:entrelares_app/models/family.dart';
import 'package:entrelares_app/models/member.dart';
import 'package:entrelares_app/models/swap_request.dart';
import 'package:entrelares_app/screens/calendar_screen.dart';
import 'package:entrelares_app/services/admin_mode.dart';
import 'package:entrelares_app/services/custody_data_source.dart';
import 'package:entrelares_app/widgets/app_l10n.dart';

class FakeCustodyDataSource implements CustodyDataSource {
  final List<Member> members;
  List<CareSchedule> days;
  final List<CareSchedule> inserted = [];
  final List<CareSchedule> updated = [];
  final List<int> deleted = [];
  Family? family;
  Object? throwOnFamily;
  Map<String, String> publicSettings = const {};
  Object? throwOnWrite;
  void Function()? realtimeCallback;
  int monthFetches = 0;

  FakeCustodyDataSource({required this.members, required this.days});

  @override
  Future<List<Member>> fetchMembers() async => members;

  @override
  Future<Member?> fetchOwnProfile() async => members.firstOrNull;

  @override
  Future<List<CareSchedule>> fetchUpcoming(DateTime from, int days) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = start.add(Duration(days: days));
    return this
        .days
        .where((d) =>
            !d.scheduleDate.isBefore(start) && !d.scheduleDate.isAfter(end))
        .toList();
  }

  @override
  Future<Family?> fetchOwnFamily() async {
    if (throwOnFamily != null) throw throwOnFamily!;
    return family;
  }

  @override
  Future<Map<String, String>> fetchPublicSettings() async => publicSettings;

  @override
  Future<void> updateOwnLanguage(int profileId, String languageCode) async {}

  @override
  Future<void> updateDetectedLanguage(
      int profileId, String languageCode) async {}

  @override
  Future<List<CareSchedule>> fetchMonth(int year, int month) async {
    monthFetches++;
    return days
        .where((d) =>
            d.scheduleDate.year == year && d.scheduleDate.month == month)
        .toList();
  }

  @override
  Future<CareSchedule?> fetchDay(DateTime date) async {
    for (final d in days) {
      if (CareSchedule.isoDate(d.scheduleDate) == CareSchedule.isoDate(date)) {
        return d;
      }
    }
    return null;
  }

  @override
  Future<void> insertDay(CareSchedule day) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    inserted.add(day);
  }

  @override
  Future<void> deleteDay(int id) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    deleted.add(id);
    days = days.where((d) => d.id != id).toList();
  }

  @override
  Future<int> bulkInsertNewDays(List<CareSchedule> newDays,
      {void Function(int percent)? onProgress}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    final existing = {for (final d in days) CareSchedule.isoDate(d.scheduleDate)};
    final now = DateTime.now();
    final todayFloor = DateTime(now.year, now.month, now.day);
    var created = 0;
    for (final d in newDays) {
      if (d.scheduleDate.isBefore(todayFloor)) continue;
      if (existing.contains(CareSchedule.isoDate(d.scheduleDate))) continue;
      inserted.add(d);
      days = [...days, d];
      created++;
    }
    onProgress?.call(100);
    return created;
  }

  @override
  Future<void> updateDay(CareSchedule day) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    updated.add(day);
  }

  void Function(bool connected)? statusCallback;

  @override
  Future<void Function()> watchChanges(void Function() onChange,
      {void Function(bool connected)? onStatus}) async {
    realtimeCallback = onChange;
    statusCallback = onStatus;
    return () => realtimeCallback = null;
  }

  // ── Lote 3: swap workflow ──────────────────────────────────────────────────

  List<SwapRequest> frozenRequests = [];
  List<SwapRequest> pendingForMe = [];
  List<SwapRequest> sentRequests = [];
  List<AppNotification> notifications = [];
  PreEditNotes? preEditNotes;
  final List<Map<String, Object?>> createdSwapRequests = [];
  final List<Map<String, Object?>> revertRequests = [];
  final List<({int id, String? note})> approvedSwaps = [];
  final List<({int id, String? reason})> rejectedSwaps = [];
  final List<int> cancelledSwaps = [];
  final List<({int id, String? note})> approvedReverts = [];
  final List<({int id, String? reason})> rejectedReverts = [];
  final List<int> cancelledReverts = [];
  int markAllReadCalls = 0;

  @override
  Future<List<SwapRequest>> fetchFrozenRequestsForMonth(
          int year, int month) async =>
      frozenRequests
          .where((r) =>
              r.scheduleDate.year == year && r.scheduleDate.month == month)
          .toList();

  @override
  Future<List<SwapRequest>> fetchPendingForMe(int myProfileId) async =>
      pendingForMe;

  @override
  Future<List<SwapRequest>> fetchSentRequests(int myProfileId) async =>
      sentRequests;

  @override
  Future<void> createSwapRequest({
    required CareSchedule schedule,
    required int proposedActualParentId,
    String? proposedHandoffTime,
    String? requestMessage,
    required Member myProfile,
    required List<Member> allProfiles,
  }) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    createdSwapRequests.add({
      'date': CareSchedule.isoDate(schedule.scheduleDate),
      'proposed': proposedActualParentId,
      'handoff': proposedHandoffTime,
      'message': requestMessage,
      'requester': myProfile.id,
    });
  }

  @override
  Future<void> approveSwap(int swapRequestId,
      {String? approvalNote, required List<Member> allProfiles}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    approvedSwaps.add((id: swapRequestId, note: approvalNote));
  }

  @override
  Future<void> rejectSwap(int swapRequestId,
      {String? reason, required List<Member> allProfiles}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    rejectedSwaps.add((id: swapRequestId, reason: reason));
  }

  @override
  Future<void> cancelSwap(int swapRequestId,
      {required List<Member> allProfiles}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    cancelledSwaps.add(swapRequestId);
  }

  @override
  Future<void> requestRevert({
    required DateTime scheduleDate,
    required int currentActualProfileId,
    required int scheduledParentId,
    String? requestMessage,
    bool restoreNotes = false,
    required Member myProfile,
    required List<Member> allProfiles,
  }) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    revertRequests.add({
      'date': CareSchedule.isoDate(scheduleDate),
      'currentActual': currentActualProfileId,
      'scheduled': scheduledParentId,
      'message': requestMessage,
      'restoreNotes': restoreNotes,
      'requester': myProfile.id,
    });
  }

  @override
  Future<void> approveRevert(int swapRequestId,
      {String? approvalNote, required List<Member> allProfiles}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    approvedReverts.add((id: swapRequestId, note: approvalNote));
  }

  @override
  Future<void> rejectRevert(int swapRequestId,
      {String? reason, required List<Member> allProfiles}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    rejectedReverts.add((id: swapRequestId, reason: reason));
  }

  @override
  Future<void> cancelRevert(int swapRequestId,
      {required List<Member> allProfiles}) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    cancelledReverts.add(swapRequestId);
  }

  @override
  Future<PreEditNotes?> fetchPreEditNotes(DateTime scheduleDate) async =>
      preEditNotes;

  @override
  Future<List<AppNotification>> fetchNotifications(int myProfileId) async =>
      notifications;

  @override
  Future<void> markAllNotificationsRead(int myProfileId) async {
    markAllReadCalls++;
    notifications = [
      for (final n in notifications)
        AppNotification(
          id: n.id,
          recipientProfileId: n.recipientProfileId,
          type: n.type,
          title: n.title,
          message: n.message,
          params: n.params,
          swapRequestId: n.swapRequestId,
          isRead: true,
          createdAt: n.createdAt,
        ),
    ];
  }

  /// More than one subscriber (calendar + badge) — all get poked.
  final List<void Function()> workflowCallbacks = [];

  void Function()? get workflowCallback =>
      workflowCallbacks.isEmpty ? null : _fireAllWorkflow;

  void _fireAllWorkflow() {
    for (final cb in List.of(workflowCallbacks)) {
      cb();
    }
  }

  @override
  Future<void Function()> watchWorkflowChanges(void Function() onChange,
      {void Function(bool connected)? onStatus}) async {
    workflowCallbacks.add(onChange);
    return () => workflowCallbacks.remove(onChange);
  }

  // ── Lote 4: sudo elevation (S-10) ──
  /// Passwords the fake accepts; anything else answers like the real 401.
  String? sudoPassword;

  /// What [elevate] reports as `elevated_until`; null exercises the local
  /// 5-minute fallback.
  String? sudoElevatedUntil;

  /// Set to answer with a transport failure instead of a verdict.
  Object? throwOnElevate;

  final List<String> elevateAttempts = [];

  @override
  Future<String?> elevate(String password) async {
    elevateAttempts.add(password);
    if (throwOnElevate != null) throw throwOnElevate!;
    if (sudoPassword != null && password == sudoPassword) {
      return sudoElevatedUntil;
    }
    throw const ElevationRefused(
        serverMessage: 'Senha incorreta.', wrongPassword: true);
  }
}

const ana = Member(id: 1, fullName: 'Ana Souza', colorSlot: 1, userId: 'u1');
const bruno = Member(id: 2, fullName: 'Bruno Lima', colorSlot: 2, userId: 'u2');

DateTime get today => DateTime.now();
DateTime dayOfMonth(int day) => DateTime(today.year, today.month, day);

CareSchedule row(int id, DateTime date, int scheduled,
        {int? actual, int revision = 1}) =>
    CareSchedule.fromJson({
      'id': id,
      'schedule_date': CareSchedule.isoDate(date),
      'scheduled_parent_id': scheduled,
      'actual_parent_id': actual,
      'revision': revision,
      'revision_token': 'tok-$id',
    });

Widget app(FakeCustodyDataSource ds,
        {AppLanguage language = AppLanguage.ptBr, AdminMode? adminMode}) =>
    AppL10n(
      l: Localization(language),
      setLanguage: (_) async {},
      child: MaterialApp(
        home: CalendarScreen(
            dataSource: ds,
            adminMode: adminMode ?? AdminMode(),
            onSignOut: () async {}),
      ),
    );

/// Tomorrow, unless the month ends today (then the write tests short-circuit
/// — the fixed today of a CI clock never hits it two runs in a row).
int? get futureDay {
  final lastDay = DateTime(today.year, today.month + 1, 0).day;
  return today.day == lastDay ? null : today.day + 1;
}

Future<void> openDay(WidgetTester tester, int day) async {
  final finder = find.text('$day').last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The full editor is taller than the sheet's viewport — scroll the target
/// into view before tapping.
Future<void> tapSheet(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Lets the save/clear SnackBar's dismiss timer fire so none outlives a test.
Future<void> settleSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 9));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('legend shows active members and the grid paints initials',
      (tester) async {
    final ds = FakeCustodyDataSource(
      members: [ana, bruno],
      days: [row(1, dayOfMonth(10), 1), row(2, dayOfMonth(11), 1, actual: 2)],
    );
    await tester.pumpWidget(app(ds));
    await tester.pumpAndSettle();

    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Bruno'), findsOneWidget);
    expect(find.text('Trocado'), findsOneWidget);
    // Day 10 belongs to Ana ("A"); day 11 is swapped to Bruno ("B").
    expect(find.text('A'), findsWidgets);
    expect(find.text('B'), findsWidgets);
  });

  testWidgets('unassigned future day: sheet inserts with the chosen parent',
      (tester) async {
    final ds = FakeCustodyDataSource(members: [ana, bruno], days: []);
    await tester.pumpWidget(app(ds));
    await tester.pumpAndSettle();

    final day = futureDay;
    if (day == null) return;
    await openDay(tester, day);
    // Since lote 2 the sheet is the FULL editor — the planned-parent label.
    expect(find.text('Responsável Agendado (Planejado)'), findsOneWidget);

    await tapSheet(tester, find.widgetWithText(ChoiceChip, 'Bruno'));
    await tapSheet(tester, find.text('Salvar'));

    expect(ds.inserted, hasLength(1));
    expect(ds.inserted.single.scheduledParentId, 2);
    expect(ds.inserted.single.scheduleDate, dayOfMonth(day));
    expect(ds.updated, isEmpty);

    // The save confirmation SnackBar (web: Toast.ShowSuccess(K.ToastSaved)).
    expect(find.text('Salvo com sucesso'), findsOneWidget);
    await settleSnack(tester);
  });

  testWidgets(
      'assigned future day: sheet updates the FULL row with the token echo',
      (tester) async {
    final day = futureDay;
    if (day == null) return;
    final ds = FakeCustodyDataSource(
      members: [ana, bruno],
      days: [row(5, dayOfMonth(day), 1, revision: 4)],
    );
    await tester.pumpWidget(app(ds));
    await tester.pumpAndSettle();

    await openDay(tester, day);
    // S-09 (lote 2): the planned parent of an assigned day is locked for
    // non-admins — the note is the editable surface that triggers the update.
    await tester.enterText(find.byType(TextField), 'Trocar mochila');
    await tapSheet(tester, find.text('Salvar'));

    expect(ds.updated, hasLength(1));
    final sent = ds.updated.single;
    expect(sent.id, 5);
    expect(sent.scheduledParentId, 1);
    expect(sent.notes, 'Trocar mochila');
    final json = sent.toUpdateJson();
    expect(json['submitted_token'], 'tok-5', reason: 'T-35 echo must survive');
    expect(json['revision'], 4, reason: 'T-33 revision as read');

    await settleSnack(tester);
  });

  testWidgets('day conflict shows the "salvou primeiro" message',
      (tester) async {
    final day = futureDay;
    if (day == null) return;
    final ds = FakeCustodyDataSource(
      members: [ana, bruno],
      days: [row(5, dayOfMonth(day), 1)],
    )..throwOnWrite = Exception(
        '{"code":"23505","message":"duplicate key value violates unique '
        'constraint \\"care_schedules_family_schedule_date_key\\""}');
    await tester.pumpWidget(app(ds));
    await tester.pumpAndSettle();

    await openDay(tester, day);
    await tester.enterText(find.byType(TextField), 'Nota qualquer');
    await tapSheet(tester, find.text('Salvar'));

    expect(
        find.textContaining('salvou este dia primeiro'), findsOneWidget);
  });

  testWidgets('past days are read-only (day-protection mirror)',
      (tester) async {
    // Run this one only when the month has a past day (i.e. not on the 1st).
    if (today.day == 1) return;
    final ds = FakeCustodyDataSource(
      members: [ana, bruno],
      days: [row(9, dayOfMonth(1), 1)],
    );
    await tester.pumpWidget(app(ds));
    await tester.pumpAndSettle();

    final finder = find.text('1').last;
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    // The amber readonly banner (web: .readonly-banner / K.editorPastReadonly).
    expect(
        find.text('🔒 Dia passado — apenas visualização'), findsOneWidget);
    expect(find.text('Salvar'), findsNothing);
  });

  testWidgets('a Realtime event reloads the visible month', (tester) async {
    final ds = FakeCustodyDataSource(members: [ana, bruno], days: []);
    await tester.pumpWidget(app(ds));
    await tester.pumpAndSettle();
    final before = ds.monthFetches;

    ds.realtimeCallback!();
    await tester.pumpAndSettle();
    expect(ds.monthFetches, greaterThan(before));
  });

  // U-13/U-24 — the proof the pilot never gave: the SAME slice, English
  // session. Words come from the catalog, the day sheet question included;
  // names stay user data; the swapped legend translates.
  testWidgets('an English session renders the slice in English',
      (tester) async {
    final day = futureDay;
    if (day == null) return;
    final ds = FakeCustodyDataSource(
      members: [ana, bruno],
      days: [row(1, dayOfMonth(day), 1, actual: 2)],
    );
    await tester.pumpWidget(app(ds, language: AppLanguage.en));
    await tester.pumpAndSettle();

    expect(find.text('Swapped'), findsOneWidget);
    expect(find.text('Trocado'), findsNothing);
    expect(find.text('Ana'), findsOneWidget, reason: 'names never translate');

    await openDay(tester, day);
    expect(find.text('Planned caregiver'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.textContaining('(swapped)'), findsOneWidget);
  });
}
