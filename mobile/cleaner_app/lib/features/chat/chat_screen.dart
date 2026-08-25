import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/chat_repository.dart';

/// The booking thread.
///
/// Private to the two people on this job, and only while the job is live: the
/// backend closes it 24 hours after completion, and this screen degrades to a
/// read-only "closed" state rather than a dead input the moment it does. New
/// messages sit at the bottom (the list is reversed so it pins there without a
/// scroll controller fighting the keyboard).
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.repository,
    required this.bookingId,
    required this.title,
  });

  final ChatRepository repository;
  final String bookingId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _time = DateFormat('h:mm a');
  final _input = TextEditingController();

  List<ChatMessage> _messages = const [];
  bool _loading = true;
  bool _closed = false;
  String? _error;
  bool _sending = false;
  StreamSubscription<List<ChatMessage>>? _sub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await widget.repository.ready();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Couldn\'t open the conversation. Try again in a moment.';
      });
      return;
    }
    _sub = widget.repository.watch(widget.bookingId).listen(
      (messages) {
        if (!mounted) return;
        setState(() {
          _messages = messages;
          _loading = false;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          if (e is ThreadClosed) {
            _closed = true;
          } else {
            _error = 'Connection lost. Pull to retry.';
          }
        });
      },
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _closed) return;
    setState(() => _sending = true);
    try {
      await widget.repository.send(widget.bookingId, text);
      _input.clear();
    } catch (_) {
      _say('Message didn\'t send. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Sparkle.clay,
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.repository.currentUserId;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Sparkle.marine,
        foregroundColor: Colors.white,
        title: Text(widget.title,
            style: const TextStyle(fontFamily: 'Archivo', fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          Expanded(child: _list(me)),
          if (_closed) const _ClosedBanner() else _composer(),
        ],
      ),
    );
  }

  Widget _list(String me) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Sparkle.marine));
    if (_error != null) {
      return _Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined, size: 40, color: Sparkle.inkSoft),
          const SizedBox(height: Sparkle.s3),
          Text(_error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
        ]),
      );
    }
    if (_messages.isEmpty) {
      return _Center(
        child: Padding(
          padding: const EdgeInsets.all(Sparkle.s6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.chat_bubble_outline, size: 40, color: Sparkle.inkSoft),
            const SizedBox(height: Sparkle.s3),
            Text(
              _closed ? 'This conversation has closed.' : 'Message the customer about access, parking, or timing.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (!_closed) ...[
              const SizedBox(height: Sparkle.s2),
              const Text('Private to this booking. Closes 24 hours after the job.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Sparkle.inkSoft)),
            ],
          ]),
        ),
      );
    }

    final reversed = _messages.reversed.toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(Sparkle.s4),
      itemCount: reversed.length,
      itemBuilder: (context, i) {
        final m = reversed[i];
        return _Bubble(mine: m.senderId == me, body: m.body, time: _time.format(m.sentAt.toLocal()));
      },
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Sparkle.surface,
          border: Border(top: BorderSide(color: Sparkle.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(Sparkle.s4, Sparkle.s2, Sparkle.s2, Sparkle.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Message…',
                  counterText: '',
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Sparkle.marine))
                  : const Icon(Icons.send_rounded, color: Sparkle.marine),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.mine, required this.body, required this.time});
  final bool mine;
  final String body;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
        margin: const EdgeInsets.only(bottom: Sparkle.s2),
        padding: const EdgeInsets.symmetric(horizontal: Sparkle.s3, vertical: Sparkle.s2),
        decoration: BoxDecoration(
          color: mine ? Sparkle.marine : Sparkle.surface,
          border: mine ? null : Border.all(color: Sparkle.hairline),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(mine ? 14 : 4),
            bottomRight: Radius.circular(mine ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body, style: TextStyle(fontSize: 15, height: 1.35, color: mine ? Colors.white : Sparkle.inkStrong)),
            const SizedBox(height: 2),
            Text(time,
                style: TextStyle(fontSize: 10, color: mine ? const Color(0xFFA9C6CD) : Sparkle.inkSoft)),
          ],
        ),
      ),
    );
  }
}

class _ClosedBanner extends StatelessWidget {
  const _ClosedBanner();

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          color: Sparkle.surface,
          padding: const EdgeInsets.all(Sparkle.s4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 16, color: Sparkle.inkSoft),
              const SizedBox(width: Sparkle.s2),
              Text('This conversation has closed.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Sparkle.inkSoft)),
            ],
          ),
        ),
      );
}

class _Center extends StatelessWidget {
  const _Center({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Center(child: child);
}
