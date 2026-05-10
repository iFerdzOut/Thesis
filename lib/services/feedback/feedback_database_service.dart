// ignore_for_file: avoid_print

import 'package:firebase_auth/firebase_auth.dart';

import '../../generated/dataconnect/smishing_shield_connector.dart';
import 'feedback_local_db.dart';
import 'feedback_consent_service.dart';

/// FeedbackDatabaseService
///
/// Collects false positives and false negatives for future
/// DistilBERT model retraining — this is the thesis novelty.
///
/// Rule 4: Data is buffered in encrypted SQLite first, then manually 
/// synced anonymously to PostgreSQL via Firebase Data Connect.
///
/// False Positive = AI flagged as smishing BUT user says it's safe
/// False Negative = AI missed it BUT user says it's smishing
///
/// Compliant with RA 10173 (Data Privacy Act):
/// - No names stored, only message text + metadata
/// - User can delete their own feedback
/// - Data is anonymized before global collection
enum FeedbackUploadStatus {
  disabled,
  uploaded,
  queued,
}

class FeedbackDatabaseService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get _uid => _auth.currentUser?.uid ?? '';

  // ══════════════════════════════════════════════════════════════════════
  // SAVE FEEDBACK
  // ══════════════════════════════════════════════════════════════════════

  /// Save a FALSE POSITIVE — AI said smishing but user says safe
  Future<FeedbackUploadStatus> saveFalsePositive({
    required String message,
    required String source, // 'sms' or 'online'
    String? sender,
  }) async {
    if (!await _canUploadFeedback()) return FeedbackUploadStatus.disabled;

    final data = _buildFeedbackData(
      message: message,
      label: 'false_positive',
      aiPrediction: 'smishing',
      userCorrection: 'safe',
      source: source,
      sender: sender,
    );

    final status = await _bufferAndAttemptSync(data);

    print('[FeedbackDB] False positive saved for retraining');
    return status;
  }

  /// Save a FALSE NEGATIVE — AI said safe but user says smishing
  Future<FeedbackUploadStatus> saveFalseNegative({
    required String message,
    required String source,
    String? sender,
  }) async {
    if (!await _canUploadFeedback()) return FeedbackUploadStatus.disabled;

    final data = _buildFeedbackData(
      message: message,
      label: 'false_negative',
      aiPrediction: 'safe',
      userCorrection: 'smishing',
      source: source,
      sender: sender,
    );

    final status = await _bufferAndAttemptSync(data);

    print('[FeedbackDB] False negative saved for retraining');
    return status;
  }

  /// Save a CONFIRMED SMISHING — AI correctly flagged, user confirmed
  Future<FeedbackUploadStatus> saveConfirmedSmishing({
    required String message,
    required String source,
    String? sender,
  }) async {
    if (!await _canUploadFeedback()) return FeedbackUploadStatus.disabled;

    final data = _buildFeedbackData(
      message: message,
      label: 'confirmed_smishing',
      aiPrediction: 'smishing',
      userCorrection: 'smishing',
      source: source,
      sender: sender,
    );

    final status = await _bufferAndAttemptSync(data);

    print('[FeedbackDB] Confirmed smishing saved');
    return status;
  }

  // ══════════════════════════════════════════════════════════════════════
  // POSTGRESQL SYNC LOOP (Rule 4)
  // ══════════════════════════════════════════════════════════════════════

  /// Manually triggered by the user to push local buffer to Postgres.
  /// Wipes SQLite rows upon a successful 200 OK.
  Future<void> syncFeedbackToPostgres() async {
    final unsynced = await FeedbackLocalDb.getUnsyncedFeedback();
    if (unsynced.isEmpty) return;

    List<int> successfulIds = [];

    for (final row in unsynced) {
      try {
        // Execute the strongly-typed GraphQL mutation via generated Dart SDK.
        await SmishingShieldConnectorConnector.instance.insertModelFeedback(
          label: row['label'] as String,
          aiPrediction: row['aiPrediction'] as String,
          userCorrection: row['userCorrection'] as String,
          source: row['source'] as String,
          senderType: row['senderType'] as String,
          messageSanitized: row['messageSanitized'] as String,
          messageLength: row['messageLength'] as int,
          hasUrl: row['hasUrl'] == 1,
          appVersion: row['appVersion'] as String,
        ).execute();
        successfulIds.add(row['id'] as int);
      } catch (e) {
        print('[FeedbackDB] Failed to sync row ${row['id']}: $e');
      }
    }

    // Rule 4: Wipe SQLite rows on successful upload
    await FeedbackLocalDb.deleteFeedbackBatch(successfulIds);
    print('[FeedbackDB] Successfully synced ${successfulIds.length} feedback items to PostgreSQL.');
  }

  // ══════════════════════════════════════════════════════════════════════
  // PRIVATE HELPERS
  // ══════════════════════════════════════════════════════════════════════

  Map<String, dynamic> _buildFeedbackData({
    required String message,
    required String label,
    required String aiPrediction,
    required String userCorrection,
    required String source,
    String? sender,
  }) {
    return {
      'label': label,
      'aiPrediction': aiPrediction,
      'userCorrection': userCorrection,
      'source': source,
      // Anonymize sender — only keep type (number/shortcode/unknown)
      'senderType': _categorizeSender(sender ?? ''),
      'messageSanitized': _sanitizeMessage(message),
      'messageLength': message.length,
      'hasUrl': message.contains('http') ||
          message.contains('www.') ||
          message.contains('.com') ||
          message.contains('.ph'),
      'appVersion': '1.0.0',
    };
  }

  /// Buffers feedback locally in SQLCipher
  Future<int?> _bufferFeedbackLocally(Map<String, dynamic> data) async {
    try {
      // Enforce zero raw PII before local storage
      data.remove('message');
      data.remove('sender');

      return await FeedbackLocalDb.insertFeedback(data);
    } catch (e) {
      print('[FeedbackDB] Local SQLite buffer error: $e');
      return null;
    }
  }

  Future<FeedbackUploadStatus> _bufferAndAttemptSync(
    Map<String, dynamic> data,
  ) async {
    final insertedId = await _bufferFeedbackLocally(Map<String, dynamic>.from(data));
    if (insertedId == null) {
      return FeedbackUploadStatus.queued;
    }
    try {
      await syncFeedbackToPostgres();
    } catch (e) {
      print('[FeedbackDB] Deferred sync will retry later: $e');
    }
    final unsynced = await FeedbackLocalDb.getUnsyncedFeedback();
    final stillQueued = unsynced.any((row) => row['id'] == insertedId);
    return stillQueued
        ? FeedbackUploadStatus.queued
        : FeedbackUploadStatus.uploaded;
  }

  Future<bool> _canUploadFeedback() async {
    if (_uid.isEmpty) return false;
    return FeedbackConsentService.isUploadEnabled();
  }

  String _sanitizeMessage(String message) {
    if (message.trim().isEmpty) return '';

    var sanitized = message;
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'((https?:\/\/|www\.)\S+)', caseSensitive: false),
      (_) => '[LINK]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
          caseSensitive: false),
      (_) => '[EMAIL]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'(\+?\d[\d\-\s]{6,}\d)'),
      (_) => '[PHONE]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b\d{4,8}\b'),
      (_) => '[CODE]',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b[A-Z]{2,}[A-Z0-9_]{1,}\b'),
      (match) {
        final value = match.group(0) ?? '';
        if (value.length <= 4) return value;
        return '[ID]';
      },
    );
    return sanitized.trim();
  }

  /// Categorize sender type for anonymization
  String _categorizeSender(String sender) {
    if (sender.isEmpty) return 'unknown';
    // Numeric phone number
    if (RegExp(r'^\+?[0-9\s\-]+$').hasMatch(sender)) return 'phone_number';
    // Short alphanumeric sender ID (like "GCASH", "BDO")
    if (sender.length <= 15 && RegExp(r'^[A-Za-z0-9\s]+$').hasMatch(sender)) {
      return 'sender_id';
    }
    return 'unknown';
  }
}
