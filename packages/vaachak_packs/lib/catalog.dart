import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'vaachak_packs.dart';

class PackUpdate {
  final PackManifest manifest;
  final Uri base;
  PackUpdate(this.manifest, this.base);
}

/// Signed, expiring release discovery. Installation still verifies every file.
class PackCatalog {
  final PackManager manager;
  final http.Client client;
  PackCatalog(this.manager, this.client);

  Future<List<PackUpdate>> check(
    Uri uri,
    Map<String, String> installed, {
    DateTime? now,
  }) async {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw ArgumentError('An HTTPS catalog URL is required');
    }
    final response = await client
        .send(http.Request('GET', uri)..followRedirects = false)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const HttpException('Catalog unavailable');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > 1048576) {
        throw const FormatException('Catalog too large');
      }
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final signature = data.remove('signature') as String;
    final key = manager.trustedKeys[data['keyId']];
    if (key == null ||
        !await Ed25519().verify(
          utf8.encode(canonicalJson(data)),
          signature: Signature(base64Decode(signature), publicKey: key),
        )) {
      throw StateError('Catalog signature is not trusted');
    }
    final clock = (now ?? DateTime.now()).toUtc();
    final issued = DateTime.parse(data['issuedAt'] as String).toUtc();
    final expiry = DateTime.parse(data['expiresAt'] as String).toUtc();
    final sequence = data['sequence'];
    if (data['schemaVersion'] != 1 ||
        sequence is! int ||
        sequence < 1 ||
        issued.isAfter(clock.add(const Duration(minutes: 5))) ||
        !expiry.isAfter(clock) ||
        !expiry.isAfter(issued) ||
        expiry.difference(issued) > const Duration(days: 90) ||
        data['packs'] is! List ||
        (data['packs'] as List).length > 100) {
      throw const FormatException('Invalid or expired catalog');
    }
    // Scope replay protection by URL, including across trusted signing-key rotation.
    final cache = File(
      '${manager.root.path}/.catalog-${crypto.sha256.convert(utf8.encode(uri.toString()))}.json',
    );
    final digest = crypto.sha256
        .convert(utf8.encode(canonicalJson(data)))
        .toString();
    if (await cache.exists()) {
      final previous = jsonDecode(await cache.readAsString()) as Map;
      final old = previous['sequence'] as int;
      if (sequence < old || sequence == old && digest != previous['digest']) {
        throw StateError('Catalog replay or sequence reuse');
      }
    }
    final result = <PackUpdate>[];
    final seen = <String>{};
    for (final entry in data['packs'] as List) {
      final manifest = PackManifest(
        Map<String, dynamic>.from(entry['manifest'] as Map),
      );
      final base = Uri.parse(entry['baseUrl'] as String);
      HttpsPackSource(base, client); // Validate signed download URL.
      if (!seen.add(manifest.id)) {
        throw const FormatException('Duplicate catalog pack');
      }
      final current = installed[manifest.id];
      if (current != null &&
          Version.parse(manifest.version) <= Version.parse(current)) {
        continue;
      }
      // Incompatible packs are not offered on this device. Invalid signatures fail closed.
      final key = manager.trustedKeys[manifest.json['keyId']];
      if (key == null ||
          !await Ed25519().verify(
            manifest.signingBytes,
            signature: Signature(
              base64Decode(manifest.json['signature'] as String),
              publicKey: key,
            ),
          )) {
        throw StateError('Untrusted catalog pack');
      }
      try {
        await manager.verifyManifest(manifest);
        result.add(PackUpdate(manifest, base));
      } on StateError {
        // Signature was checked above; capability/app-version incompatibility.
        continue;
      }
    }
    await manager.root.create(recursive: true);
    final pending = File('${cache.path}.new');
    await pending.writeAsString(
      jsonEncode({'sequence': sequence, 'digest': digest}),
      flush: true,
    );
    await pending.rename(cache.path);
    return result;
  }
}
