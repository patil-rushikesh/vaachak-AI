import 'package:flutter/material.dart';
import 'session.dart';

class PrivacyControls extends StatefulWidget {
  final LearningSession session;
  const PrivacyControls({super.key, required this.session});
  @override
  State<PrivacyControls> createState() => _PrivacyControlsState();
}

class _PrivacyControlsState extends State<PrivacyControls> {
  bool busy = false;
  String? message;
  Future<void> revoke(String purpose) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.session.store.setConsent(
        widget.session.profile.id,
        purpose,
        false,
      );
      await widget.session.reloadProgress();
      if (mounted) {
        setState(
          () => message = purpose == 'microphone'
              ? 'Microphone consent withdrawn. Text practice remains available.'
              : 'Progress sharing stopped. The school will receive the notice on the next sync.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => message = 'The change was not saved. Please retry.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (session.profile.minor)
            const Text(
              'Learners under 18 need separately witnessed guardian consent for learning, microphone use and school sharing.',
            ),
          const Text(
            'Voice is processed in memory and is not retained. Advertising and telemetry are off. '
            'Consent can be withdrawn without enabling another purpose.',
          ),
          for (final item in [
            ('microphone', 'Microphone'),
            ('serverSync', 'School progress sharing'),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.$2),
              subtitle: Text(
                session.snapshot.consents[item.$1] == true
                    ? 'Allowed'
                    : 'Not allowed',
              ),
              trailing: session.snapshot.consents[item.$1] == true
                  ? TextButton(
                      onPressed: busy ? null : () => revoke(item.$1),
                      child: const Text('Withdraw'),
                    )
                  : null,
            ),
          const Text(
            'Grant microphone consent when starting reading. Join a class to choose school sharing. '
            'Withdraw learning consent using “Erase profile and progress” below.',
          ),
          if (const String.fromEnvironment('SCHOOL_PRIVACY_CONTACT') != '')
            const Text(
              'Privacy questions: ${String.fromEnvironment('SCHOOL_PRIVACY_CONTACT')}',
            ),
          if (message != null)
            Semantics(liveRegion: true, child: Text(message!)),
          const Divider(),
        ],
      );
    },
  );
}
