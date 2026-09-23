import 'package:flutter/material.dart';

/// Shared school login. Passwords are never persisted by the application.
class PasswordSignIn extends StatefulWidget {
  final String label;
  final Future<void> Function(String email, String password) onSignIn;
  const PasswordSignIn({
    super.key,
    required this.label,
    required this.onSignIn,
  });
  @override
  State<PasswordSignIn> createState() => _PasswordSignInState();
}

class _PasswordSignInState extends State<PasswordSignIn> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController(), password = TextEditingController();
  bool busy = false, hidden = true;
  String? error;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSignIn(email.text.trim(), password.text);
      if (mounted) password.clear();
    } catch (_) {
      if (mounted) {
        setState(() {
          error =
              'Unable to sign in. Check your email and password and your connection. Contact your school administrator if you need a password reset.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: form,
    child: AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: email,
            enabled: !busy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            autocorrect: false,
            decoration: InputDecoration(labelText: widget.label),
            validator: (value) =>
                RegExp(
                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                ).hasMatch(value?.trim() ?? '')
                ? null
                : 'Enter a valid email address',
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: password,
            enabled: !busy,
            obscureText: hidden,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => submit(),
            validator: (value) =>
                value == null || value.isEmpty ? 'Enter your password' : null,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: hidden ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => hidden = !hidden),
                icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : submit,
            child: Text(busy ? 'Signing in…' : 'Sign in'),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
          const Text(
            'Use the account supplied by your school. No verification email is needed.',
          ),
        ],
      ),
    ),
  );
}
