import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';

// ---------------------------------------------------------------------------
// Data Models
// ---------------------------------------------------------------------------

/// A single message row from `support_chats/{chatId}/messages/{msgId}`.
class SupportMessage {
  final String id;

  /// 'user' | 'ai' | 'agent'
  final String senderType;

  /// UID, 'ai_assistant', or 'agent'.
  final String senderId;

  final String text;
  final DateTime? timestamp;

  /// 'text' | 'image'. Voice is deliberately not representable — the security
  /// rules reject any audio type on every chat in the schema, so a voice-note
  /// field here could only ever produce a message that fails to send.
  final String type;

  /// Storage URL when [type] is 'image'. Null for text.
  final String? imageUrl;

  /// Which KB topic the assistant matched. Null for user/agent rows.
  /// Surfaced to agents so they can see what the bot thought was asked.
  final String? topic;

  const SupportMessage({
    required this.id,
    required this.senderType,
    required this.senderId,
    required this.text,
    this.timestamp,
    this.type = 'text',
    this.imageUrl,
    this.topic,
  });

  bool get isMine => senderType == 'user';
  bool get isAi => senderType == 'ai';
  bool get isAgent => senderType == 'agent';
  bool get isImage => type == 'image' && (imageUrl ?? '').isNotEmpty;

  /// Display label above non-user bubbles.
  String get senderLabel {
    switch (senderType) {
      case 'ai':
        return 'Sese Assistant';
      case 'agent':
        return 'Support Agent';
      default:
        return '';
    }
  }

  factory SupportMessage.fromMap(String id, Map<String, dynamic> map) {
    DateTime? when;
    final raw = map['timestamp'] ?? map['sentAt'];
    try {
      if (raw != null) when = (raw as dynamic).toDate() as DateTime?;
    } catch (_) {
      if (raw is String) when = DateTime.tryParse(raw);
    }
    // Support both old (sender/bot/admin) and new (senderType) shapes.
    final rawSenderType = (map['senderType'] ?? '').toString();
    final rawSender = (map['sender'] ?? '').toString();
    final senderType = rawSenderType.isNotEmpty
        ? rawSenderType
        : _legacySenderType(rawSender);
    final senderId =
        (map['senderId'] ?? map['senderUid'] ?? map['userId'] ?? '').toString();
    final imageUrl = (map['imageUrl'] ?? '').toString();
    return SupportMessage(
      id: id,
      senderType: senderType,
      senderId: senderId,
      text: (map['text'] ?? '').toString(),
      timestamp: when,
      // Absent `type` is legacy text; anything else is coerced to text so a
      // malformed value can never render as an unknown type.
      type: map['type'] == 'image' ? 'image' : 'text',
      imageUrl: imageUrl.isEmpty ? null : imageUrl,
      topic: (map['topic'] ?? '').toString().isEmpty
          ? null
          : map['topic'].toString(),
    );
  }

  static String _legacySenderType(String sender) {
    switch (sender) {
      case 'bot':
      case 'ai_assistant':
        return 'ai';
      case 'admin':
      case 'agent':
        return 'agent';
      default:
        return 'user';
    }
  }
}

// ---------------------------------------------------------------------------
// Chat Session Status
// ---------------------------------------------------------------------------

/// Lifecycle for a `support_chats` session document.
class SupportChatStatus {
  /// AI is handling the conversation.
  static const aiActive = 'ai_active';

  /// User requested a human; waiting for an agent to claim.
  static const pendingAgent = 'pending_agent';

  /// An agent has claimed and is live-chatting.
  static const agentConnected = 'agent_connected';

  /// Session closed; input locked on both sides.
  static const resolved = 'resolved';

  static bool isHumanInvolved(String status) =>
      status == pendingAgent || status == agentConnected;

  static bool isResolved(String status) => status == resolved;

  static bool isLocked(String status) => status == resolved;
}

// ---------------------------------------------------------------------------
// Escalation phrase — triggers the cloud function / AI to handover
// ---------------------------------------------------------------------------

/// User-visible message posted when the "Connect to Agent" button is tapped.
/// The AI / Cloud Function detects this and flips status to `pending_agent`.
const String supportEscalationPhrase =
    'Please connect me to a human support agent';

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Transport layer for `support_chats` collection.
///
/// Collection shape: `support_chats/{chatId}` with subcollection `messages`.
/// Backward-compat: still reads `support_tickets` for any in-flight sessions
/// that haven't been migrated.
class SupportChatService {
  // Named params (not initialising formals) so call sites read as
  // `SupportChatService(firestore: fake)`. A positional-with-this would
  // require exposing the private field names to every caller.
  // ignore_for_file: prefer_initializing_formals
  final FirebaseFirestore? _firestore;
  final FirebaseStorage? _storage;

  SupportChatService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _firestore = firestore,
        _storage = storage;

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  // NOTE: path construction + upload moved to SupportMediaService
  // (sese_core) so both apps share one implementation. `_storage` is
  // forwarded into it per call.

  // -------------------------------------------------------------------------
  // Open / Resume a session
  // -------------------------------------------------------------------------

  /// Reuses an active (`ai_active` / `pending_agent` / `agent_connected`)
  /// session for the caller, or creates a fresh one with `status: ai_active`.
  ///
  /// The lookup and the create are wrapped separately so a permission or index
  /// failure identifies *which* half broke. They used to share one `catch` that
  /// collapsed both into a generic "Could not open support chat", which made
  /// the real cause invisible.
  Future<String> openOrCreateSession({
    required String userId,
    required String userRole,
    required String userName,
  }) async {
    final db = _db;
    if (db == null || userId.isEmpty) {
      throw const SupportChatException(
        'unavailable',
        'Support chat is unavailable. Try again.',
      );
    }

    // 1. Reuse an existing active session, if any.
    try {
      final snap = await db
          .collection('support_chats')
          .where('userId', isEqualTo: userId)
          .limit(20)
          .get();

      for (final doc in snap.docs) {
        final status = (doc.data()['status'] ?? '').toString();
        if (status == SupportChatStatus.aiActive ||
            status == SupportChatStatus.pendingAgent ||
            status == SupportChatStatus.agentConnected) {
          return doc.id;
        }
      }
    } on FirebaseException catch (e) {
      // Most often permission-denied from the `support_chats` read rule, or
      // missing-index if a composite filter is ever added here.
      debugPrint(
        'SupportChatService: session lookup failed (${e.code}): ${e.message}',
      );
      throw SupportChatException(
        'lookup-failed',
        'Could not reach support right now (${e.code}).',
      );
    } catch (e) {
      debugPrint('SupportChatService: session lookup error: $e');
      throw const SupportChatException(
        'lookup-failed',
        'Could not reach support right now.',
      );
    }

    // 2. No active session — create one.
    try {
      final ref = await db.collection('support_chats').add({
        'userId': userId,
        'userRole': userRole,
        'userName': userName.isEmpty ? 'User' : userName,
        'status': SupportChatStatus.aiActive,
        'assignedAgentId': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'lastMessage': '',
      });
      return ref.id;
    } on FirebaseException catch (e) {
      debugPrint(
        'SupportChatService: session create failed (${e.code}): ${e.message}',
      );
      throw SupportChatException(
        'create-failed',
        'Could not start a support chat (${e.code}).',
      );
    } catch (e) {
      debugPrint('SupportChatService: session create error: $e');
      throw const SupportChatException(
        'create-failed',
        'Could not start a support chat.',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Message stream
  // -------------------------------------------------------------------------

  Stream<List<SupportMessage>> messagesStream(String chatId) {
    final db = _db;
    if (db == null || chatId.isEmpty) {
      return Stream.value(const <SupportMessage>[]);
    }
    return db
        .collection('support_chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => SupportMessage.fromMap(d.id, d.data())).toList())
        .handleError((Object _) => const <SupportMessage>[]);
  }

  // -------------------------------------------------------------------------
  // Status stream
  // -------------------------------------------------------------------------

  Stream<String> statusStream(String chatId) {
    final db = _db;
    if (db == null || chatId.isEmpty) {
      return Stream.value(SupportChatStatus.aiActive);
    }
    return db
        .collection('support_chats')
        .doc(chatId)
        .snapshots()
        .map((doc) =>
            (doc.data()?['status'] ?? SupportChatStatus.aiActive).toString())
        .handleError((Object _) => SupportChatStatus.aiActive);
  }

  // -------------------------------------------------------------------------
  // Send a user message
  // -------------------------------------------------------------------------

  Future<void> sendMessage({
    required String chatId,
    required String userId,
    required String text,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await _writeUserMessage(chatId: chatId, userId: userId, text: clean);
  }

  /// Sends a photo to the support thread.
  ///
  /// Uploads via the shared [SupportMediaService], then writes the message
  /// with the resulting URL. If the write fails after the upload the orphaned
  /// object is deleted so a rejected message doesn't leave litter in the
  /// bucket.
  ///
  /// Images only — the schema rejects audio types on every chat, so there is
  /// deliberately no audio counterpart to this method.
  Future<void> sendImage({
    required String chatId,
    required String userId,
    required XFile file,
    String caption = '',
  }) async {
    if (file.path.isEmpty) return;
    final db = _db;
    if (db == null) {
      throw const SupportChatException(
        'unavailable',
        'Attachments are unavailable right now.',
      );
    }

    final media = SupportMediaService(_storage);
    final path = SupportMediaService.pathFor(userId, 'support.jpg');

    String url;
    try {
      url = await media.upload(file: file, storagePath: path);
    } on SupportMediaException catch (e) {
      throw SupportChatException('upload-failed', e.message);
    }

    try {
      await _writeUserMessage(
        chatId: chatId,
        userId: userId,
        text: caption.trim(),
        type: 'image',
        imageUrl: url,
      );
    } catch (_) {
      // Best-effort cleanup; never mask the original failure.
      await media.deleteQuietly(path);
      rethrow;
    }
  }

  /// Shared write for text and image rows.
  ///
  /// `type` is always explicitly written as 'text' or 'image' because the
  /// rules branch on `'type' in request.resource.data`.
  Future<void> _writeUserMessage({
    required String chatId,
    required String userId,
    required String text,
    String type = 'text',
    String? imageUrl,
  }) async {
    final db = _db;
    if (db == null || chatId.isEmpty || userId.isEmpty) {
      throw const SupportChatException(
        'unavailable',
        'Support chat is unavailable. Try again.',
      );
    }
    try {
      final batch = db.batch();
      final msgRef = db
          .collection('support_chats')
          .doc(chatId)
          .collection('messages')
          .doc();
      batch.set(msgRef, {
        'senderId': userId,
        'senderType': 'user',
        'type': type,
        'text': text,
        'imageUrl': ?imageUrl,
        'timestamp': FieldValue.serverTimestamp(),
      });
      // Update lastMessage / updatedAt on the parent doc.
      batch.update(
        db.collection('support_chats').doc(chatId),
        {
          'lastMessage':
              text.isNotEmpty ? text : (type == 'image' ? '📷 Photo' : ''),
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );
      await batch.commit();
    } on FirebaseException catch (e) {
      debugPrint(
        'SupportChatService: message write failed (${e.code}): ${e.message}',
      );
      throw SupportChatException(
        'send-failed',
        'Message not sent (${e.code}).',
      );
    } catch (e) {
      debugPrint('SupportChatService.sendMessage error: $e');
      if (e is SupportChatException) rethrow;
      throw const SupportChatException(
        'send-failed',
        'Message not sent. Check your connection.',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Post-resolution CSAT rating
  // -------------------------------------------------------------------------

  /// Live CSAT state for a chat. Emits `null` until a rating is submitted, so
  /// the prompt can be shown once and then stay dismissed across rebuilds.
  Stream<int?> ratingStream(String chatId) {
    final db = _db;
    if (db == null || chatId.isEmpty) return Stream<int?>.value(null);
    return db
        .collection('support_chats')
        .doc(chatId)
        .snapshots()
        .map((doc) {
      final raw = doc.data()?['csatRating'];
      return raw is num ? raw.toInt() : null;
    }).handleError((Object _) => null);
  }

  /// Records a 1-5 star rating for a resolved chat.
  ///
  /// Writes ONLY the rating fields. Status, assigned agent and escalation
  /// state are left untouched — a user must not be able to un-resolve a chat
  /// or reassign it by rating it. The Firestore rules enforce the same
  /// constraint independently of this code.
  Future<void> submitRating({
    required String chatId,
    required int rating,
    String comment = '',
  }) async {
    final db = _db;
    if (db == null || chatId.isEmpty) {
      throw const SupportChatException(
        'unavailable',
        'Could not save your rating.',
      );
    }
    if (rating < 1 || rating > 5) {
      throw const SupportChatException('invalid', 'Invalid rating.');
    }
    final trimmed = comment.trim();
    try {
      await db.collection('support_chats').doc(chatId).set({
        'csatRating': rating,
        'csatComment': trimmed.isEmpty ? null : trimmed,
        'csatSubmittedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      debugPrint('SupportChatService.submitRating (${e.code}): ${e.message}');
      throw SupportChatException(
        'rating-failed',
        'Could not save your rating (${e.code}).',
      );
    } catch (e) {
      debugPrint('SupportChatService.submitRating: $e');
      if (e is SupportChatException) rethrow;
      throw const SupportChatException(
        'rating-failed',
        'Could not save your rating.',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Request a human agent (client-side escalation trigger)
  // -------------------------------------------------------------------------

  /// Posts the escalation phrase and atomically sets status → `pending_agent`.
  /// The AI / Cloud Function may also do this on the server side; either path
  /// is safe because the status transition is idempotent.
  Future<void> requestHumanAgent({
    required String chatId,
    required String userId,
  }) async {
    final db = _db;
    if (db == null || chatId.isEmpty) {
      throw const SupportChatException(
          'unavailable', 'Support chat is unavailable.');
    }
    try {
      final batch = db.batch();
      final msgRef = db
          .collection('support_chats')
          .doc(chatId)
          .collection('messages')
          .doc();
      batch.set(msgRef, {
        'senderId': 'ai_assistant',
        'senderType': 'ai',
        'text':
            'Hold on, let me connect you to an available support agent…',
        'timestamp': FieldValue.serverTimestamp(),
      });
      batch.update(
        db.collection('support_chats').doc(chatId),
        {
          'status': SupportChatStatus.pendingAgent,
          'updatedAt': FieldValue.serverTimestamp(),
          'lastMessage':
              'Hold on, let me connect you to an available support agent…',
        },
      );
      await batch.commit();
    } catch (e) {
      debugPrint('SupportChatService.requestHumanAgent error: $e');
      if (e is SupportChatException) rethrow;
      throw const SupportChatException(
        'escalate-failed',
        'Could not request a human agent. Try again.',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

/// Thrown for support-chat failures. Carries a SnackBar-safe [userMessage].
class SupportChatException implements Exception {
  final String code;
  final String userMessage;

  const SupportChatException(this.code, this.userMessage);

  @override
  String toString() => 'SupportChatException($code): $userMessage';
}
