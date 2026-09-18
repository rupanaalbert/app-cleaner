import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/property_repository.dart';
import 'add_property_screen.dart';

/// Sits in front of the booking flow: loads the signed-in customer's
/// properties once, then either drops straight into [builder] with their
/// existing (or seeded) property, or — for a brand-new customer with none —
/// shows [AddPropertyScreen] first and uses whatever they save.
class PropertyGateScreen extends StatefulWidget {
  const PropertyGateScreen({super.key, required this.properties, required this.builder});
  final PropertyRepository properties;
  final Widget Function(Property property) builder;

  @override
  State<PropertyGateScreen> createState() => _PropertyGateScreenState();
}

class _PropertyGateScreenState extends State<PropertyGateScreen> {
  bool _loading = true;
  String? _error;
  Property? _property;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.properties.list();
      if (!mounted) return;
      setState(() {
        _property = list.isEmpty ? null : list.first;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your account. Pull down to retry.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Sparkle.marine,
        body: Center(child: CircularProgressIndicator(color: Sparkle.seafoam)),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Sparkle.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 40, color: Sparkle.inkSoft),
                const SizedBox(height: Sparkle.s4),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: Sparkle.s4),
                FilledButton(onPressed: _load, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      );
    }
    final property = _property;
    if (property == null) {
      return AddPropertyScreen(
        repository: widget.properties,
        onSaved: (p) => setState(() => _property = p),
      );
    }
    return widget.builder(property);
  }
}
