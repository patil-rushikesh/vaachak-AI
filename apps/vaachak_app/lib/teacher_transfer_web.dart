import 'package:flutter/material.dart';
import 'package:vaachak_content/vaachak_content.dart';
import 'school_connection.dart';

Widget teacherTransferButton(
  BuildContext context,
  ContentBank bank,
  SchoolConnection connection,
) => const Padding(
  padding: EdgeInsets.symmetric(vertical: 8),
  child: Text(
    'Use the Android teacher portal for offline file, QR and hotspot transfers.',
  ),
);
