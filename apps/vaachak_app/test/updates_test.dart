import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:vaachak_app/updates.dart';

class FakePlay implements UpdateClient {
  int immediateCalls = 0, downloadCalls = 0, completions = 0;
  bool fail = false;
  AppUpdateResult result = AppUpdateResult.success;
  Completer<AppUpdateInfo>? pending;
  AppUpdateInfo info = update();
  static AppUpdateInfo update({
    int priority = 0,
    bool immediate = true,
    UpdateAvailability availability = UpdateAvailability.updateAvailable,
    InstallStatus status = InstallStatus.unknown,
  }) => AppUpdateInfo(
    updateAvailability: availability,
    immediateUpdateAllowed: immediate,
    immediateAllowedPreconditions: [],
    flexibleUpdateAllowed: true,
    flexibleAllowedPreconditions: [],
    availableVersionCode: 2,
    installStatus: status,
    packageName: 'ai.vaachak.vaachak_app',
    clientVersionStalenessDays: 0,
    updatePriority: priority,
  );
  @override
  Future<AppUpdateInfo> inspect() async {
    if (fail) throw StateError('offline');
    return pending == null ? info : pending!.future;
  }

  @override
  Future<AppUpdateResult> immediate() async {
    immediateCalls++;
    return result;
  }

  @override
  Future<AppUpdateResult> download() async {
    downloadCalls++;
    return result;
  }

  @override
  Future<void> complete() async {
    if (fail) throw StateError('install failed');
    completions++;
  }
}

void main() {
  test('routine download waits for explicit restart', () async {
    final play = FakePlay(), service = AppUpdateService(client: FakePlay());
    service.dispose();
    final subject = AppUpdateService(client: play);
    addTearDown(subject.dispose);
    await subject.check();
    expect(play.downloadCalls, 1);
    expect(play.completions, 0);
    expect(subject.readyToRestart, isTrue);
    await subject.restart();
    expect(play.completions, 1);
    expect(subject.readyToRestart, isFalse);
  });
  test('schema migration and critical priority use immediate mode', () async {
    final play = FakePlay();
    final service = AppUpdateService(client: play);
    addTearDown(service.dispose);
    await service.check(requiresSchemaMigration: true);
    play.info = FakePlay.update(priority: 4);
    await service.check();
    expect(play.immediateCalls, 2);
    expect(play.downloadCalls, 0);
  });
  test('unsupported immediate update and cancellation preserve use', () async {
    final play = FakePlay()
      ..info = FakePlay.update(priority: 4, immediate: false);
    final service = AppUpdateService(client: play);
    addTearDown(service.dispose);
    await service.check();
    expect(play.immediateCalls, 0);
    play.info = FakePlay.update();
    play.result = AppUpdateResult.userDeniedUpdate;
    await service.check();
    expect(service.readyToRestart, isFalse);
  });
  test(
    'process recovery resumes accepted update and restores downloaded state',
    () async {
      final play = FakePlay()
        ..info = FakePlay.update(
          availability: UpdateAvailability.developerTriggeredUpdateInProgress,
        );
      final service = AppUpdateService(client: play);
      addTearDown(service.dispose);
      await service.recover();
      expect(play.immediateCalls, 1);
      play.info = FakePlay.update(status: InstallStatus.downloaded);
      await service.recover();
      expect(service.readyToRestart, isTrue);
      expect(play.completions, 0);
      expect(play.downloadCalls, 0);
    },
  );
  test('single flight and disposal suppress late native actions', () async {
    final play = FakePlay()..pending = Completer<AppUpdateInfo>();
    final service = AppUpdateService(client: play);
    final first = service.check();
    await service.check();
    service.dispose();
    play.pending!.complete(FakePlay.update());
    await first;
    expect(play.downloadCalls, 0);
  });
  test('failed restart stays retryable', () async {
    final play = FakePlay();
    final service = AppUpdateService(client: play);
    addTearDown(service.dispose);
    await service.check();
    play.fail = true;
    await service.restart();
    expect(service.readyToRestart, isTrue);
    expect(service.busy, isFalse);
    play.fail = false;
    await service.restart();
    expect(play.completions, 1);
  });
}
