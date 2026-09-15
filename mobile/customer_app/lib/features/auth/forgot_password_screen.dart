import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/auth_controller.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, required this.auth});
  final AuthController auth;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _submitting = false;
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    // The backend always responds the same way whether or not the address is
    // real (no account enumeration) — there's nothing to branch on here.
    await widget.auth.repository.forgotPassword(_email.text.trim());
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _sent = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Sparkle.linen,
      appBar: AppBar(backgroundColor: Sparkle.linen, surfaceTintColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sparkle.s5),
            child: _sent ? _confirmation(context) : _form(context),
          ),
        ),
      ),
    );
  }

  Widget _confirmation(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.mark_email_read_outlined, size: 40, color: Sparkle.seafoam),
        const SizedBox(height: Sparkle.s3),
        Text('Check your email', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Sparkle.s2),
        const Text(
          "If an account exists for that email, we've sent a link to reset your password.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Sparkle.inkSoft, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: Sparkle.s5),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to log in'),
        ),
      ],
    );
  }

  Widget _form(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Reset your password', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Sparkle.s1),
          const Text("We'll email you a link to get back in.",
              style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
          const SizedBox(height: Sparkle.s5),
          TextFormField(
            controller: _email,
            enabled: !_submitting,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Email',
              filled: true,
              fillColor: Sparkle.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Sparkle.hairline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Sparkle.hairline),
              ),
            ),
            validator: (v) {
              final value = v?.trim() ?? '';
              if (value.isEmpty) return 'Enter your email';
              if (!value.contains('@') || !value.contains('.')) return "That doesn't look like an email";
              return null;
            },
          ),
          const SizedBox(height: Sparkle.s4),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Send reset link'),
          ),
        ],
      ),
    );
  }
}
