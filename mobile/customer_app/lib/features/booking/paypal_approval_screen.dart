import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme.dart';

/// Whether the customer completed PayPal's approval (`true`) or backed out —
/// closed the sheet, hit cancel on PayPal's side, or the redirect never
/// arrived (`false`).
class PaypalApprovalResult {
  const PaypalApprovalResult(this.approved);
  final bool approved;
}

/// Hosts the PayPal approval redirect a customer completes before a booking
/// is confirmed — the in-app replacement for what used to be Stripe's native
/// PaymentSheet. PayPal redirects to `sparkle://booking/paypal/return`
/// (approved) or `sparkle://booking/paypal/cancel` (backed out); this screen
/// watches for those and pops with the result rather than letting the
/// webview try to load a scheme it can't handle.
class PaypalApprovalScreen extends StatefulWidget {
  const PaypalApprovalScreen({super.key, required this.approveUrl});
  final String approveUrl;

  @override
  State<PaypalApprovalScreen> createState() => _PaypalApprovalScreenState();
}

class _PaypalApprovalScreenState extends State<PaypalApprovalScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Sparkle.linen)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri != null && uri.scheme == 'sparkle') {
            Navigator.of(context).pop(PaypalApprovalResult(uri.path.contains('return')));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
        onWebResourceError: (error) => setState(() {
          _loading = false;
          _error = error.description;
        }),
      ))
      ..loadRequest(Uri.parse(widget.approveUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Sparkle.linen,
        surfaceTintColor: Colors.transparent,
        title: const Text('Approve with PayPal'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(const PaypalApprovalResult(false)),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(Sparkle.s5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Sparkle.clay, size: 32),
                    const SizedBox(height: Sparkle.s3),
                    Text('Could not load PayPal: $_error', textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
    );
  }
}
