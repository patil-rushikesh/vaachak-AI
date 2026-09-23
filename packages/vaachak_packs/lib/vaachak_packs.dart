import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

enum DeviceTier { c, b, a }

class DeviceCapabilities {
  final int ramBytes, freeBytes, androidSdk;
  final bool arm64, thermalLimited;
  const DeviceCapabilities({
    required this.ramBytes,
    required this.freeBytes,
    required this.androidSdk,
    required this.arm64,
    this.thermalLimited = false,
  });
  DeviceTier get tier {
    if (!arm64 || ramBytes < 2e9 || freeBytes < 1e9 || androidSdk < 26) {
      throw StateError('Device does not meet core requirements');
    }
    if (ramBytes >= 6e9 &&
        freeBytes >= 3e9 &&
        androidSdk >= 29 &&
        !thermalLimited) {
      return DeviceTier.a;
    }
    if (ramBytes >= 4e9 && freeBytes >= 1.5e9) {
      return DeviceTier.b;
    }
    return DeviceTier.c;
  }
}

String canonicalJson(dynamic value) {
  dynamic sort(dynamic v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) {
      return v.map(sort).toList();
    }
    return v;
  }

  return jsonEncode(sort(value));
}

dynamic _freeze(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freeze(v))),
    );
  }
  if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
  return value;
}

class PackManifest {
  final Map<String, dynamic> json;
  PackManifest(Map<String, dynamic> data)
    : json = _freeze(jsonDecode(jsonEncode(data))) as Map<String, dynamic> {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,99}$').hasMatch(id) ||
        sizeBytes <= 0 ||
        sizeBytes > 2000000000 ||
        files.isEmpty ||
        files.length > 10000) {
      throw FormatException('Invalid pack manifest');
    }
    Version.parse(version);
    minTier;
    if (json['keyId'] is! String || (json['keyId'] as String).isEmpty) {
      throw FormatException('Missing release key identifier');
    }
    VersionConstraint.parse(json['appVersionRange'] as String);
    if (!{
      'core',
      'speech',
      'pronunciation',
      'explainer',
      'content',
    }.contains(kind)) {
      throw FormatException('Unknown pack kind');
    }
    final seen = <String>{};
    var total = 0;
    for (final file in files) {
      final path = file['path'] as String;
      if (!RegExp(r'^[A-Za-z0-9_! ./-]+$').hasMatch(path) ||
          path.startsWith('/') ||
          path.split('/').any((v) => v.isEmpty || v == '.' || v == '..') ||
          !seen.add(path) ||
          path == 'manifest.json') {
        throw FormatException('Unsafe pack path');
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(file['sha256'] as String) ||
          file['sizeBytes'] is! int ||
          (file['sizeBytes'] as int) <= 0) {
        throw FormatException('Invalid file digest or size');
      }
      total += file['sizeBytes'] as int;
    }
    validateRuntime();
    if (total != sizeBytes ||
        {'core', 'speech'}.contains(kind) && sizeBytes > 350000000) {
      throw FormatException('Pack size limit exceeded or inconsistent');
    }
  }

  /// Every runtime input must belong to the signed file inventory.
  void validateRuntime() {
    final runtime = json['runtime'];
    if (runtime == null) return; // Content-only packs have no native runtime.
    if (runtime is! Map) throw FormatException('Invalid runtime descriptor');
    void file(dynamic value) {
      if (value is! String || !files.any((f) => f['path'] == value)) {
        throw FormatException('Runtime references an unsigned file');
      }
    }

    if (runtime['asr'] != null || runtime['tts'] != null) {
      if (!{'core', 'speech'}.contains(kind) ||
          runtime['asr'] is! Map ||
          runtime['tts'] is! Map) {
        throw FormatException('Speech requires a complete core runtime');
      }
      final asr = runtime['asr'] as Map, tts = runtime['tts'] as Map;
      if (!{'whisper', 'zipformer'}.contains(asr['type'])) {
        throw FormatException('Unsupported ASR type');
      }
      for (final key in ['encoder', 'decoder', 'tokens']) {
        file(asr[key]);
      }
      if (asr['type'] == 'zipformer') file(asr['joiner']);
      if (tts['type'] != null && tts['type'] != 'vits') {
        throw FormatException('Unsupported TTS type');
      }
      file(tts['model']);
      file(tts['tokens']);
      final data = tts['dataDir'];
      if (data is! String ||
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(data) ||
          !files.any((f) => (f['path'] as String).startsWith('$data/'))) {
        throw FormatException('Unsigned TTS data directory');
      }
    }
    if (runtime['explainer'] != null) {
      final explainer = runtime['explainer'];
      if (kind != 'explainer' ||
          minTier != DeviceTier.a ||
          explainer is! Map ||
          explainer['type'] != 'litertlm') {
        throw FormatException('Explainer requires a tier A LiteRT-LM runtime');
      }
      file(explainer['model']);
    }
    if (runtime.keys.any((key) => !{'asr', 'tts', 'explainer'}.contains(key))) {
      throw FormatException('Unknown runtime descriptor');
    }
  }

  String get id => json['packId'] as String;
  String get version => json['version'] as String;
  String get kind => json['kind'] as String;
  int get sizeBytes => json['sizeBytes'] as int;
  DeviceTier get minTier =>
      DeviceTier.values.byName((json['minTier'] as String).toLowerCase());
  List<Map<String, dynamic>> get files => (json['files'] as List)
      .map((v) => (v as Map).cast<String, dynamic>())
      .toList();
  List<int> get signingBytes =>
      utf8.encode(canonicalJson({...json}..remove('signature')));
}

class PackProgress {
  final String id, state;
  final int received, total;
  const PackProgress(this.id, this.state, this.received, this.total);
}

abstract interface class PackSource {
  Stream<List<int>> read(String path, int offset);
}

class DirectoryPackSource implements PackSource {
  final Directory directory;
  DirectoryPackSource(this.directory);
  @override
  Stream<List<int>> read(String path, int offset) async* {
    final root = await directory.resolveSymbolicLinks(),
        file = File(p.join(root, path));
    final resolved = await file.resolveSymbolicLinks();
    if (!p.isWithin(root, resolved)) {
      throw FileSystemException('Pack symlink escapes source');
    }
    yield* file.openRead(offset);
  }
}

class HttpsPackSource implements PackSource {
  final Uri base;
  final http.Client client;
  HttpsPackSource(this.base, this.client) {
    if (base.scheme != 'https' ||
        !base.path.endsWith('/') ||
        base.hasQuery ||
        base.userInfo.isNotEmpty) {
      throw ArgumentError('HTTPS directory URL required');
    }
  }
  @override
  Stream<List<int>> read(String path, int offset) async* {
    final request = http.Request('GET', base.resolve(path))
      ..followRedirects = false;
    if (offset > 0) {
      request.headers['Range'] = 'bytes=$offset-';
    }
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != (offset == 0 ? 200 : 206)) {
      throw HttpException('Pack fetch failed (${response.statusCode})');
    }
    int? rangeBytes;
    if (offset > 0) {
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(response.headers['content-range'] ?? '');
      if (match == null ||
          int.parse(match[1]!) != offset ||
          int.parse(match[2]!) < offset ||
          int.parse(match[2]!) >= int.parse(match[3]!)) {
        throw HttpException('Invalid resume response');
      }
      rangeBytes = int.parse(match[2]!) - offset + 1;
    }
    var received = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      received += chunk.length;
      if (rangeBytes != null && received > rangeBytes) {
        throw HttpException('Range response overflow');
      }
      yield chunk;
    }
    if (rangeBytes != null && received != rangeBytes) {
      throw HttpException('Truncated range response');
    }
  }
}

class PackManager {
  final Directory root;
  final Map<String, SimplePublicKey> trustedKeys;
  DeviceCapabilities device;
  final Future<DeviceCapabilities> Function()? refreshDevice;
  final Version appVersion;
  final _progress = StreamController<PackProgress>.broadcast();
  bool _installing = false;
  PackManager({
    required this.root,
    required this.trustedKeys,
    required this.device,
    required this.appVersion,
    this.refreshDevice,
  });
  void _emit(PackProgress progress) {
    if (!_progress.isClosed) _progress.add(progress);
  }

  Stream<PackProgress> watch(String id) =>
      _progress.stream.where((e) => e.id == id);
  Future<void> verifyManifest(PackManifest manifest) async {
    if (refreshDevice != null) device = await refreshDevice!();
    final key = trustedKeys[manifest.json['keyId']];
    if (key == null) {
      throw StateError('Untrusted release key');
    }
    final valid = await Ed25519().verify(
      manifest.signingBytes,
      signature: Signature(
        base64Decode(manifest.json['signature'] as String),
        publicKey: key,
      ),
    );
    if (!valid) {
      throw StateError('Pack signature verification failed');
    }
    if (device.tier.index < manifest.minTier.index ||
        !VersionConstraint.parse(
          manifest.json['appVersionRange'] as String,
        ).allows(appVersion)) {
      throw StateError('Pack is incompatible with this device or app');
    }
    if (manifest.kind == 'explainer' && device.tier != DeviceTier.a) {
      throw StateError('Explanation models require tier A');
    }
  }

  Future<Directory> install(PackManifest manifest, PackSource source) async {
    if (_installing) {
      throw StateError('Another pack installation is running');
    }
    _installing = true;
    try {
      await verifyManifest(manifest);
      if (device.freeBytes < manifest.sizeBytes * 2 + 500000000) {
        throw FileSystemException('Not enough free space to install safely');
      }
      await root.create(recursive: true);
      await _rejectLinks(root);
      final staging = Directory(
        p.join(root.path, '.${manifest.id}-${manifest.version}.partial'),
      );
      final target = Directory(
        p.join(root.path, manifest.id, manifest.version),
      );
      if (await target.exists()) {
        await verifyInstalled(manifest, target);
        await _activate(manifest, target);
        return target;
      }
      var installedBytes = 0;
      await for (final file in root.list(recursive: true, followLinks: false)) {
        if (file is File) {
          installedBytes += await file.length();
        }
      }
      if (installedBytes + manifest.sizeBytes > 2000000000) {
        throw FileSystemException('Installed packs would exceed 2 GB');
      }
      await staging.create(recursive: true);
      await _rejectLinks(staging);
      await _rejectLinks(target.parent);
      var received = 0;
      for (final spec in manifest.files) {
        final file = File(p.join(staging.path, spec['path'] as String)),
            expected = spec['sizeBytes'] as int;
        await file.parent.create(recursive: true);
        var offset = await file.exists() ? await file.length() : 0;
        if (offset > expected) {
          await file.delete();
          offset = 0;
        }
        final sink = file.openWrite(mode: FileMode.append);
        try {
          if (offset < expected) {
            await for (final chunk in source.read(
              spec['path'] as String,
              offset,
            )) {
              offset += chunk.length;
              if (offset > expected) {
                throw FormatException('File exceeds signed size');
              }
              sink.add(chunk);
              _emit(
                PackProgress(
                  manifest.id,
                  'downloading',
                  received + offset,
                  manifest.sizeBytes,
                ),
              );
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (offset != expected ||
            (await digest.sha256.bind(file.openRead()).first).toString() !=
                spec['sha256']) {
          await file.delete();
          throw StateError('Pack integrity verification failed');
        }
        received += offset;
      }
      await File(
        p.join(staging.path, 'manifest.json'),
      ).writeAsString(canonicalJson(manifest.json), flush: true);
      await _verifyTree(manifest, staging);
      await target.parent.create(recursive: true);
      await staging.rename(target.path);
      await _activate(manifest, target);
      _emit(
        PackProgress(manifest.id, 'installed', received, manifest.sizeBytes),
      );
      return target;
    } catch (_) {
      _emit(PackProgress(manifest.id, 'failed', 0, manifest.sizeBytes));
      rethrow;
    } finally {
      _installing = false;
    }
  }

  Future<void> verifyInstalled(
    PackManifest manifest,
    Directory directory,
  ) async {
    await verifyManifest(manifest);
    await _verifyTree(manifest, directory);
    final saved = File(p.join(directory.path, 'manifest.json'));
    if (!await saved.exists() ||
        await saved.length() > 1048576 ||
        canonicalJson(jsonDecode(await saved.readAsString())) !=
            canonicalJson(manifest.json)) {
      throw StateError(
        'Installed version has a different manifest; versions are immutable',
      );
    }
    for (final spec in manifest.files) {
      final file = File(p.join(directory.path, spec['path'] as String));
      if (!await file.exists() ||
          await file.length() != spec['sizeBytes'] ||
          (await digest.sha256.bind(file.openRead()).first).toString() !=
              spec['sha256']) {
        throw StateError('Installed pack has been modified');
      }
    }
  }

  Future<void> _rejectLinks(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Pack directory is a symbolic link');
    }
    if (!await directory.exists()) return;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) throw StateError('Pack contains a symbolic link');
    }
  }

  Future<void> _verifyTree(PackManifest manifest, Directory directory) async {
    await _rejectLinks(directory);
    final allowed = {...manifest.files.map((f) => f['path']), 'manifest.json'};
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File &&
          !allowed.contains(p.relative(entry.path, from: directory.path))) {
        throw StateError('Pack contains an unsigned file');
      }
    }
  }

  Future<void> _activate(PackManifest manifest, Directory target) async {
    final active = File(p.join(target.parent.path, 'active'));
    if (await active.exists()) {
      final old = (await active.readAsString()).trim();
      if (old != manifest.version && _safeVersion(old)) {
        final previous = File(p.join(target.parent.path, 'previous.new'));
        await previous.writeAsString(old, flush: true);
        await previous.rename(p.join(target.parent.path, 'previous'));
      }
    }
    final pointer = File(p.join(target.parent.path, 'active.new'));
    await pointer.writeAsString(manifest.version, flush: true);
    await pointer.rename(active.path);
  }

  bool _safeVersion(String version) => RegExp(
    r'^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$',
  ).hasMatch(version);

  /// Only previously installed, freshly verified bytes may be reactivated.
  Future<void> rollback(String id) async {
    if (_installing) throw StateError('Another pack operation is running');
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,99}$').hasMatch(id)) {
      throw FormatException('Invalid pack identifier');
    }
    _installing = true;
    try {
      final parent = Directory(p.join(root.path, id));
      await _rejectLinks(parent);
      final previous = File(p.join(parent.path, 'previous'));
      final version = (await previous.readAsString()).trim();
      if (!_safeVersion(version)) throw StateError('Invalid previous version');
      final target = Directory(p.join(parent.path, version));
      final file = File(p.join(target.path, 'manifest.json'));
      if (await file.length() > 1048576) throw StateError('Manifest too large');
      final manifest = PackManifest(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      if (manifest.id != id || manifest.version != version) {
        throw StateError('Pack identity mismatch');
      }
      await verifyInstalled(manifest, target);
      await _activate(manifest, target);
    } finally {
      _installing = false;
    }
  }

  Future<void> dispose() => _progress.close();
}
