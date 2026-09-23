import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:vaachak_engine/vaachak_engine.dart';
import 'package:vaachak_store/vaachak_store.dart';

class ProgressBundle {
  final String deviceId;
  final List<DomainEvent> events;
  ProgressBundle(this.deviceId, List<DomainEvent> events)
    : events = List.unmodifiable(events) {
    if (deviceId.isEmpty || events.length > 500) {
      throw FormatException('Invalid bundle');
    }
  }
  Map<String, dynamic> toJson() => {
    'bundleVersion': 1,
    'producer': {'deviceId': deviceId, 'appVersion': '0.1.0'},
    'learnerSummaries': [],
    'events': events.map((e) => e.toJson()).toList(),
    'interventionsAck': [],
  };
  factory ProgressBundle.fromJson(Map<String, dynamic> j) {
    if (j['bundleVersion'] != 1 ||
        j['events'] is! List ||
        (j['events'] as List).length > 500) {
      throw FormatException('Unsupported bundle');
    }
    return ProgressBundle(
      (j['producer'] as Map)['deviceId'] as String,
      (j['events'] as List)
          .map((e) => DomainEvent.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

class BundleCodec {
  static const maxBytes = 2 * 1024 * 1024, maxPlainBytes = 4 * 1024 * 1024;
  final SecretKey pairingKey;
  final String classId;
  final _cipher = AesGcm.with256bits();
  BundleCodec(this.pairingKey, this.classId);
  Future<Uint8List> encode(ProgressBundle bundle) async {
    final plain = utf8.encode(jsonEncode(bundle.toJson()));
    if (plain.length > maxPlainBytes) {
      throw FormatException('Bundle too large');
    }
    final box = await _cipher.encrypt(
      gzip.encode(plain),
      secretKey: pairingKey,
      aad: utf8.encode('vaachak:1:$classId'),
    );
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'classId': classId,
          'nonce': base64Encode(box.nonce),
          'ciphertext': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        }),
      ),
    );
    if (bytes.length > maxBytes) {
      throw FormatException('Encrypted bundle too large');
    }
    return bytes;
  }

  Future<ProgressBundle> decode(List<int> bytes) async {
    if (bytes.length > maxBytes) {
      throw FormatException('Bundle too large');
    }
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (envelope['v'] != 1 || envelope['classId'] != classId) {
      throw FormatException('Wrong bundle version or pairing');
    }
    final box = SecretBox(
      base64Decode(envelope['ciphertext'] as String),
      nonce: base64Decode(envelope['nonce'] as String),
      mac: Mac(base64Decode(envelope['mac'] as String)),
    );
    final zipped = await _cipher.decrypt(
      box,
      secretKey: pairingKey,
      aad: utf8.encode('vaachak:1:$classId'),
    );
    final result = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in Stream.value(zipped).transform(gzip.decoder)) {
      count += chunk.length;
      if (count > maxPlainBytes) {
        throw FormatException('Decompressed bundle exceeds limit');
      }
      result.add(chunk);
    }
    return ProgressBundle.fromJson(
      jsonDecode(utf8.decode(result.takeBytes())) as Map<String, dynamic>,
    );
  }
}

abstract interface class EventTransport {
  String get id;
  Future<Set<String>> send(List<DomainEvent> events);
}

class SupabaseEventTransport implements EventTransport {
  final Uri endpoint;
  final String anonKey;
  final Future<String> Function() accessToken;
  final http.Client client;
  final String environment;
  SupabaseEventTransport(
    this.endpoint,
    this.anonKey,
    this.accessToken,
    this.client, {
    this.environment = 'dev',
  }) {
    if (!{'dev', 'qa', 'prod'}.contains(environment)) {
      throw ArgumentError('Invalid environment');
    }
    if (endpoint.scheme != 'https') {
      throw ArgumentError('HTTPS required');
    }
  }
  @override
  String get id => 'supabase:${endpoint.host}:$environment';
  @override
  Future<Set<String>> send(List<DomainEvent> events) async {
    final request =
        http.Request('POST', endpoint.resolve('/rest/v1/rpc/ingest_events'))
          ..followRedirects = false
          ..headers.addAll({
            'apikey': anonKey,
            'Authorization': 'Bearer ${await accessToken()}',
            'Content-Type': 'application/json',
            'Content-Profile': environment,
            'Accept-Profile': environment,
          })
          ..body = jsonEncode({
            'batch': events.map((e) => e.toJson()).toList(),
          });
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    final responseBytes = BytesBuilder();
    var received = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      received += chunk.length;
      if (received > 65536) throw FormatException('Oversized acknowledgement');
      responseBytes.add(chunk);
    }
    if (response.statusCode != 200) {
      throw HttpException('Sync failed (${response.statusCode})');
    }
    final body = utf8.decode(responseBytes.takeBytes());
    final ids = ((jsonDecode(body) as Map)['acceptedIds'] as List)
        .cast<String>()
        .toSet();
    if (!events.map((e) => e.id).toSet().containsAll(ids)) {
      throw FormatException('Server acknowledged unsent events');
    }
    return ids;
  }
}

class SyncAgent {
  final VaachakStore store;
  final EventTransport transport;
  final Future<bool> Function(String learner) maySync;
  bool _busy = false;
  SyncAgent(this.store, this.transport, this.maySync);
  Future<int> flush({int maxBatches = 10}) async {
    if (_busy) {
      return 0;
    }
    _busy = true;
    try {
      final retry =
          int.tryParse(await store.metadata('retry:${transport.id}') ?? '0') ??
          0;
      if (DateTime.now().millisecondsSinceEpoch < retry) {
        return 0;
      }
      var sent = 0;
      for (var i = 0; i < maxBatches; i++) {
        final eligible = <String>{};
        for (final learner in await store.pendingLearners(transport.id)) {
          if (await maySync(learner)) eligible.add(learner);
        }
        final batch = await store.pending(
          transport.id,
          allowedLearners: eligible,
        );
        if (batch.isEmpty) {
          break;
        }
        final accepted = await transport.send(batch);
        await store.acknowledge(transport.id, accepted);
        sent += accepted.length;
        if (accepted.isEmpty) {
          break;
        }
      }
      await store.setMetadata('failures:${transport.id}', '0');
      await store.setMetadata('retry:${transport.id}', '0');
      return sent;
    } catch (_) {
      final failures =
          (int.tryParse(
                await store.metadata('failures:${transport.id}') ?? '0',
              ) ??
              0) +
          1;
      final seconds =
          min(3600, 5 * pow(2, min(failures, 10)).toInt()) +
          Random.secure().nextInt(10);
      await store.setMetadata('failures:${transport.id}', '$failures');
      await store.setMetadata(
        'retry:${transport.id}',
        '${DateTime.now().millisecondsSinceEpoch + seconds * 1000}',
      );
      rethrow;
    } finally {
      _busy = false;
    }
  }
}

/// Systematic fountain frames, followed by random XOR repair frames. Every frame
/// is independently identified; imports are authenticated after reconstruction.
class QrFountainEncoder {
  final Uint8List bytes;
  final int blockSize;
  late final String hash = sha256.convert(bytes).toString();
  QrFountainEncoder(this.bytes, {this.blockSize = 900}) {
    if (bytes.isEmpty ||
        bytes.length > BundleCodec.maxBytes ||
        blockSize < 128 ||
        blockSize > 900) {
      throw ArgumentError('Invalid QR payload');
    }
  }
  int get blocks => (bytes.length / blockSize).ceil();
  String frame(int sequence) {
    if (sequence < 0) {
      throw ArgumentError('Negative frame sequence');
    }
    final indexes = <int>{};
    if (sequence < blocks) {
      indexes.add(sequence);
    } else {
      final random = Random(sequence);
      final degree = min(blocks, 2 + random.nextInt(3));
      while (indexes.length < degree) {
        indexes.add(random.nextInt(blocks));
      }
    }
    final data = Uint8List(blockSize);
    for (final index in indexes) {
      for (var k = 0; k < blockSize; k++) {
        final pos = index * blockSize + k;
        if (pos < bytes.length) {
          data[k] ^= bytes[pos];
        }
      }
    }
    return jsonEncode({
      'v': 1,
      'hash': hash,
      'length': bytes.length,
      'size': blockSize,
      'indexes': indexes.toList()..sort(),
      'data': base64Encode(data),
    });
  }
}

class _Equation {
  final Set<int> indexes;
  final Uint8List data;
  _Equation(this.indexes, this.data);
}

class QrFountainDecoder {
  String? _hash;
  int _length = 0, _size = 0;
  final _known = <int, Uint8List>{};
  final _equations = <_Equation>[];
  double get progress =>
      _length == 0 ? 0 : _known.length / (_length / _size).ceil();
  Uint8List? add(String frame) {
    if (frame.length > 2048) {
      throw FormatException('QR frame too large');
    }
    final j = jsonDecode(frame) as Map<String, dynamic>,
        hash = j['hash'] as String;
    final length = j['length'] as int, size = j['size'] as int;
    if (j['v'] != 1 ||
        length < 1 ||
        length > BundleCodec.maxBytes ||
        size < 128 ||
        size > 900 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw FormatException('Invalid QR header');
    }
    if (_hash != null &&
        (_hash != hash || _length != length || _size != size)) {
      throw FormatException('Mixed QR transfers');
    }
    _hash = hash;
    _length = length;
    _size = size;
    final indexes = (j['indexes'] as List).cast<int>().toSet(),
        data = base64Decode(j['data'] as String),
        count = (length / size).ceil();
    if (indexes.isEmpty ||
        indexes.length > 4 ||
        indexes.any((i) => i < 0 || i >= count) ||
        data.length != size) {
      throw FormatException('Invalid QR equation');
    }
    if (_equations.length > count * 4 + 32) {
      throw FormatException('Too many QR repair frames');
    }
    _equations.add(_Equation(indexes, data));
    var changed = true;
    while (changed) {
      changed = false;
      for (final equation in _equations.toList()) {
        for (final index in equation.indexes.toList()) {
          final known = _known[index];
          if (known != null) {
            for (var k = 0; k < size; k++) {
              equation.data[k] ^= known[k];
            }
            equation.indexes.remove(index);
          }
        }
        if (equation.indexes.length == 1) {
          _known[equation.indexes.single] = equation.data;
          _equations.remove(equation);
          changed = true;
        } else if (equation.indexes.isEmpty) {
          if (equation.data.any((b) => b != 0)) {
            throw FormatException('Conflicting QR data');
          }
          _equations.remove(equation);
        }
      }
    }
    if (_known.length != count) {
      return null;
    }
    final all = BytesBuilder();
    for (var i = 0; i < count; i++) {
      all.add(_known[i]!);
    }
    final result = Uint8List.sublistView(all.takeBytes(), 0, length);
    if (sha256.convert(result).toString() != hash) {
      throw FormatException('QR transfer checksum failed');
    }
    return result;
  }
}

class HotspotSharing {
  final BundleCodec codec;
  final Future<void> Function(ProgressBundle) receive;
  HttpServer? _server;
  bool _receiving = false;
  HotspotSharing(this.codec, this.receive);
  Future<int> start(InternetAddress localAddress) async {
    if (!isPrivateAddress(localAddress)) {
      throw ArgumentError('Bind to a private hotspot address');
    }
    if (_server != null) {
      throw StateError('Already sharing');
    }
    final server = await HttpServer.bind(localAddress, 0);
    _server = server;
    server.listen((request) async {
      var ownsSlot = false;
      try {
        if (_receiving ||
            request.method != 'POST' ||
            request.uri.path != '/vbundle') {
          request.response.statusCode = 404;
          return;
        }
        _receiving = true;
        ownsSlot = true;
        final data = BytesBuilder();
        var size = 0;
        await for (final chunk in request.timeout(
          const Duration(seconds: 15),
        )) {
          size += chunk.length;
          if (size > BundleCodec.maxBytes) {
            throw FormatException('Oversized bundle');
          }
          data.add(chunk);
        }
        await receive(await codec.decode(data.takeBytes()));
        request.response.statusCode = 204;
      } catch (_) {
        request.response.statusCode = 400;
      } finally {
        if (ownsSlot) {
          _receiving = false;
        }
        await request.response.close();
      }
    });
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

Future<void> exportBundleFile(File file, Uint8List bytes) async {
  if (!file.path.endsWith('.vbundle') || bytes.length > BundleCodec.maxBytes) {
    throw ArgumentError('Invalid bundle file');
  }
  final temp = File('${file.path}.partial');
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(file.path);
}

Future<ProgressBundle> importBundleFile(File file, BundleCodec codec) async {
  if (await file.length() > BundleCodec.maxBytes) {
    throw FormatException('Bundle file too large');
  }
  return codec.decode(await file.readAsBytes());
}

bool isPrivateAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return address.isLoopback ||
      b[0] == 10 ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31);
}

/// Private literal IPs only; payload is already authenticated AES-GCM data.
/// A raw socket permits local hotspot transport without weakening public HTTPS.
Future<void> sendHotspot(Uri target, Uint8List encrypted) async {
  final address = InternetAddress.tryParse(target.host);
  if (target.scheme != 'http' ||
      address == null ||
      !isPrivateAddress(address) ||
      target.userInfo.isNotEmpty ||
      target.path != '/vbundle' ||
      target.hasQuery ||
      target.hasFragment ||
      encrypted.length > BundleCodec.maxBytes) {
    throw ArgumentError('Use a private hotspot transfer address');
  }
  final socket = await Socket.connect(
    address,
    target.port,
    timeout: const Duration(seconds: 10),
  );
  try {
    socket.add(
      ascii.encode(
        'POST /vbundle HTTP/1.1\r\nHost: ${target.host}\r\nContent-Length: ${encrypted.length}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n',
      ),
    );
    socket.add(encrypted);
    await socket.flush();
    var count = 0;
    final bytes = <int>[];
    await for (final chunk in socket.timeout(const Duration(seconds: 20))) {
      count += chunk.length;
      if (count > 4096) {
        throw const FormatException('Oversized hotspot acknowledgement');
      }
      bytes.addAll(chunk);
    }
    if (!ascii.decode(bytes).startsWith('HTTP/1.1 204 ')) {
      throw StateError('Hotspot transfer was not accepted');
    }
  } finally {
    socket.destroy();
  }
}
