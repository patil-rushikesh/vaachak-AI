import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vaachak_sync/school_sync.dart';
import 'package:vaachak_sync/vaachak_sync.dart';

class SchoolTransferPage extends StatefulWidget {
  final SchoolSync sync;
  final String? learnerId, teacherId;
  const SchoolTransferPage({
    super.key,
    required this.sync,
    this.learnerId,
    this.teacherId,
  });
  @override
  State<SchoolTransferPage> createState() => _TransferState();
}

class _TransferState extends State<SchoolTransferPage>
    with WidgetsBindingObserver {
  List<SchoolPairing> pairs = [];
  SchoolPairing? selected;
  String message = 'Refresh once online to obtain approved pairings.';
  bool busy = false;
  int teacherBatch = 1;
  final address = TextEditingController();
  HotspotSharing? hotspot;
  SimpleKeyPair? teacherKey;
  bool get teacher => widget.teacherId != null;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load(false));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(hotspot?.stop());
    address.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(hotspot?.stop());
  }

  Future<void> action(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Transfer could not complete. Check pairing, permission and connection. Saved progress is unchanged.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(bool online) async {
    if (teacher) {
      const secure = FlutterSecureStorage();
      final keyName =
          'school.teacher.key:${widget.sync.api.scope}:${widget.teacherId}';
      var seed = await secure.read(key: keyName);
      if (seed == null) {
        final key = await Ed25519().newKeyPair();
        seed = base64Encode(await key.extractPrivateKeyBytes());
        await secure.write(key: keyName, value: seed);
      }
      teacherKey = await Ed25519().newKeyPairFromSeed(base64Decode(seed));
      if (online) {
        await widget.sync.api.rpc('register_teacher_key', {
          'public_key': base64Encode(
            (await teacherKey!.extractPublicKey()).bytes,
          ),
        });
      }
    }
    final all = await widget.sync.pairings(refresh: online);
    if (mounted) {
      setState(() {
        pairs = all
            .where(
              (p) =>
                  teacher ||
                  widget.learnerId == null ||
                  p.learnerId == widget.learnerId,
            )
            .toList();
        selected = pairs.isEmpty ? null : pairs.first;
        message = online
            ? 'Approved pairings refreshed. Learners should refresh after a teacher key changes.'
            : 'Saved pairings loaded. Refresh online to check changes.';
      });
    }
  }

  Future<Uint8List> export() async {
    final pair = selected!;
    if (!teacher) return widget.sync.exportProgress(pair);
    final rows = await widget.sync.api.request(
      'interventions?learner_id=eq.${Uri.encodeComponent(pair.learnerId)}&class_id=eq.${pair.classId}&teacher_id=eq.${widget.teacherId}&order=delivery_seq&limit=500&offset=${(teacherBatch - 1) * 500}',
    );
    final events = (rows as List)
        .map((r) => interventionEvent(Map<String, dynamic>.from(r as Map)))
        .toList();
    final bytes = await TeacherTransfer.encode(
      pair,
      widget.teacherId!,
      teacherKey!,
      events,
    );
    await widget.sync.store.setMetadata(
      'teacher.transfer:${pair.id}',
      jsonEncode({'batch': teacherBatch, 'bytes': base64Encode(bytes)}),
    );
    return bytes;
  }

  Future<Uint8List> outgoing() async {
    if (!teacher) return export();
    try {
      return await export();
    } catch (_) {
      final cached = await widget.sync.store.metadata(
        'teacher.transfer:${selected!.id}',
      );
      if (cached == null) rethrow;
      final saved = jsonDecode(cached) as Map<String, dynamic>;
      if (saved['batch'] != teacherBatch) rethrow;
      return base64Decode(saved['bytes'] as String);
    }
  }

  Future<void> receive(List<int> bytes) async {
    final pair = selected!;
    if (teacher) {
      // Durable encrypted inbox survives lack of network. Relaying is idempotent.
      final bundle = await pair.codec.decode(bytes);
      if (bundle.deviceId != pair.deviceId ||
          bundle.events.any(
            (e) => e.learnerId != pair.learnerId || e.deviceId != pair.deviceId,
          )) {
        throw const FormatException('Wrong learner');
      }
      final inbox = 'teacher.inbox:${pair.id}';
      final old =
          jsonDecode(await widget.sync.store.metadata(inbox) ?? '[]') as List;
      final encoded = base64Encode(bytes);
      if (!old.contains(encoded)) {
        if (old.length >= 20) {
          throw StateError('Relay saved files before receiving more');
        }
        old.add(encoded);
        await widget.sync.store.setMetadata(inbox, jsonEncode(old));
      }
      if (mounted) {
        setState(
          () => message =
              'Encrypted progress saved to the teacher inbox. Relay it when online.',
        );
      }
    } else {
      if (!await widget.sync.permitted(pair.learnerId)) {
        throw StateError('Sharing consent withdrawn');
      }
      final count = await TeacherTransfer.receive(
        pair,
        bytes,
        widget.sync.store,
        widget.sync.graph,
        widget.sync.transport.id,
      );
      if (mounted) setState(() => message = '$count teacher updates received.');
    }
  }

  Future<void> relayInbox() async {
    final key = 'teacher.inbox:${selected!.id}';
    final queue =
        jsonDecode(await widget.sync.store.metadata(key) ?? '[]') as List;
    var delivered = 0;
    while (queue.isNotEmpty) {
      delivered += await widget.sync.relay(
        selected!,
        base64Decode(queue.first as String),
      );
      queue.removeAt(0);
      await widget.sync.store.setMetadata(key, jsonEncode(queue));
    }
    if (mounted) {
      setState(() => message = '$delivered events delivered to the school.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        teacher ? 'Teacher offline transfers' : 'Offline school transfer',
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(message),
        if (busy) const LinearProgressIndicator(),
        OutlinedButton(
          onPressed: busy ? null : () => action(() => load(true)),
          child: const Text('Refresh approved pairings'),
        ),
        DropdownButtonFormField<String>(
          initialValue: selected?.id,
          key: ValueKey(selected?.id),
          decoration: const InputDecoration(labelText: 'Paired learner'),
          items: pairs
              .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
              .toList(),
          onChanged: busy
              ? null
              : (id) => setState(
                  () => selected = pairs.singleWhere((p) => p.id == id),
                ),
        ),
        if (selected != null) ...[
          if (teacher)
            TextFormField(
              initialValue: '1',
              enabled: !busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Teacher update batch (500 updates each)',
                helperText:
                    'Transfer batches in order. Repeating a batch is safe.',
              ),
              onChanged: (value) {
                final batch = int.tryParse(value);
                if (batch != null && batch > 0 && batch <= 1000000) {
                  setState(() => teacherBatch = batch);
                }
              },
            ),
          FilledButton(
            onPressed: busy
                ? null
                : () => action(() async {
                    final bytes = await outgoing();
                    final dir = await getTemporaryDirectory();
                    final file = File('${dir.path}/school-transfer.vbundle');
                    try {
                      await exportBundleFile(file, bytes);
                      await SharePlus.instance.share(
                        ShareParams(
                          files: [XFile(file.path)],
                          subject: 'Encrypted school transfer',
                        ),
                      );
                    } finally {
                      if (await file.exists()) await file.delete();
                    }
                  }),
            child: const Text('Share encrypted file'),
          ),
          OutlinedButton(
            onPressed: busy
                ? null
                : () => action(() async {
                    final choice = await FilePicker.pickFiles(
                      type: FileType.any,
                    );
                    if (choice.isEmpty) return;
                    final path = choice.single.path;
                    if (path == null) throw StateError('File unavailable');
                    final file = File(path);
                    if (await file.length() > BundleCodec.maxBytes * 2) {
                      throw const FormatException('File too large');
                    }
                    await receive(await file.readAsBytes());
                  }),
            child: const Text('Import encrypted file'),
          ),
          OutlinedButton(
            onPressed: busy
                ? null
                : () => action(() async {
                    final bytes = await outgoing();
                    if (!context.mounted) return;
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AnimatedTransferQr(bytes: bytes),
                      ),
                    );
                  }),
            child: const Text('Show animated QR'),
          ),
          OutlinedButton(
            onPressed: busy
                ? null
                : () => action(() async {
                    final bytes = await Navigator.push<Uint8List>(
                      context,
                      MaterialPageRoute(builder: (_) => const ScanTransferQr()),
                    );
                    if (bytes != null) await receive(bytes);
                  }),
            child: const Text('Scan transfer QR'),
          ),
          if (teacher)
            FilledButton(
              onPressed: busy ? null : () => action(relayInbox),
              child: const Text('Relay saved progress to school'),
            ),
          if (!teacher) ...[
            TextField(
              controller: address,
              decoration: const InputDecoration(
                labelText: 'Teacher hotspot address',
                hintText: 'http://192.168.1.2:12345/vbundle',
              ),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      await sendHotspot(
                        Uri.parse(address.text.trim()),
                        await outgoing(),
                      );
                      if (mounted) {
                        setState(
                          () => message =
                              'Encrypted transfer received by teacher. Server sync will confirm progress later.',
                        );
                      }
                    }),
              child: const Text('Send over local hotspot'),
            ),
          ] else
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      await hotspot?.stop();
                      final interfaces = await NetworkInterface.list(
                        type: InternetAddressType.IPv4,
                      );
                      final candidates = interfaces
                          .expand((i) => i.addresses)
                          .where(isPrivateAddress)
                          .where((a) => !a.isLoopback)
                          .toList();
                      if (candidates.isEmpty) {
                        throw StateError('Connect to a hotspot first');
                      }
                      final host = candidates.first;
                      hotspot = HotspotSharing(selected!.codec, (bundle) async {
                        await receive(await selected!.codec.encode(bundle));
                      });
                      final port = await hotspot!.start(host);
                      if (mounted) {
                        setState(
                          () => message =
                              'Receive at http://${host.address}:$port/vbundle while this screen stays open.',
                        );
                      }
                    }),
              child: const Text('Receive over local hotspot'),
            ),
        ],
      ],
    ),
  );
}

class AnimatedTransferQr extends StatefulWidget {
  final Uint8List bytes;
  const AnimatedTransferQr({super.key, required this.bytes});
  @override
  State<AnimatedTransferQr> createState() => _AnimatedQrState();
}

class _AnimatedQrState extends State<AnimatedTransferQr> {
  late final encoder = QrFountainEncoder(widget.bytes);
  int sequence = 0;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() => sequence = (sequence + 1) % (encoder.blocks + 20));
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Encrypted transfer')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrImageView(
            data: encoder.frame(sequence),
            size: 300,
            backgroundColor: Colors.white,
          ),
          Text('Frame ${sequence + 1} · keep scanning until complete'),
        ],
      ),
    ),
  );
}

class ScanTransferQr extends StatefulWidget {
  const ScanTransferQr({super.key});
  @override
  State<ScanTransferQr> createState() => _ScanState();
}

class _ScanState extends State<ScanTransferQr> {
  final decoder = QrFountainDecoder();
  bool done = false;
  String? error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan encrypted transfer')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            errorBuilder: (_, _) => const Center(
              child: Text(
                'Camera unavailable. Allow camera access or import a transfer file.',
              ),
            ),
            onDetect: (capture) {
              if (done) return;
              for (final barcode in capture.barcodes) {
                final text = barcode.rawValue;
                if (text == null) continue;
                try {
                  final bytes = decoder.add(text);
                  if (bytes != null) {
                    done = true;
                    Navigator.pop(context, bytes);
                    return;
                  }
                  setState(() => error = null);
                } catch (_) {
                  setState(
                    () => error =
                        'This QR is not part of the current transfer. Reopen scanning to start a different transfer.',
                  );
                }
              }
            },
          ),
        ),
        LinearProgressIndicator(value: decoder.progress),
        if (error != null) Text(error!),
      ],
    ),
  );
}
