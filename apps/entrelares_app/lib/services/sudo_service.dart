import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/foundation.dart';

import 'custody_data_source.dart';

/// S-10 — session-scoped elevation state, mirror of the web's `SudoService`.
///
/// The SERVER owns the window (`auth_elevations`, written only by the `elevate`
/// Edge Function) and every gated RPC re-checks `is_elevated()`. This class
/// exists so the client can decide whether to ASK for the password before
/// spending a round-trip, and so the local throttle slows a keyboard attacker
/// on THIS device.
///
/// Never trust [isElevated] alone: the caller must ALSO handle the
/// `ELEVATION_REQUIRED:` marker coming back from the action itself. That second
/// layer is not redundant — it catches the window expiring between the check
/// and the RPC, and it is the only layer that works when the device clock has
/// drifted. [runWithSudo] wires both.
class SudoService extends ChangeNotifier {
  final CustodyDataSource _dataSource;

  DateTime? _elevatedUntilUtc;
  DateTime? _cooldownUntilUtc;
  int _failedAttempts = 0;

  SudoService(this._dataSource);

  /// Whether the client believes the window is open, with the 15 s safety
  /// margin already subtracted.
  bool get isElevated =>
      SudoRules.isElevated(_elevatedUntilUtc, DateTime.now().toUtc());

  /// Seconds left of the local throttle; 0 when the prompt may accept input.
  int get cooldownSecondsRemaining => SudoRules.cooldownSecondsRemaining(
      _cooldownUntilUtc, DateTime.now().toUtc());

  bool get isCoolingDown => cooldownSecondsRemaining > 0;

  /// Confirms the password. Returns null when the window is now open, or the
  /// message to show the user.
  ///
  /// The message is the SERVER's whenever it sent one — the local sentences are
  /// fallbacks for a body that could not be read at all.
  Future<String?> elevate(String password, Localization l) async {
    final remaining = cooldownSecondsRemaining;
    if (remaining > 0) {
      return l.format(KApp.sudoErrCooldown, ['$remaining']);
    }

    try {
      final until = await _dataSource.elevate(password);
      _elevatedUntilUtc =
          SudoRules.elevatedUntilFrom(until, DateTime.now().toUtc());
      _failedAttempts = 0;
      _cooldownUntilUtc = null;
      notifyListeners();
      return null;
    } on ElevationRefused catch (e) {
      if (e.wrongPassword) {
        final step = SudoRules.registerFailedAttempt(_failedAttempts);
        _failedAttempts = step.failedAttempts;
        if (step.cooldownStarts) {
          _cooldownUntilUtc = DateTime.now().toUtc().add(SudoRules.cooldown);
          notifyListeners();
          return l.format(
              KApp.sudoErrCooldown, ['${SudoRules.cooldown.inSeconds}']);
        }
        return e.serverMessage ?? l[KApp.sudoErrWrongPassword];
      }
      if (e.rateLimited) {
        // The server's own throttle — surface its text, and do not spend a
        // local attempt on it.
        return e.serverMessage ?? l[KApp.sudoErrGeneric];
      }
      return e.serverMessage ?? l[KApp.sudoErrGeneric];
    } catch (_) {
      // A dead session reaches here too: the invoke fails before any password
      // is judged, so nothing is counted against the user.
      return l[KApp.sudoErrConnection];
    }
  }

  /// Drops the window. Called when the authenticated phase ends — an elevation
  /// must never outlive the session that earned it.
  void reset() {
    if (_elevatedUntilUtc == null &&
        _cooldownUntilUtc == null &&
        _failedAttempts == 0) {
      return;
    }
    _elevatedUntilUtc = null;
    _cooldownUntilUtc = null;
    _failedAttempts = 0;
    notifyListeners();
  }
}
