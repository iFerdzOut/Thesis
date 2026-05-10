import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/feedback/feedback_consent_service.dart';

Future<void> ensureFeedbackUploadPreference(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null || user.isAnonymous) {
    return;
  }

  final hasAnswered = await FeedbackConsentService.hasAnsweredConsentPrompt();
  if (hasAnswered || !context.mounted) {
    return;
  }

  final allowUpload = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _FeedbackUploadConsentDialog(),
      ) ??
      false;

  await FeedbackConsentService.setUploadEnabled(allowUpload);
}

class _FeedbackUploadConsentDialog extends StatelessWidget {
  const _FeedbackUploadConsentDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_upload_outlined, color: Color(0xFF075E54)),
          SizedBox(width: 10),
          Expanded(
            child: Text('Help Improve Detection?'),
          ),
        ],
      ),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You can allow optional upload of sanitized report data to support evaluation and future retraining.',
            style: TextStyle(fontSize: 14, height: 1.35),
          ),
          SizedBox(height: 12),
          Text(
            'Pwede mong payagan ang optional upload ng nilinis na report data para makatulong sa evaluation at future retraining.',
            style: TextStyle(fontSize: 13, height: 1.35),
          ),
          SizedBox(height: 14),
          Text(
            'Names, phone numbers, links, and codes are sanitized before upload.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF075E54),
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text(
            'Allow upload',
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}
