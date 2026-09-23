import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'package:vaachak_sync/school_sync.dart';
import 'offline_providers.dart';
import 'school_connection.dart';
import 'school_transfer_page.dart';

Widget teacherTransferButton(
  BuildContext context,
  ContentBank bank,
  SchoolConnection connection,
) => Consumer(
  builder: (context, ref, _) => OutlinedButton.icon(
    icon: const Icon(Icons.swap_horiz),
    label: const Text('Offline transfers'),
    onPressed: () async {
      final store = await ref.read(offlineStoreProvider.future);
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SchoolTransferPage(
            sync: SchoolSync(store, bank.graph, connection.api),
            teacherId: connection.userId,
          ),
        ),
      );
    },
  ),
);
