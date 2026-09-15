import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/auth_controller.dart';
import '../../data/auth_repository.dart';
import 'forgot_password_screen.dart';
import 'signup_screen.dart';

InputDecoration _fieldDecoration(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
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

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});
  final AuthController auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  String? _banner;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _banner = null;
    });
    try {
      await widget.auth.login(_email.text.trim(), _password.text);
      // No further navigation needed — main.dart swaps `home:` to the real
      // app the moment AuthController.state flips to AuthSignedIn.
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() => _banner = e.message);
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
      backgroundColor: Sparkle.linen,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sparkle.s5),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Sparkle', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: Sparkle.s1),
                  const Text('Welcome back', textAlign: TextAlign.center,
                      style: TextStyle(color: Sparkle.inkSoft, fontSize: 15)),
                  const SizedBox(height: Sparkle.s6),
                  if (_banner != null) ...[
                    Container(
                      padding: const EdgeInsets.all(Sparkle.s3),
                      decoration: BoxDecoration(
                        color: const Color(0x1AC4553D),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_banner!, style: const TextStyle(color: Sparkle.clay, fontSize: 13)),
                    ),
                    const SizedBox(height: Sparkle.s4),
                  ],
                  TextFormField(
                    controller: _email,
                    enabled: !_submitting,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: _fieldDecoration('Email'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your email' : null,
                  ),
                  const SizedBox(height: Sparkle.s3),
                  TextFormField(
                    controller: _password,
                    enabled: !_submitting,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: _fieldDecoration('Password'),
                    validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => ForgotPasswordScreen(auth: widget.auth),
                              )),
                      child: const Text('Forgot password?'),
                    ),
                  ),
                  const SizedBox(height: Sparkle.s3),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Log in'),
                  ),
                  const SizedBox(height: Sparkle.s5),
                  Center(
                    child: TextButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => SignupScreen(auth: widget.auth),
                              )),
                      child: const Text('New here? Create an account'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
