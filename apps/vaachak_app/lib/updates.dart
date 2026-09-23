import 'dart:async';
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';

abstract class UpdateClient {
  Future<AppUpdateInfo> inspect();
  Future<AppUpdateResult> immediate();
  Future<AppUpdateResult> download();
  Future<void> complete();
}

class PlayUpdateClient implements UpdateClient {
  @override
  Future<AppUpdateInfo> inspect() => InAppUpdate.checkForUpdate();
  @override
  Future<AppUpdateResult> immediate() => InAppUpdate.performImmediateUpdate();
  @override
  Future<AppUpdateResult> download() => InAppUpdate.startFlexibleUpdate();
  @override
  Future<void> complete() => InAppUpdate.completeFlexibleUpdate();
}

/// Play priority >= 4 is the release contract for schema-changing binaries.
/// Downloaded flexible updates never restart a learner's activity automatically.
class AppUpdateService extends ChangeNotifier {
  final UpdateClient client;
  bool busy = false, readyToRestart = false, _closed = false;
  Timer? _inspectionTimer;
  Completer<AppUpdateInfo>? _inspection;
  String message = 'Check for a signed app update from Google Play.';
  AppUpdateService({UpdateClient? client})
    : client = client ?? PlayUpdateClient();
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || _closed) return;
    busy = true;
    _notify();
    try {
      await action();
    } catch (_) {
      message =
          'Updates are unavailable. Your saved learning remains available. '
          'Sideloaded builds need a signed update from your school.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<AppUpdateInfo> _inspect() {
    final pending = _inspection = Completer<AppUpdateInfo>();
    _inspectionTimer = Timer(const Duration(seconds: 20), () {
      if (!pending.isCompleted) {
        pending.completeError(TimeoutException('Play inspection timed out'));
      }
    });
    Future<AppUpdateInfo>.sync(client.inspect).then(
      (info) {
        if (!pending.isCompleted) pending.complete(info);
      },
      onError: (Object error, StackTrace stack) {
        if (!pending.isCompleted) pending.completeError(error, stack);
      },
    );
    return pending.future.whenComplete(() {
      _inspectionTimer?.cancel();
      _inspectionTimer = null;
      _inspection = null;
    });
  }

  Future<void> _immediate() async {
    final result = await client.immediate();
    message = result == AppUpdateResult.success
        ? 'The app update is completing through Google Play.'
        : 'Update was not completed. Your saved learning remains available.';
  }

  Future<void> check({bool requiresSchemaMigration = false}) => _run(() async {
    message = 'Checking Google Play…';
    final info = await _inspect();
    if (_closed) return;
    if (info.installStatus == InstallStatus.downloaded) {
      readyToRestart = true;
      message = 'Update downloaded. Restart when you have finished learning.';
    } else if (info.updateAvailability ==
        UpdateAvailability.developerTriggeredUpdateInProgress) {
      await _immediate();
    } else if (info.updateAvailability != UpdateAvailability.updateAvailable) {
      message = 'Your app is up to date.';
    } else if (requiresSchemaMigration || info.updatePriority >= 4) {
      if (!info.immediateUpdateAllowed) {
        message =
            'Install this update through the Play Store. Your data is preserved.';
        return;
      }
      await _immediate();
    } else if (!info.flexibleUpdateAllowed) {
      message = 'Open the Play Store to install this update.';
    } else {
      message = 'Downloading update. You can keep learning.';
      _notify();
      final result = await client.download();
      readyToRestart = result == AppUpdateResult.success;
      message = readyToRestart
          ? 'Update downloaded. Restart when you have finished learning.'
          : 'Download was not completed. You can try again later.';
    }
  });

  /// Inspect Play's durable status after process restart or foreground resume.
  /// Only resume an already accepted immediate update; do not start a new one.
  Future<void> recover() => _run(() async {
    final info = await _inspect();
    if (_closed) return;
    if (info.installStatus == InstallStatus.downloaded) {
      readyToRestart = true;
      message = 'Update downloaded. Restart when you have finished learning.';
    } else if (info.updateAvailability ==
        UpdateAvailability.developerTriggeredUpdateInProgress) {
      await _immediate();
    }
  });

  Future<void> restart() => _run(() async {
    if (!readyToRestart) return;
    await client.complete();
    readyToRestart = false;
    message = 'Restarting to finish the update.';
  });

  @override
  void dispose() {
    _closed = true;
    _inspectionTimer?.cancel();
    if (_inspection != null && !_inspection!.isCompleted) {
      _inspection!.completeError(StateError('Update page closed'));
    }
    super.dispose();
  }
}

class UpdatePage extends StatelessWidget {
  final AppUpdateService service;
  const UpdatePage({super.key, required this.service});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('App updates')),
    body: ListenableBuilder(
      listenable: service,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(service.message, semanticsLabel: service.message),
          const SizedBox(height: 24),
          if (service.busy) const LinearProgressIndicator(),
          FilledButton(
            onPressed: service.busy ? null : () => service.check(),
            child: const Text('Check and download update'),
          ),
          if (service.readyToRestart)
            OutlinedButton(
              onPressed: service.busy ? null : () => service.restart(),
              child: const Text('Restart and install'),
            ),
          const Text(
            'Routine updates download first. You choose when to restart. '
            'Important compatibility updates use Google Play’s immediate update flow.',
          ),
        ],
      ),
    ),
  );
}
