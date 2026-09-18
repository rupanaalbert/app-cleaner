import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/auth_controller.dart';
import '../../data/auth_repository.dart';
import 'login_screen.dart';

InputDecoration _fieldDecoration(String label, {String? hint, String? errorText}) => InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: errorText,
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
    );

final _phoneRe = RegExp(r'^\+[1-9]\d{7,14}$');

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, required this.auth});
  final AuthController auth;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  bool _submitting = false;
  String? _banner;
  bool _emailTaken = false;
  final Map<String, String> _serverErrors = {};

  @override
  void dispose() {
    _fullName.dispose();
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _clearServerError(String path) {
    if (_serverErrors.remove(path) != null) setState(() {});
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _banner = null;
      _emailTaken = false;
    });
    try {
      await widget.auth.register(
        email: _email.text.trim(),
        password: _password.text,
        fullName: _fullName.text.trim(),
        phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      );
      // main.dart's `home:` already swapped the moment state flipped to
      // AuthSignedIn, but this screen is always reached via a push (from
      // LoginScreen), so it's sitting on top of that already-updated root
      // and needs popping to reveal it.
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on AuthFailure catch (e) {
      if (!mounted) return;
      if (e.fields.isNotEmpty) {
        setState(() {
          _serverErrors
            ..clear()
            ..addEntries(e.fields.map((f) => MapEntry(f.path, f.message)));
        });
        _formKey.currentState?.validate();
      } else {
        setState(() {
          _banner = e.message;
          _emailTaken = e.code == 'EMAIL_TAKEN';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _banner = 'Something went wrong. Try again in a moment.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Sparkle.mist,
      appBar: AppBar(backgroundColor: Sparkle.mist, surfaceTintColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Sparkle.s5, 0, Sparkle.s5, Sparkle.s5),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Apply to clean with Sparkle', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: Sparkle.s1),
                const Text("You'll finish background check and payout setup right after.",
                    style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
                const SizedBox(height: Sparkle.s5),
                if (_banner != null) ...[
                  Container(
                    padding: const EdgeInsets.all(Sparkle.s3),
                    decoration: BoxDecoration(
                      color: const Color(0x1AC4553D),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_banner!, style: const TextStyle(color: Sparkle.clay, fontSize: 13)),
                        if (_emailTaken)
                          Padding(
                            padding: const EdgeInsets.only(top: Sparkle.s1),
                            child: GestureDetector(
                              onTap: () => Navigator.of(context)
                                  .pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth))),
                              child: const Text('Log in instead?',
                                  style: TextStyle(color: Sparkle.clay, fontSize: 13, fontWeight: FontWeight.w700)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Sparkle.s4),
                ],
                TextFormField(
                  controller: _fullName,
                  enabled: !_submitting,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _clearServerError('full_name'),
                  decoration: _fieldDecoration('Full name', errorText: _serverErrors['full_name']),
                  validator: (v) {
                    if (_serverErrors.containsKey('full_name')) return _serverErrors['full_name'];
                    if ((v ?? '').trim().length < 2) return 'Enter your full name';
                    return null;
                  },
                ),
                const SizedBox(height: Sparkle.s3),
                TextFormField(
                  controller: _email,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _clearServerError('email'),
                  decoration: _fieldDecoration('Email', errorText: _serverErrors['email']),
                  validator: (v) {
                    if (_serverErrors.containsKey('email')) return _serverErrors['email'];
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@') || !value.contains('.')) return "That doesn't look like an email";
                    return null;
                  },
                ),
                const SizedBox(height: Sparkle.s3),
                TextFormField(
                  controller: _password,
                  enabled: !_submitting,
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _clearServerError('password'),
                  decoration: _fieldDecoration('Password', hint: 'At least 10 characters',
                      errorText: _serverErrors['password']),
                  validator: (v) {
                    if (_serverErrors.containsKey('password')) return _serverErrors['password'];
                    if ((v ?? '').length < 10) return 'Use at least 10 characters';
                    return null;
                  },
                ),
                const SizedBox(height: Sparkle.s3),
                TextFormField(
                  controller: _phone,
                  enabled: !_submitting,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => _clearServerError('phone'),
                  onFieldSubmitted: (_) => _submit(),
                  decoration: _fieldDecoration('Phone (optional)', hint: 'e.g. +15551234567',
                      errorText: _serverErrors['phone']),
                  validator: (v) {
                    if (_serverErrors.containsKey('phone')) return _serverErrors['phone'];
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return null;
                    if (!_phoneRe.hasMatch(value)) return 'Include country code, e.g. +15551234567';
                    return null;
                  },
                ),
                const SizedBox(height: Sparkle.s5),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Create account'),
                ),
                const SizedBox(height: Sparkle.s3),
                Center(
                  child: TextButton(
                    onPressed: _submitting
                        ? null
                        : () {
                            if (Navigator.of(context).canPop()) {
                              Navigator.of(context).pop();
                            } else {
                              Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)));
                            }
                          },
                    child: const Text('Already have an account? Log in'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
