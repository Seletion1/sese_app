import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// One row of `trips/{tripId}/messages/{messageId}`.
///
/// Roles: `customer` (booker), `recipient` (relay-posted through the
/// customer app until recipients hold accounts), `driver` (assignee),
/// `support` (hub agent via console). Types: `text` | `image` only —
/// voice notes are rejected by rules and have no composer anywhere.
class TripChatMessage {
  final String id;
  final String senderId;
  final String senderRole;
  final String type;
  final String text;
  final String imageUrl;
  final DateTime? createdAt;

  const TripChatMessage({
    required this.id,
    required this.senderId,
    required this.senderRole,
    this.type = 'text',
    this.text = '',
    this.imageUrl = '',
    this.createdAt,
  });

  bool get isImage => type == 'image' && imageUrl.isNotEmpty;

  factory TripChatMessage.fromMap(String id, Map<String, dynamic> map) {
    DateTime? when;
    final raw = map['timestamp'] ?? map['createdAt'];
    try {
      if (raw != null) when = (raw as dynamic).toDate() as DateTime?;
    } catch (_) {
      if (raw is String) when = DateTime.tryParse(raw);
      if (raw is num) {
        when = DateTime.fromMillisecondsSinceEpoch(raw.toInt());
      }
    }
    return TripChatMessage(
      id: id,
      senderId: (map['senderId'] ?? '').toString(),
      senderRole: (map['senderRole'] ?? 'customer').toString(),
      type: (map['type'] ?? 'text').toString(),
      text: (map['text'] ?? '').toString(),
      imageUrl: (map['imageUrl'] ?? '').toString(),
      createdAt: when,
    );
  }
}

/// Tri-party trip chat transport (`trips/{tripId}/messages`).
///
/// Participant-gated by firestore.rules (trip customer, assigned driver,
/// hub staff); text/images strictly. Image uploads land in
/// `trip_media/{tripId}/` (participant-gated, images-only storage rules).
class TripChatService {
  final FirebaseFirestore? _firestore;
  final FirebaseStorage? _storage;

  TripChatService([this._firestore, this._storage]);

  FirebaseFirestore? get _db {
    try {
      return _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  FirebaseStorage? get _bucket {
    try {
      return _storage ?? FirebaseStorage.instance;
    } catch (_) {
      return null;
    }
  }

  CollectionReference<Map<String, dynamic>>? _messages(String tripId) {
    final db = _db;
    if (db == null || tripId.isEmpty) return null;
    return db.collection('trips').doc(tripId).collection('messages');
  }

  /// Live message thread, oldest first. Denied reads end as empty.
  Stream<List<TripChatMessage>> messagesStream(String tripId) {
    final col = _messages(tripId);
    if (col == null) return Stream.value(const <TripChatMessage>[]);
    return col
        .orderBy('timestamp')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => TripChatMessage.fromMap(d.id, d.data())).toList())
        .handleError((Object _) => const <TripChatMessage>[]);
  }

  /// Sends a text message as [senderRole] (`customer` | `recipient` |
  /// `driver` | `support`). Throws [TripChatException] on failure.
  Future<void> sendText({
    required String tripId,
    required String senderId,
    required String senderRole,
    required String text,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      throw const TripChatException('empty', 'Message is empty.');
    }
    final col = _messages(tripId);
    if (col == null) {
      throw const TripChatException(
          'unavailable', 'Chat is unavailable offline.');
    }
    try {
      await col.add({
        'senderId': senderId,
        'senderRole': senderRole,
        'type': 'text',
        'text': clean,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('TripChatService.sendText failed: $e');
      throw const TripChatException(
          'send-failed', 'Could not send the message. Try again.');
    }
  }

  /// Uploads a photo to `trip_media/{tripId}/` and posts it as an image
  /// message. Returns the download URL.
  Future<String> sendImage({
    required String tripId,
    required String senderId,
    required String senderRole,
    required String localPath,
  }) async {
    final col = _messages(tripId);
    final bucket = _bucket;
    if (col == null || bucket == null) {
      throw const TripChatException(
          'unavailable', 'Photo chat is unavailable offline.');
    }
    try {
      final ref = bucket.ref().child(
          'trip_media/$tripId/${DateTime.now().millisecondsSinceEpoch}.jpg');
      await ref.putFile(
          File(localPath), SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      await col.add({
        'senderId': senderId,
        'senderRole': senderRole,
        'type': 'image',
        'text': '',
        'imageUrl': url,
        'timestamp': FieldValue.serverTimestamp(),
      });
      return url;
    } catch (e) {
      debugPrint('TripChatService.sendImage failed: $e');
      throw const TripChatException(
          'send-failed', 'Could not send the photo. Try again.');
    }
  }
}

/// Sanitized trip-chat failure (safe to show verbatim).
class TripChatException implements Exception {
  final String code;
  final String userMessage;

  const TripChatException(this.code, this.userMessage);

  @override
  String toString() => 'TripChatException($code)';
}
