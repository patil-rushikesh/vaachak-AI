import 'dart:io';
import 'package:drift/native.dart';
import 'vaachak_store.dart';

VaachakStore openEncryptedStore(File file, String hexKey, String deviceId) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hexKey)) {
    throw ArgumentError('A 256-bit database key is required');
  }
  return VaachakStore(
    NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute("PRAGMA key = '$hexKey'");
        final cipher = db.select('PRAGMA cipher_version');
        if (cipher.isEmpty ||
            !cipher.first.values.first.toString().startsWith('4.')) {
          throw StateError(
            'SQLCipher 4 is unavailable; refusing to open unencrypted storage',
          );
        }
        db.execute('PRAGMA cipher_compatibility = 4');
        db.execute('PRAGMA cipher_memory_security = ON');
        db.execute('PRAGMA secure_delete = ON');
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA synchronous = FULL');
      },
    ),
    deviceId: deviceId,
  );
}
