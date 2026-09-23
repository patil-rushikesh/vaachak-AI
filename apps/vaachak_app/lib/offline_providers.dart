import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_store/native.dart';
import 'package:vaachak_store/vaachak_store.dart';
import 'session.dart';

Future<VaachakStore> openDeviceStore() async {
  const secure = FlutterSecureStorage();
  final directory = await getApplicationSupportDirectory();
  final file = File('${directory.path}/vaachak.db');
  var key = await secure.read(key: 'vaachak.database.key');
  var device = await secure.read(key: 'vaachak.device.id');
  if (await file.exists() && (key == null || device == null)) {
    throw StateError(
      'Existing database identity is unavailable; restore its key and device identity',
    );
  }
  if (key == null) {
    key = List.generate(
      32,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await secure.write(key: 'vaachak.database.key', value: key);
  }
  if (device == null) {
    device = newUlid();
    await secure.write(key: 'vaachak.device.id', value: device);
  }
  final store = openEncryptedStore(file, key, device);
  try {
    await store.profiles();
    return store;
  } catch (_) {
    await store.close();
    rethrow;
  }
}

final offlineStoreProvider = FutureProvider<VaachakStore>((ref) async {
  var disposed = false;
  VaachakStore? opened;
  ref.onDispose(() {
    disposed = true;
    unawaited(opened?.close());
  });
  final store = await openDeviceStore();
  if (disposed) {
    await store.close();
    throw StateError('Storage opening was cancelled');
  }
  opened = store;
  return store;
}, retry: (count, error) => null);

final localProfilesProvider = FutureProvider<List<LocalProfile>>((ref) async {
  final store = await ref.watch(offlineStoreProvider.future);
  return List.unmodifiable(await store.profiles());
}, retry: (count, error) => null);

class PinRejected implements Exception {}

class UnlockCancelled implements Exception {}

class OfflineSessionState {
  final LearningSession? session;
  final int revision;
  const OfflineSessionState(this.session, [this.revision = 0]);
}

final offlineSessionProvider =
    NotifierProvider<OfflineSessionController, OfflineSessionState>(
      OfflineSessionController.new,
    );

class OfflineSessionController extends Notifier<OfflineSessionState> {
  int _generation = 0;
  LearningSession? _current;
  bool _closed = false;
  @override
  OfflineSessionState build() {
    ref.onDispose(() {
      _closed = true;
      _generation++;
      _release();
    });
    return const OfflineSessionState(null);
  }

  void _release() {
    final current = _current;
    _current = null;
    if (current == null) return;
    current.removeListener(_changed);
    current.ready = false;
    // Revoked-consent refresh can arrive inside notifyListeners. Defer disposal
    // until that notification unwinds while closing the session immediately.
    scheduleMicrotask(current.dispose);
  }

  void _changed() {
    if (_closed) return;
    if (_current?.ready != true) {
      lock();
    } else {
      state = OfflineSessionState(_current, state.revision + 1);
    }
  }

  Future<void> unlock(
    VaachakStore store,
    ContentBank bank,
    String profileId,
    String pin,
  ) async {
    final ticket = ++_generation;
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) throw PinRejected();
    try {
      if (!await store.unlock(profileId, pin)) throw PinRejected();
    } on PinLocked {
      throw PinRejected();
    }
    if (_closed || ticket != _generation) throw UnlockCancelled();
    final profiles = await store.profiles();
    final profile = profiles.singleWhere((p) => p.id == profileId);
    final next = LearningSession(store, bank, profile);
    try {
      if (_closed || ticket != _generation) throw UnlockCancelled();
      await next.start();
      if (_closed || ticket != _generation) throw UnlockCancelled();
      final previous = _current;
      if (previous != null) unawaited(previous.finish().catchError((_) {}));
      _release();
      _current = next;
      next.addListener(_changed);
      state = OfflineSessionState(next);
    } catch (_) {
      if (next.ready) unawaited(next.finish().catchError((_) {}));
      next.dispose();
      rethrow;
    }
  }

  /// Invalidates pending PIN checks as well as the currently unlocked profile.
  void lock() {
    _generation++;
    final previous = _current;
    if (previous != null) unawaited(previous.finish().catchError((_) {}));
    _release();
    if (!_closed) state = const OfflineSessionState(null);
  }
}
