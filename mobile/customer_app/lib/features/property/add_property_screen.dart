import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/property_repository.dart';

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

final _zipRe = RegExp(r'^\d{5}(-\d{4})?$');

/// The one-time "tell us where to clean" step for a customer with no saved
/// address yet — every seeded customer already has one and never sees this;
/// a freshly registered customer always does, once, before their first
/// booking. [PropertyGateScreen] is what decides whether to show this.
class AddPropertyScreen extends StatefulWidget {
  const AddPropertyScreen({super.key, required this.repository, required this.onSaved});
  final PropertyRepository repository;
  final void Function(Property property) onSaved;

  @override
  State<AddPropertyScreen> createState() => _AddPropertyScreenState();
}

class _AddPropertyScreenState extends State<AddPropertyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _city = TextEditingController();
  final _region = TextEditingController();
  final _postalCode = TextEditingController();
  final _accessNotes = TextEditingController();
  bool _submitting = false;
  String? _banner;

  @override
  void dispose() {
    _line1.dispose();
    _line2.dispose();
    _city.dispose();
    _region.dispose();
    _postalCode.dispose();
    _accessNotes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _banner = null;
    });
    try {
      final property = await widget.repository.create(
        line1: _line1.text.trim(),
        line2: _line2.text.trim().isEmpty ? null : _line2.text.trim(),
        city: _city.text.trim(),
        region: _region.text.trim(),
        postalCode: _postalCode.text.trim(),
        accessNotes: _accessNotes.text.trim().isEmpty ? null : _accessNotes.text.trim(),
      );
      if (!mounted) return;
      widget.onSaved(property);
    } on ApiFailure catch (e) {
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Sparkle.s5, Sparkle.s5, Sparkle.s5, Sparkle.s5),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Where should we clean?', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: Sparkle.s1),
                const Text("We'll only need this once — you can book from here every time after.",
                    style: TextStyle(color: Sparkle.inkSoft, fontSize: 13)),
                const SizedBox(height: Sparkle.s5),
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
                  controller: _line1,
                  enabled: !_submitting,
                  textInputAction: TextInputAction.next,
                  decoration: _fieldDecoration('Street address', hint: 'e.g. 10 Pleasant St'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your street address' : null,
                ),
                const SizedBox(height: Sparkle.s3),
                TextFormField(
                  controller: _line2,
                  enabled: !_submitting,
                  textInputAction: TextInputAction.next,
                  decoration: _fieldDecoration('Apt / unit (optional)'),
                ),
                const SizedBox(height: Sparkle.s3),
                TextFormField(
                  controller: _city,
                  enabled: !_submitting,
                  textInputAction: TextInputAction.next,
                  decoration: _fieldDecoration('City'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your city' : null,
                ),
                const SizedBox(height: Sparkle.s3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _region,
                        enabled: !_submitting,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 2,
                        textInputAction: TextInputAction.next,
                        decoration: _fieldDecoration('State', hint: 'MA').copyWith(counterText: ''),
                        validator: (v) => (v ?? '').trim().length != 2 ? '2-letter state' : null,
                      ),
                    ),
                    const SizedBox(width: Sparkle.s3),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _postalCode,
                        enabled: !_submitting,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        decoration: _fieldDecoration('ZIP code'),
                        validator: (v) =>
                            _zipRe.hasMatch((v ?? '').trim()) ? null : 'Enter a valid ZIP code',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Sparkle.s3),
                TextFormField(
                  controller: _accessNotes,
                  enabled: !_submitting,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: _fieldDecoration('Access notes (optional)',
                      hint: 'Gate code, parking, where to find a key'),
                ),
                const SizedBox(height: Sparkle.s5),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save address'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
