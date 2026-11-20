import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One row of `trips/{tripId}/messages/{messageId}`.
///
/// Roles: `customer` (booker), `recipient` (relay-posted through the
/// customer app until recipients hold accounts), `driver` (assignee),
/// `support` (hub agent via console). Types: `text` | `image` only —
/// voice notes are rejected by rules and have no composer anywhere.
///
/// Channels: `'pickup'` (conversation with the booker / pickup contact) vs.
/// `'dropoff'` (conversation with the delivery / drop-off receiver).
class TripChatMessage {
  final String id;
  final String senderId;
  final String senderRole;
  final String type;
  final String text;
  final String imageUrl;
  final DateTime? createdAt;
  final String channel;

  const TripChatMessage({
    required this.id,
    required this.senderId,
    required this.senderRole,
    this.type = 'text',
    this.text = '',
    this.imageUrl = '',
    this.createdAt,
    this.channel = 'pickup',
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
      channel: (map['channel'] ?? 'pickup').toString(),
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

  /// In-memory timestamp cache of last read time per (tripId + channel + uid).
  static final Map<String, int> _lastReadMemoryCache = {};

  /// Global broadcast stream triggered whenever any channel is marked as read.
  static final StreamController<void> _readUpdatesController =
      StreamController<void>.broadcast();

  static String _readKey(String tripId, String channel, String uid) =>
      'trip_chat_last_read_${tripId}_${channel}_$uid';

  /// Returns milliseconds epoch of last read time for the given channel.
  Future<int> getLastReadTimestamp({
    required String tripId,
    required String channel,
    required String currentUid,
  }) async {
    final key = _readKey(tripId, channel, currentUid);
    if (_lastReadMemoryCache.containsKey(key)) {
      return _lastReadMemoryCache[key]!;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final val = prefs.getInt(key) ?? 0;
      _lastReadMemoryCache[key] = val;
      return val;
    } catch (_) {
      return _lastReadMemoryCache[key] ?? 0;
    }
  }

  /// Marks a specific chat channel as read up to the current timestamp.
  Future<void> markChannelRead({
    required String tripId,
    required String channel,
    required String currentUid,
  }) async {
    if (tripId.isEmpty || currentUid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = _readKey(tripId, channel, currentUid);
    _lastReadMemoryCache[key] = now;
    _readUpdatesController.add(null);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, now);
    } catch (_) {}
  }

  /// Live message thread, oldest first.
  ///
  /// When [channel] is provided, filters messages strictly for that channel:
  /// - `'dropoff'`: messages where `m.channel == 'dropoff'`
  /// - `'pickup'`: messages where `m.channel == 'pickup'` or `m.channel.isEmpty`
  /// - `null`: all messages in the trip
  Stream<List<TripChatMessage>> messagesStream(String tripId, {String? channel}) {
    final col = _messages(tripId);
    if (col == null) return Stream.value(const <TripChatMessage>[]);
    return col
        .orderBy('timestamp')
        .snapshots()
        .map((snap) {
          final all = snap.docs
              .map((d) => TripChatMessage.fromMap(d.id, d.data()))
              .toList();
          if (channel == null) return all;
          if (channel == 'dropoff') {
            return all.where((m) => m.channel == 'dropoff').toList();
          }
          return all.where((m) => m.channel == 'pickup' || m.channel.isEmpty).toList();
        })
        .handleError((Object _) => const <TripChatMessage>[]);
  }

  /// Reactive unread message count stream for [currentUid].
  ///
  /// If [channel] is specified (`'pickup'` or `'dropoff'`), counts only unread
  /// messages in that channel. If [channel] is null, counts total unread
  /// messages across all channels.
  Stream<int> unreadCountStream({
    required String tripId,
    required String currentUid,
    String? channel,
  }) {
    if (tripId.isEmpty || currentUid.isEmpty) return Stream.value(0);

    late StreamController<int> controller;
    StreamSubscription? msgSub;
    StreamSubscription? readSub;
    List<TripChatMessage> latestMessages = const [];

    Future<void> recalculate() async {
      int count = 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final m in latestMessages) {
        if (m.senderId == currentUid) continue;
        final ch = m.channel.isEmpty ? 'pickup' : m.channel;
        final lastRead = await getLastReadTimestamp(
          tripId: tripId,
          channel: ch,
          currentUid: currentUid,
        );
        final msgTime = m.createdAt?.millisecondsSinceEpoch ?? nowMs;
        if (msgTime > lastRead) {
          count++;
        }
      }
      if (!controller.isClosed) {
        controller.add(count);
      }
    }

    controller = StreamController<int>.broadcast(
      onListen: () {
        msgSub = messagesStream(tripId, channel: channel).listen((msgs) {
          latestMessages = msgs;
          unawaited(recalculate());
        });
        readSub = _readUpdatesController.stream.listen((_) {
          unawaited(recalculate());
        });
      },
      onCancel: () {
        msgSub?.cancel();
        readSub?.cancel();
      },
    );

    return controller.stream;
  }

  /// Sends a text message as [senderRole] (`customer` | `recipient` |
  /// `driver` | `support`) on [channel] (`pickup` | `dropoff`).
  /// Throws [TripChatException] on failure.
  Future<void> sendText({
    required String tripId,
    required String senderId,
    required String senderRole,
    required String text,
    String channel = 'pickup',
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
        'channel': channel,
        'timestamp': FieldValue.serverTimestamp(),
      });
      // Sending a message marks the sender's channel as read up to now
      await markChannelRead(tripId: tripId, channel: channel, currentUid: senderId);
    } catch (e) {
      debugPrint('TripChatService.sendText failed: $e');
      throw const TripChatException(
          'send-failed', 'Could not send the message. Try again.');
    }
  }

  /// Uploads a photo to `trip_media/{tripId}/` and posts it as an image
  /// message on [channel] (`pickup` | `dropoff`). Returns the download URL.
  Future<String> sendImage({
    required String tripId,
    required String senderId,
    required String senderRole,
    required String localPath,
    String channel = 'pickup',
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
      final rawBytes = await File(localPath).readAsBytes();
      final bytes = await ImageCompressionService.compressBytes(rawBytes);
      await ref.putData(
          bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      await col.add({
        'senderId': senderId,
        'senderRole': senderRole,
        'type': 'image',
        'text': '',
        'imageUrl': url,
        'channel': channel,
        'timestamp': FieldValue.serverTimestamp(),
      });
      // Sending an image marks the sender's channel as read up to now
      await markChannelRead(tripId: tripId, channel: channel, currentUid: senderId);
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
