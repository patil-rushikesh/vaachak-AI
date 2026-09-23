import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_sync/vaachak_sync.dart';

void main() {
  final event = DomainEvent(
    id: '00000000000000000000000001',
    learnerId: 'learner',
    deviceId: 'device',
    seq: 1,
    hlc: HybridClock(1000, 0, 'device'),
    type: 'SessionStarted',
    payload: {},
  );
  test('bundle encryption round trip and wrong pairing fail closed', () async {
    final codec = BundleCodec(SecretKey(List.filled(32, 7)), 'class');
    final encoded = await codec.encode(ProgressBundle('device', [event]));
    expect(utf8.decode(encoded).contains('learner'), isFalse);
    expect((await codec.decode(encoded)).events.single.id, event.id);
    await expectLater(
      BundleCodec(SecretKey(List.filled(32, 8)), 'class').decode(encoded),
      throwsA(anything),
    );
    await expectLater(
      BundleCodec(SecretKey(List.filled(32, 7)), 'other').decode(encoded),
      throwsFormatException,
    );
    final j = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
    final bytes = base64Decode(j['ciphertext'] as String);
    bytes[0] ^= 1;
    j['ciphertext'] = base64Encode(bytes);
    await expectLater(
      codec.decode(utf8.encode(jsonEncode(j))),
      throwsA(anything),
    );
  });
  test('QR frames reconstruct out of order and tolerate duplicate scans', () {
    final original = Uint8List.fromList(List.generate(8000, (i) => i % 251)),
        decoder = QrFountainDecoder();
    final encoder = QrFountainEncoder(original);
    Uint8List? result;
    for (var i = encoder.blocks - 1; i >= 0; i--) {
      final frame = encoder.frame(i);
      expect(frame.length, lessThanOrEqualTo(2048));
      result = decoder.add(frame);
      result = decoder.add(frame) ?? result;
    }
    expect(result, original);
    expect(decoder.progress, 1);
  });
  test('fountain repair recovers a dropped systematic frame', () {
    final bytes = Uint8List.fromList(List.generate(8000, (i) => i % 251)),
        decoder = QrFountainDecoder(),
        encoder = QrFountainEncoder(
          Uint8List.fromList(List.generate(8000, (i) => i % 251)),
        );
    for (var i = 1; i < encoder.blocks; i++) {
      decoder.add(encoder.frame(i));
    }
    Uint8List? result;
    for (
      var i = encoder.blocks;
      i < encoder.blocks + 200 && result == null;
      i++
    ) {
      result = decoder.add(encoder.frame(i));
    }
    expect(result, bytes);
  });
  test('mixed and malformed QR frames rejected', () {
    final d = QrFountainDecoder();
    d.add(QrFountainEncoder(Uint8List(2000)).frame(0));
    expect(
      () => d.add(QrFountainEncoder(Uint8List(3000)).frame(0)),
      throwsFormatException,
    );
    expect(() => QrFountainDecoder().add('a' * 2049), throwsFormatException);
  });
}
