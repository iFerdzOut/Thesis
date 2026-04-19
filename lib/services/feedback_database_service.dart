// ignore_for_file: avoid_print

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'feedback_consent_service.dart';

/// FeedbackDatabaseService
///
/// Collects false positives and false negatives for future
/// DistilBERT model retraining — this is the thesis novelty.
///
/// Data is uploaded directly to Firestore under `model_feedback`
/// for thesis evaluation and retraining support.
///
/// False Positive = AI flagged as smishing BUT user says it's safe
/// False Negative = AI missed it BUT user says it's smishing
///
/// Compliant with RA 10173 (Data Privacy Act):
/// - No names stored, only message text + metadata
/// - User can delete their own feedback
/// - Data is anonymized before global collection
class FeedbackDatabaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get _uid => _auth.currentUser?.uid ?? '';
  String get _userHash => _uid.hashCode.toRadixString(16);

  // ══════════════════════════════════════════════════════════════════════
  // SAVE FEEDBACK
  // ══════════════════════════════════════════════════════════════════════

  /// Save a FALSE POSITIVE — AI said smishing but user says safe
  Future<void> saveFalsePositive({
    required String message,
    required String source, // 'sms' or 'online'
    String? sender,
  }) async {
    if (!await _canUploadFeedback()) return;

    final data = _buildFeedbackData(
      message: message,
      label: 'false_positive',
      aiPrediction: 'smishing',
      userCorrection: 'safe',
      source: source,
      sender: sender,
    );

    await _saveDirectlyToModelFeedback(data);

    print('[FeedbackDB] False positive saved for retraining');
  }

  /// Save a FALSE NEGATIVE — AI said safe but user says smishing
  Future<void> saveFalseNegative({
    required String message,
    required String source,
    String? sender,
  }) async {
    if (!await _canUploadFeedback()) return;

    final data = _buildFeedbackData(
      message: message,
      label: 'false_negative',
      aiPrediction: 'safe',
      userCorrection: 'smishing',
      source: source,
      sender: sender,
    );

    await _saveDirectlyToModelFeedback(data);

    print('[FeedbackDB] False negative saved for retraining');
  }

  /// Save a CONFIRMED SMISHING — AI correctly flagged, user confirmed
  Future<void> saveConfirmedSmishing({
    required String message,
    required String source,
    String? sender,
  }) async {
    if (!await _canUploadFeedback()) return;

    final data = _buildFeedbackData(
      message: message,
      label: 'confirmed_smishing',
      aiPrediction: 'smishing',
      userCorrection: 'smishing',
      source: source,
      sender: sender,
    );

    await _saveDirectlyToModelFeedback(data);

    print('[FeedbackDB] Confirmed smishing saved');
  }

  // ══════════════════════════════════════════════════════════════════════
  // READ FEEDBACK
  // ══════════════════════════════════════════════════════════════════════

  /// Stream all feedback entries for the current user
  Stream<QuerySnapshot> getUserFeedback() {
    if (_uid.isEmpty) return const Stream.empty();
    return _firestore
        .collection('model_feedback')
        .where('userHash', isEqualTo: _userHash)
        .snapshots();
  }

  /// Get feedback count by label
  Future<Map<String, int>> getFeedbackStats() async {
    if (_uid.isEmpty) return {};

    final snapshot = await _firestore
        .collection('model_feedback')
        .where('userHash', isEqualTo: _userHash)
        .get();

    final stats = <String, int>{
      'false_positive': 0,
      'false_negative': 0,
      'confirmed_smishing': 0,
    };

    for (final doc in snapshot.docs) {
      final label = doc.data()['label'] as String? ?? '';
      if (stats.containsKey(label)) {
        stats[label] = stats[label]! + 1;
      }
    }

    return stats;
  }

  /// Delete a feedback entry
  Future<void> deleteFeedback(String docId) async {
    if (_uid.isEmpty) return;
    await _firestore.collection('model_feedback').doc(docId).delete();
  }

  /// Get global feedback count (for dashboard)
  Future<int> getGlobalFeedbackCount() async {
    try {
      final snapshot =
          await _firestore.collection('model_feedback').count().get();
      return snapshot.count ?? 0;
    } catch (e) {
      return 0;
    }
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
      // Store message for retraining
      'message': message,
      'messageSanitized': _sanitizeMessage(message),
      'messageLength': message.length,
      'hasUrl': message.contains('http') ||
          message.contains('www.') ||
          message.contains('.com') ||
          message.contains('.ph'),
      'reportedAt': FieldValue.serverTimestamp(),
      'appVersion': '1.0.0',
    };
  }

  /// Save anonymized feedback directly to model_feedback.
  /// No raw sender or raw personal identifiers are stored.
  Future<void> _saveDirectlyToModelFeedback(Map<String, dynamic> data) async {
    try {
      final sanitizedMessage =
          data['messageSanitized']?.toString().trim().isNotEmpty == true
              ? data['messageSanitized'].toString().trim()
              : _sanitizeMessage(data['message']?.toString() ?? '');

      // Remove any potentially identifying info before global save
      final anonymized = Map<String, dynamic>.from(data)
        ..remove('sender')
        ..remove('message')
        ..remove('messageSanitized');

      await _firestore.collection('model_feedback').add({
        ...anonymized,
        'messageSanitized': sanitizedMessage,
        'uploadMode': 'direct_report',
        'userHash': _userHash,
      });
    } catch (e) {
      print('[FeedbackDB] Global save error: $e');
    }
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
