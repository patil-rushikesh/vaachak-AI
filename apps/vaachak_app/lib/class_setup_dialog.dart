import 'package:flutter/material.dart';

const classStandards = [
  'KG',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '10',
  '11',
  '12',
  'adult',
];

/// ISO 639-1 codes for the instruction language of a class.
const classLanguages = {
  'en': 'English',
  'hi': 'Hindi',
  'mr': 'Marathi',
  'gu': 'Gujarati',
  'bn': 'Bengali',
  'ta': 'Tamil',
  'te': 'Telugu',
  'kn': 'Kannada',
  'ml': 'Malayalam',
  'pa': 'Punjabi',
  'or': 'Odia',
  'ur': 'Urdu',
};

String currentAcademicYear([DateTime? now]) {
  final date = now ?? DateTime.now();
  final start = date.month >= 6 ? date.year : date.year - 1;
  return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
}

String classLabel(Map<String, dynamic> c) {
  final standard = c['standard'] as String?;
  final section = c['section'] as String?;
  final detail = standard == null
      ? ''
      : ' · ${standard == 'adult' ? 'Adult' : 'Std $standard'}${section ?? ''}';
  return '${c['name']}$detail';
}

/// Collects classroom classification. Returns RPC arguments for `create_class`,
/// or null when cancelled. Validation mirrors the database constraints.
Future<Map<String, dynamic>?> showClassSetupDialog(BuildContext context) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => const _ClassSetupDialog(),
  );
}

class _ClassSetupDialog extends StatefulWidget {
  const _ClassSetupDialog();
  @override
  State<_ClassSetupDialog> createState() => _ClassSetupState();
}

class _ClassSetupState extends State<_ClassSetupDialog> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      section = TextEditingController(),
      pincode = TextEditingController(),
      state = TextEditingController(),
      district = TextEditingController();
  String standard = '1', language = 'en';

  @override
  void dispose() {
    name.dispose();
    section.dispose();
    pincode.dispose();
    state.dispose();
    district.dispose();
    super.dispose();
  }

  String? _required(String? v, int min, int max, String message) {
    final length = (v ?? '').trim().length;
    return length < min || length > max ? message : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create classroom'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Class name'),
                  validator: (v) => _required(v, 1, 80, 'Enter a class name'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: standard,
                  decoration: const InputDecoration(
                    labelText: 'Standard (grade)',
                  ),
                  items: [
                    for (final s in classStandards)
                      DropdownMenuItem(
                        value: s,
                        child: Text(s == 'adult' ? 'Adult learners' : s),
                      ),
                  ],
                  onChanged: (v) => setState(() => standard = v ?? standard),
                ),
                TextFormField(
                  controller: section,
                  decoration: const InputDecoration(
                    labelText: 'Section (optional)',
                  ),
                  validator: (v) => (v ?? '').trim().length > 8
                      ? 'At most 8 characters'
                      : null,
                ),
                TextFormField(
                  controller: pincode,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Pincode'),
                  validator: (v) => RegExp(r'^[1-9][0-9]{5}$').hasMatch(v ?? '')
                      ? null
                      : 'Enter a 6-digit pincode',
                ),
                TextFormField(
                  controller: state,
                  decoration: const InputDecoration(labelText: 'State'),
                  validator: (v) => _required(v, 2, 60, 'Enter the state'),
                ),
                TextFormField(
                  controller: district,
                  decoration: const InputDecoration(labelText: 'District'),
                  validator: (v) => _required(v, 2, 60, 'Enter the district'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: language,
                  decoration: const InputDecoration(
                    labelText: 'Language of instruction',
                  ),
                  items: [
                    for (final e in classLanguages.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => language = v ?? language),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            Navigator.pop(context, {
              'class_name': name.text.trim(),
              'class_standard': standard,
              'class_section': section.text.trim(),
              'class_pincode': pincode.text.trim(),
              'class_state': state.text.trim(),
              'class_district': district.text.trim(),
              'class_language': language,
              'class_year': currentAcademicYear(),
            });
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
