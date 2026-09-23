import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_sync/school_sync.dart';
import 'offline_providers.dart';
import 'school_connection.dart';

class SchoolCoordinator with WidgetsBindingObserver {
  final SchoolConnection connection;
  final SchoolSync sync;
  final Future<void> Function() changed;
  final status = ValueNotifier<String>(
    'Progress stays on this device until you join a class.',
  );
  Timer? _timer;
  bool _busy = false, _closed = false;
  SchoolCoordinator(this.connection, this.sync, this.changed) {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => run());
  }
  Future<void> run() async {
    if (_closed ||
        _busy ||
        !connection.signedIn ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      return;
    }
    _busy = true;
    status.value = 'Syncing school progress…';
    try {
      final count = await sync.sync();
      if (!_closed) {
        status.value = 'School sync complete · $count events delivered';
        await changed();
      }
    } catch (_) {
      if (!_closed) {
        status.value =
            'Offline or school unavailable. Progress is saved; sync will retry.';
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(run());
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closed = true;
    _timer?.cancel();
    unawaited(connection.close());
    status.dispose();
  }
}

final schoolCoordinatorProvider =
    FutureProvider.family<SchoolCoordinator?, ContentBank>((ref, bank) async {
      if (!SchoolConnection.configured) return null;
      final store = await ref.watch(offlineStoreProvider.future);
      final connection = SchoolConnection('learner');
      await connection.restore();
      var closed = false;
      final coordinator = SchoolCoordinator(
        connection,
        SchoolSync(store, bank.graph, connection.api),
        () async {
          if (!closed) {
            await ref.read(offlineSessionProvider).session?.reloadProgress();
            ref.invalidate(localProfilesProvider);
          }
        },
      );
      ref.onDispose(() {
        closed = true;
        coordinator.dispose();
      });
      ref.listen(offlineSessionProvider, (_, next) {
        if (next.session != null) unawaited(coordinator.run());
      });
      unawaited(coordinator.run());
      return coordinator;
    });
