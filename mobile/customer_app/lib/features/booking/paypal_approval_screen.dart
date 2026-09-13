import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/theme.dart';
import '../../l10n/sparkle_strings.dart';

/// Whether the customer completed PayPal's approval (`true`) or backed out —
/// closed the browser tab, hit cancel on PayPal's side, or the redirect
/// never arrived (`false`).
class PaypalApprovalResult {
  const PaypalApprovalResult(this.approved);
  final bool approved;
}

/// Hosts the PayPal approval redirect a customer completes before a booking
/// is confirmed — the in-app replacement for what used to be Stripe's native
/// PaymentSheet. Opens PayPal in the system browser (Chrome Custom Tabs on
/// Android, `ASWebAuthenticationSession` on iOS) rather than an embedded
/// WebView: an in-app WebView's Chromium renderer runs in the host app's
/// process, so a renderer crash on lower-spec/unaccelerated devices took the
/// whole app down with it; the system browser is a separate process, so it
/// can't. PayPal redirects to `sparkle://booking/paypal/return` (approved)
/// or `sparkle://booking/paypal/cancel` (backed out); this screen launches
/// the browser and pops with the result once the OS hands the redirect back.
class PaypalApprovalScreen extends StatefulWidget {
  const PaypalApprovalScreen({super.key, required this.approveUrl});
  final String approveUrl;

  @override
  State<PaypalApprovalScreen> createState() => _PaypalApprovalScreenState();
}

class _PaypalApprovalScreenState extends State<PaypalApprovalScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _launch();
  }

  Future<void> _launch() async {
    try {
      final callback = await FlutterWebAuth2.authenticate(
        url: widget.approveUrl,
        callbackUrlScheme: 'sparkle',
      );
      if (!mounted) return;
      final approved = Uri.parse(callback).path.contains('return');
      Navigator.of(context).pop(PaypalApprovalResult(approved));
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'CANCELED') {
        // User closed the browser tab/session without completing approval —
        // the package surfaces this as an error, not a callback URL.
        Navigator.of(context).pop(const PaypalApprovalResult(false));
        return;
      }
      setState(() => _error = e.message ?? e.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = SparkleStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.approveWithPaypal),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(const PaypalApprovalResult(false)),
        ),
      ),
      backgroundColor: Sparkle.linen,
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(Sparkle.s5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Sparkle.clay, size: 32),
                    const SizedBox(height: Sparkle.s3),
                    Text(s.couldNotLoadPaypal(_error!), textAlign: TextAlign.center),
                  ],
                ),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
