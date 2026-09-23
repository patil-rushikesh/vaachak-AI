import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_sync/vaachak_sync.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native QR image decoding reconstructs an authenticated file bundle',
    (tester) async {
      final directory = await (await getTemporaryDirectory()).createTemp(
        'phase3-qr-',
      );
      final scanner = MobileScannerController(autoStart: false);
      try {
        final codec = BundleCodec(
          SecretKey(List.filled(32, 7)),
          'synthetic-class',
        );
        final events = List.generate(
          100,
          (i) => DomainEvent(
            id: i.toString().padLeft(26, '0'),
            learnerId: '00000000000000000000000001',
            deviceId: 'qr-device',
            seq: i + 1,
            hlc: HybridClock(1000, i, 'qr-device'),
            type: 'PracticeAttempt',
            payload: {
              'nodeId': 'grammar.articles',
              'itemId': 'synthetic-$i',
              'score': (i % 10) / 10,
            },
          ),
        );
        final encrypted = await codec.encode(
          ProgressBundle('qr-device', events),
        );
        final file = File('${directory.path}/progress.vbundle');
        await exportBundleFile(file, encrypted);
        expect((await importBundleFile(file, codec)).events.length, 100);
        final encoder = QrFountainEncoder(encrypted),
            decoder = QrFountainDecoder();
        expect(encoder.blocks, greaterThan(1));
        Uint8List? recovered;
        for (var index = encoder.blocks - 1; index >= 0; index--) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 1024, 1024),
            Paint()..color = Colors.white,
          );
          canvas.translate(32, 32);
          final frame = encoder.frame(index);
          QrPainter(
            data: frame,
            version: QrVersions.auto,
            eyeStyle: const QrEyeStyle(color: Colors.black),
            dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
          ).paint(canvas, const Size(960, 960));
          final picture = recorder.endRecording();
          final image = await picture.toImage(1024, 1024);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          final path = File('${directory.path}/frame.png');
          await path.writeAsBytes(png!.buffer.asUint8List());
          final capture = await scanner.analyzeImage(
            path.path,
            formats: [BarcodeFormat.qrCode],
          );
          expect(capture, isNotNull);
          final decoded = capture!.barcodes
              .map((b) => b.rawValue)
              .whereType<String>()
              .single;
          expect(decoded, frame);
          recovered = decoder.add(decoded) ?? recovered;
        }
        expect(recovered, encrypted);
        expect(
          (await codec.decode(recovered!)).events.map((e) => e.id),
          events.map((e) => e.id),
        );
        // ignore: avoid_print
        print(
          'PHASE3_QR_NATIVE: 100 events, ${encoder.blocks} rendered frames, Android native decoder, authenticated file and QR round trip passed',
        );
      } finally {
        await scanner.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
