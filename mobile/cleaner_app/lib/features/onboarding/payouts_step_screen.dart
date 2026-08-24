import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/onboarding_repository.dart';

/// PayPal payout email.
///
/// No hosted redirect to send a cleaner through — PayPal's Payouts API can
/// send to any email with no per-recipient review, which is the entire
/// reason this replaced Stripe Connect Express (see CLAUDE.md invariant #7).
/// Save the email, the backend fires a $0.01 verification payout, and this
/// step completes once that resolves — usually a few minutes, checked here
/// with pull-to-refresh rather than a redirect-and-return flow.
class PayoutsStepScreen extends StatefulWidget {
  const PayoutsStepScreen({super.key, required this.repository, required this.initial});

  final OnboardingRepository repository;
  final OnboardingState initial;

  @override
  State<PayoutsStepScreen> createState() => _PayoutsStepScreenState();
}

class _PayoutsStepScreenState extends State<PayoutsStepScreen> {
  late OnboardingState _state = widget.initial;
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  OnboardingStep get _step => _state.steps.firstWhere((s) => s.key == 'payouts');

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final next = await widget.repository.savePayoutsEmail(_emailController.text.trim());
      if (!mounted) return;
      setState(() => _state = next);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('$e'),
          backgroundColor: Sparkle.clay,
          behavior: SnackBarBehavior.floating,
        ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _refresh() async {
    try {
      final next = await widget.repository.load();
      if (!mounted) return;
      setState(() => _state = next);
    } catch (_) {
      // A failed refresh just leaves the last known state on screen — the
      // form below doesn't depend on it having succeeded.
    }
  }

  @override
  Widget build(BuildContext context) {
    final verified = _step.complete;
    final pending = !verified && _step.detail.toLowerCase().contains('verifying');

    return Scaffold(
      backgroundColor: Sparkle.mist,
      appBar: AppBar(
        backgroundColor: Sparkle.mist,
        surfaceTintColor: Colors.transparent,
        title: const Text('How you get paid', style: TextStyle(fontFamily: 'Archivo', fontSize: 18)),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: Sparkle.marine,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s2, Sparkle.s4, Sparkle.s6),
          children: [
            Container(
              padding: const EdgeInsets.all(Sparkle.s4),
              decoration: BoxDecoration(
                color: Sparkle.surface,
                borderRadius: BorderRadius.circular(Sparkle.radius),
                border: Border.all(color: verified ? Sparkle.seafoam : Sparkle.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        verified ? Icons.verified : (pending ? Icons.hourglass_bottom : Icons.paid_outlined),
                        size: 20,
                        color: verified ? Sparkle.seafoam : Sparkle.payout,
                      ),
                      const SizedBox(width: Sparkle.s2),
                      Expanded(
                        child: Text(_step.detail, style: Theme.of(context).textTheme.titleMedium),
                      ),
                    ],
                  ),
                  if (!verified) ...[
                    const SizedBox(height: Sparkle.s4),
                    Text(
                      'Payouts go to this PayPal email — no bank details, no document upload. '
                      'We send a one-cent deposit to confirm it before turning payouts on.',
                      style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft, height: 1.4),
                    ),
                    const SizedBox(height: Sparkle.s4),
                    Form(
                      key: _formKey,
                      child: TextFormField(
                        controller: _emailController,
                        enabled: !_saving && !pending,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'PayPal email',
                          hintText: 'you@example.com',
                        ),
                        validator: (value) {
                          final v = value?.trim() ?? '';
                          if (v.isEmpty) return 'Enter the email your PayPal is under';
                          if (!v.contains('@') || !v.contains('.')) return 'That doesn\'t look like an email';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(height: Sparkle.s4),
                    OutlinedButton(
                      onPressed: _saving || pending ? null : _save,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        side: const BorderSide(color: Sparkle.marine),
                        foregroundColor: Sparkle.marine,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 18, width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Sparkle.marine))
                          : Text(pending ? 'Verification sent' : 'Save and verify'),
                    ),
                    if (pending) ...[
                      const SizedBox(height: Sparkle.s3),
                      Text(
                        'Pull down to refresh once you\'ve gotten the deposit — usually just a few minutes.',
                        style: const TextStyle(fontSize: 12, color: Sparkle.inkSoft, height: 1.4),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
