import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/onboarding_repository.dart';

/// Document upload.
///
/// Every required slot is rendered whether or not it's been filled — a list
/// that only shows what you've already done can't tell you what's left. A
/// rejected document shows the reviewer's note verbatim, because "document
/// rejected" with no reason produces a support ticket and a re-upload of the
/// exact same file.
class DocumentsStepScreen extends StatefulWidget {
  const DocumentsStepScreen({
    super.key,
    required this.repository,
    required this.initial,
    required this.pickImage,
  });

  final OnboardingRepository repository;
  final OnboardingState initial;

  /// Injected so this screen doesn't depend on a camera plugin — pass
  /// `() => ImagePicker().pickImage(source: ...).then((f) => f?.readAsBytes())`.
  final Future<List<int>?> Function(bool fromCamera) pickImage;

  @override
  State<DocumentsStepScreen> createState() => _DocumentsStepScreenState();
}

class _DocumentsStepScreenState extends State<DocumentsStepScreen> {
  late OnboardingState _state = widget.initial;
  String? _uploading;

  Future<void> _upload(DocumentSlot slot) async {
    final source = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Sparkle.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Sparkle.radius)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final bytes = await widget.pickImage(source);
    if (bytes == null) return;

    setState(() => _uploading = slot.docType);
    try {
      final next = await widget.repository.uploadDocument(slot.docType, bytes);
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
      if (mounted) setState(() => _uploading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Sparkle.mist,
      appBar: AppBar(
        backgroundColor: Sparkle.mist,
        surfaceTintColor: Colors.transparent,
        title: const Text('Documents', style: TextStyle(fontFamily: 'Archivo', fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s2, Sparkle.s4, Sparkle.s6),
        children: [
          const Text(
            'Photograph each document flat, in good light, with all four corners in frame. '
            'Blurry edges are the single most common reason a document comes back.',
            style: TextStyle(fontSize: 14, color: Sparkle.ink, height: 1.45),
          ),
          const SizedBox(height: Sparkle.s5),
          for (final slot in _state.documents) ...[
            _DocumentCard(
              slot: slot,
              busy: _uploading == slot.docType,
              onUpload: () => _upload(slot),
            ),
            const SizedBox(height: Sparkle.s3),
          ],
          const SizedBox(height: Sparkle.s2),
          const _PrivacyNote(),
        ],
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.slot, required this.busy, required this.onUpload});

  final DocumentSlot slot;
  final bool busy;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final rejected = slot.rejectedNote != null;
    final borderColor = rejected
        ? Sparkle.clay
        : slot.verified
            ? Sparkle.seafoam
            : Sparkle.hairline;

    return Container(
      padding: const EdgeInsets.all(Sparkle.s4),
      decoration: BoxDecoration(
        color: Sparkle.surface,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(slot.title, style: Theme.of(context).textTheme.titleMedium)),
              _StatusPill(slot: slot),
            ],
          ),
          const SizedBox(height: Sparkle.s2),
          Text(slot.why,
              style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft, height: 1.4)),
          if (rejected) ...[
            const SizedBox(height: Sparkle.s3),
            Container(
              padding: const EdgeInsets.all(Sparkle.s3),
              decoration: BoxDecoration(
                color: const Color(0xFFFDF1ED),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 16, color: Sparkle.clay),
                  const SizedBox(width: Sparkle.s2),
                  Expanded(
                    child: Text(slot.rejectedNote!,
                        style: const TextStyle(fontSize: 13, color: Sparkle.clay, height: 1.4)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: Sparkle.s3),
          OutlinedButton(
            onPressed: busy || slot.verified ? null : onUpload,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: BorderSide(color: slot.verified ? Sparkle.hairline : Sparkle.marine),
              foregroundColor: Sparkle.marine,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Sparkle.marine))
                : Text(slot.verified
                    ? 'Verified'
                    : slot.uploaded
                        ? 'Replace'
                        : 'Add ${slot.title.toLowerCase()}'),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.slot});
  final DocumentSlot slot;

  @override
  Widget build(BuildContext context) {
    final (label, color) = slot.rejectedNote != null
        ? ('Needs replacing', Sparkle.clay)
        : slot.verified
            ? ('Verified', Sparkle.seafoam)
            : slot.uploaded
                ? ('In review', Sparkle.inkSoft)
                : ('Not added', Sparkle.inkSoft);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sparkle.s2, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.7, color: color)),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 16, color: Sparkle.inkSoft),
        SizedBox(width: Sparkle.s2),
        Expanded(
          child: Text(
            'Documents upload straight to encrypted storage and are only visible to the team member '
            'reviewing your application. Customers never see them.',
            style: TextStyle(fontSize: 12, color: Sparkle.inkSoft, height: 1.45),
          ),
        ),
      ],
    );
  }
}
