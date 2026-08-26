import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme.dart';
import '../../data/onboarding_repository.dart';

/// Onboarding hub.
///
/// Not a wizard. The four tasks are independent and the background check takes
/// 1–3 days, so a linear flow would park every applicant behind the slowest
/// step. This is a checklist: start the check first, fill in everything else
/// while it runs.
///
/// The list is the same one the reviewer sees in the admin console. An
/// applicant who can read exactly what's blocking them doesn't open a ticket,
/// and doesn't quietly give up either — cleaner supply is the hard side of
/// this marketplace, and every abandoned application is a week of lost jobs.
class OnboardingHubScreen extends StatefulWidget {
  const OnboardingHubScreen({
    super.key,
    required this.repository,
    this.onOpenStep,
  });

  final OnboardingRepository repository;
  final void Function(String stepKey)? onOpenStep;

  @override
  State<OnboardingHubScreen> createState() => _OnboardingHubScreenState();
}

class _OnboardingHubScreenState extends State<OnboardingHubScreen> {
  OnboardingState? _state;
  String? _error;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await widget.repository.load();
      if (!mounted) return;
      setState(() {
        _state = state;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await widget.repository.submit();
      await _load();
      if (!mounted) return;
      _say('Application sent. We review within 2 business days.');
    } on OnboardingIncomplete catch (e) {
      _say(e.message, tone: Sparkle.clay);
    } catch (e) {
      _say('$e', tone: Sparkle.clay);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _say(String text, {Color tone = Sparkle.marineDeep}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        backgroundColor: tone,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;

    return Scaffold(
      backgroundColor: Sparkle.mist,
      body: RefreshIndicator(
        onRefresh: _load,
        color: Sparkle.marine,
        child: state == null
            ? _loadingOrError()
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                children: [
                  _Header(state: state),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Sparkle.s4, Sparkle.s5, Sparkle.s4, Sparkle.s6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final step in state.steps) ...[
                          _TaskTile(
                            step: step,
                            locked: state.submitted && step.key != 'background_check',
                            onTap: () => widget.onOpenStep?.call(step.key),
                          ),
                          const SizedBox(height: Sparkle.s3),
                        ],
                        const SizedBox(height: Sparkle.s2),
                        if (!state.submitted) ...[
                          FilledButton(
                            onPressed: state.readyToSubmit && !_submitting ? _submit : null,
                            child: _submitting
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Text('Send my application'),
                          ),
                          const SizedBox(height: Sparkle.s3),
                          Text(
                            state.readyToSubmit
                                ? 'A real person reviews every application. We aim to come back within 2 business days.'
                                : 'You can send this once the tasks above are done. Your background check can still be running.',
                            style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft, height: 1.45),
                          ),
                        ] else
                          _SubmittedNotice(state: state),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _loadingOrError() {
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 140),
          const Icon(Icons.cloud_off_outlined, size: 40, color: Sparkle.inkSoft),
          const SizedBox(height: Sparkle.s4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sparkle.s6),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
          const SizedBox(height: Sparkle.s4),
          Center(
            child: SizedBox(
              width: 160,
              child: FilledButton(onPressed: _load, child: const Text('Try again')),
            ),
          ),
        ],
      );
    }
    return const Center(child: CircularProgressIndicator(color: Sparkle.marine));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});
  final OnboardingState state;

  @override
  Widget build(BuildContext context) {
    final done = state.completedCount;
    final total = state.steps.length;

    return Container(
      width: double.infinity,
      color: Sparkle.marine,
      padding: EdgeInsets.fromLTRB(
          Sparkle.s4, MediaQuery.of(context).padding.top + Sparkle.s5, Sparkle.s4, Sparkle.s5),
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: MediaQuery.of(context).padding.top,
            child: Opacity(
              opacity: 0.12,
              child: SvgPicture.asset('assets/images/sparkle_motif.svg', width: 120, height: 120),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Getting you approved',
                  style: TextStyle(
                      fontFamily: 'Archivo', fontSize: 24, fontWeight: FontWeight.w800,
                      color: Colors.white, letterSpacing: -0.5)),
              const SizedBox(height: Sparkle.s2),
              Text(
                state.approved
                    ? 'You\'re approved. Turn on Accepting jobs to start receiving offers.'
                    : 'Four tasks, and you can do them in any order. Start the background check first — it takes the longest.',
                style: const TextStyle(color: Color(0xFFA9C6CD), fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: Sparkle.s4),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: done / total,
                        minHeight: 6,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(Sparkle.seafoam),
                      ),
                    ),
                  ),
                  const SizedBox(width: Sparkle.s3),
                  Text('$done of $total',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.step, required this.locked, required this.onTap});

  final OnboardingStep step;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final waiting = step.key == 'background_check' && !step.complete;

    return Semantics(
      button: !locked,
      label: '${step.title}. ${step.complete ? "Done" : step.detail}',
      child: InkWell(
        onTap: locked || step.complete ? null : onTap,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        child: Container(
          padding: const EdgeInsets.all(Sparkle.s4),
          decoration: BoxDecoration(
            color: Sparkle.surface,
            borderRadius: BorderRadius.circular(Sparkle.radius),
            border: Border.all(color: step.complete ? Sparkle.seafoam : Sparkle.hairline),
            boxShadow: Sparkle.cardShadow,
          ),
          child: Row(
            children: [
              Container(
                height: 28,
                width: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: step.complete
                      ? Sparkle.seafoam
                      : waiting
                          ? const Color(0xFFFDF6E7)
                          : Sparkle.mist,
                  border: Border.all(
                      color: step.complete ? Sparkle.seafoam : Sparkle.hairline, width: 1.5),
                ),
                child: Icon(
                  step.complete
                      ? Icons.check
                      : waiting
                          ? Icons.hourglass_bottom
                          : Icons.arrow_forward,
                  size: 15,
                  color: step.complete ? Colors.white : Sparkle.inkSoft,
                ),
              ),
              const SizedBox(width: Sparkle.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(step.detail,
                        style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft, height: 1.35)),
                  ],
                ),
              ),
              if (!step.complete && !locked && !waiting)
                const Icon(Icons.chevron_right, color: Sparkle.inkSoft),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubmittedNotice extends StatelessWidget {
  const _SubmittedNotice({required this.state});
  final OnboardingState state;

  @override
  Widget build(BuildContext context) {
    final approved = state.approved;
    return Container(
      padding: const EdgeInsets.all(Sparkle.s4),
      decoration: BoxDecoration(
        color: approved ? Sparkle.seafoamSoft : Sparkle.surface,
        borderRadius: BorderRadius.circular(Sparkle.radius),
        border: Border.all(color: approved ? Sparkle.seafoam : Sparkle.hairline),
        boxShadow: Sparkle.cardShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(approved ? Icons.verified : Icons.schedule_send,
              size: 20, color: approved ? Sparkle.seafoam : Sparkle.marine),
          const SizedBox(width: Sparkle.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(approved ? 'You\'re approved' : 'With our team',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  approved
                      ? 'Head to Jobs and turn on Accepting jobs. Offers usually start within a day.'
                      : 'We review in the order applications arrive, usually within 2 business days. '
                          'We\'ll notify you either way — nothing else to do right now.',
                  style: const TextStyle(fontSize: 13, color: Sparkle.inkSoft, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
