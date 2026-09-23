import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:vaachak_packs/vaachak_packs.dart';
import 'model_runtime.dart';
import 'package:vaachak_packs/catalog.dart';

class PackPage extends StatefulWidget {
  const PackPage({super.key});
  @override
  State<PackPage> createState() => _PackPageState();
}

class _PackPageState extends State<PackPage> {
  ModelRuntime? runtime;
  String? message;
  bool busy = false;
  double? progress;
  final url = TextEditingController();
  final catalogUrl = TextEditingController(
    text: const String.fromEnvironment('PACK_CATALOG_URL'),
  );
  List<PackUpdate> available = [];
  http.Client? activeClient;
  List<(String, String)> installed = [];
  @override
  void initState() {
    super.initState();
    open();
  }

  @override
  void dispose() {
    url.dispose();
    catalogUrl.dispose();
    activeClient?.close();
    runtime?.packs.dispose();
    super.dispose();
  }

  Future<void> open() async {
    try {
      runtime = await ModelRuntime.open();
      if (!mounted) {
        await runtime!.packs.dispose();
        return;
      }
      await refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Model packs are unavailable on this device. Text practice remains available.',
        );
      }
    }
  }

  Future<void> refresh() async {
    final packs = await runtime!.installed();
    if (mounted) {
      setState(
        () => installed = packs.map((p) => (p.$1.id, p.$1.version)).toList(),
      );
    }
  }

  Future<void> checkCatalog() async {
    if (busy || runtime == null) return;
    setState(() {
      busy = true;
      message = null;
    });
    final client = http.Client();
    activeClient = client;
    try {
      final updates = await PackCatalog(runtime!.packs, client).check(
        Uri.parse(catalogUrl.text.trim()),
        {for (final p in installed) p.$1: p.$2},
      );
      if (mounted) {
        setState(() {
          available = updates;
          message = updates.isEmpty
              ? 'No compatible pack updates are available.'
              : 'Verified updates are ready to download.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          available = [];
          message =
              'Cannot verify the catalog. Check the connection, device clock and school release URL.';
        });
      }
    } finally {
      client.close();
      activeClient = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install(bool local, {PackUpdate? update}) async {
    if (runtime == null || busy) {
      return;
    }
    setState(() {
      busy = true;
      message = null;
      progress = 0;
    });
    final client = http.Client();
    activeClient = client;
    try {
      late PackManifest manifest;
      late PackSource source;
      if (update != null) {
        manifest = update.manifest;
        source = HttpsPackSource(update.base, client);
      } else if (local) {
        final path = await FilePicker.getDirectoryPath(
          dialogTitle: 'Choose a signed pack folder',
        );
        if (path == null) {
          return;
        }
        final file = File('$path/manifest.json');
        if (await file.length() > 1048576) {
          throw FormatException('Manifest too large');
        }
        manifest = PackManifest(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        );
        source = DirectoryPackSource(Directory(path));
      } else {
        final uri = Uri.parse(url.text.trim());
        if (uri.scheme != 'https' || !uri.path.endsWith('/manifest.json')) {
          throw FormatException('Use an HTTPS manifest.json URL');
        }
        final request = http.Request('GET', uri)..followRedirects = false;
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw HttpException('Manifest unavailable');
        }
        final data = <int>[];
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 20),
        )) {
          if (data.length + chunk.length > 1048576) {
            throw FormatException('Manifest too large');
          }
          data.addAll(chunk);
        }
        manifest = PackManifest(
          jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
        );
        source = HttpsPackSource(uri.resolve('./'), client);
      }
      final subscription = runtime!.packs.watch(manifest.id).listen((p) {
        if (mounted) {
          setState(() => progress = p.received / p.total);
        }
      });
      try {
        await runtime!.packs.install(manifest, source);
      } finally {
        await subscription.cancel();
      }
      await refresh();
      if (mounted) {
        setState(() {
          message =
              'Pack verified and installed. Reopen learning to use updated content.';
          available.removeWhere((p) => p.manifest.id == manifest.id);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'The pack could not be installed. Check its signature, device compatibility, free space and connection. Your previous pack is still available.',
        );
      }
    } finally {
      client.close();
      activeClient = null;
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> rollback(String id) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await runtime!.packs.rollback(id);
      await refresh();
      if (mounted) setState(() => message = 'Previous verified pack restored.');
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'No compatible, verified previous version is available.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline packs')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Bring learning with you.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Download once or copy a pack from your school. Every file is checked before it can be used.',
            ),
            const SizedBox(height: 24),
            if (runtime != null)
              Text(
                'Device tier: ${runtime!.packs.device.tier.name.toUpperCase()}',
              ),
            if (runtime != null && runtime!.packs.trustedKeys.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'This development build has no trusted school release key. Pack installation stays disabled until your administrator configures one.',
                ),
              ),
            TextField(
              controller: catalogUrl,
              decoration: const InputDecoration(
                labelText: 'School update catalog URL',
              ),
            ),
            OutlinedButton(
              onPressed:
                  busy || runtime == null || runtime!.packs.trustedKeys.isEmpty
                  ? null
                  : checkCatalog,
              child: const Text('Check content and model updates'),
            ),
            for (final update in available)
              ListTile(
                title: Text(
                  '${update.manifest.id} · ${update.manifest.version}',
                ),
                subtitle: Text(
                  '${(update.manifest.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                ),
                trailing: TextButton(
                  onPressed: busy ? null : () => install(false, update: update),
                  child: const Text('Download'),
                ),
              ),
            for (final pack in installed)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.verified_outlined),
                  title: Text('${pack.$1} · ${pack.$2}'),
                  trailing: IconButton(
                    tooltip: 'Restore previous verified version',
                    onPressed: busy ? null : () => rollback(pack.$1),
                    icon: const Icon(Icons.restore),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            TextField(
              controller: url,
              decoration: const InputDecoration(
                labelText: 'School pack URL',
                hintText: 'HTTPS manifest URL',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed:
                  busy || runtime == null || runtime!.packs.trustedKeys.isEmpty
                  ? null
                  : () => install(false),
              icon: const Icon(Icons.download),
              label: const Text('Download and verify'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  busy || runtime == null || runtime!.packs.trustedKeys.isEmpty
                  ? null
                  : () => install(true),
              icon: const Icon(Icons.folder_open),
              label: const Text('Import a pack folder'),
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: LinearProgressIndicator(value: progress),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(message!),
              ),
          ],
        ),
      ),
    ),
  );
}
