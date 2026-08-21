import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

/// One message in a booking thread. Mirrors the Firebase rule schema:
/// `threads/{bookingId}/messages/{pushId}` → { sender_id, body, sent_at }.
class ChatMessage {
  final String id;
  final String senderId;
  final String body;
  final DateTime sentAt;
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.body,
    required this.sentAt,
  });
}

/// The thread is gone. The backend removes `booking_access` and the thread 24h
/// after completion (`RealtimeService.revokeAccess`), and the rules then deny
/// reads — the UI reads that as "this conversation has closed", not an error.
class ThreadClosed implements Exception {
  const ThreadClosed();
}

abstract class ChatRepository {
  /// This user's id — used to place bubbles and to stamp `sender_id`.
  String get currentUserId;

  /// Sign in to Firebase if needed. The RTDB rules require `auth.uid`, so the
  /// screen must not read or write before this resolves.
  Future<void> ready();

  Stream<List<ChatMessage>> watch(String bookingId);
  Future<void> send(String bookingId, String body);
}

class FirebaseChatRepository implements ChatRepository {
  FirebaseChatRepository({
    required this.firebaseTokenProvider,
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _db = database ?? FirebaseDatabase.instance;

  /// Exchanges the API session for a Firebase custom token (POST /realtime/token).
  final Future<String> Function() firebaseTokenProvider;
  final FirebaseAuth _auth;
  final FirebaseDatabase _db;

  @override
  String get currentUserId => _auth.currentUser?.uid ?? '';

  @override
  Future<void> ready() async {
    if (_auth.currentUser != null) return;
    await _auth.signInWithCustomToken(await firebaseTokenProvider());
  }

  @override
  Stream<List<ChatMessage>> watch(String bookingId) {
    // Push ids are chronological, but sort on sent_at anyway so a clock skew
    // can't shuffle the thread.
    return _db.ref('threads/$bookingId/messages').onValue.map((event) {
      final value = event.snapshot.value;
      if (value is! Map) return <ChatMessage>[];
      final messages = <ChatMessage>[];
      value.forEach((key, raw) {
        if (raw is Map) {
          messages.add(ChatMessage(
            id: key.toString(),
            senderId: (raw['sender_id'] as String?) ?? '',
            body: (raw['body'] as String?) ?? '',
            sentAt: DateTime.fromMillisecondsSinceEpoch(((raw['sent_at'] as num?) ?? 0).toInt()),
          ));
        }
      });
      messages.sort((a, b) => a.sentAt.compareTo(b.sentAt));
      return messages;
    }).handleError((Object error) {
      if (error is FirebaseException && error.code == 'permission-denied') {
        throw const ThreadClosed();
      }
      throw error;
    });
  }

  @override
  Future<void> send(String bookingId, String body) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Chat is not ready — sign-in incomplete.');
    // Create-only per the rules; push() makes a fresh id every time.
    await _db.ref('threads/$bookingId/messages').push().set({
      'sender_id': uid,
      'body': body,
      'sent_at': ServerValue.timestamp,
    });
  }
}
