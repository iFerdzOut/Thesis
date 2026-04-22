import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/sms_storage_service.dart';
import '../services/sms_background_worker.dart';
import '../feedback_local_db.dart';
import 'contribution_hub_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final SmsStorageService _smsStorageService;
  late Future<Map<String, int>> _feedbackStatsFuture;

  @override
  void initState() {
    super.initState();
    _smsStorageService = SmsStorageService();
    _feedbackStatsFuture = FeedbackLocalDb.getFeedbackCounts();
  }

  void _refreshFeedbackStats() {
    setState(() {
      _feedbackStatsFuture = FeedbackLocalDb.getFeedbackCounts();
    });

    // TEMPORARY TEST: Force background worker to scan immediately
    SmsBackgroundWorker.triggerImmediateScanTest();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        title: const Text('Dashboard',
            style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _refreshFeedbackStats,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: currentUserId.isEmpty
            ? const Stream.empty()
            : FirebaseFirestore.instance
                .collection('users')
                .doc(currentUserId)
                .collection('quarantine')
                .snapshots(),
        builder: (context, quarantineSnap) {
          final int onlineQuarantined = quarantineSnap.hasData
              ? quarantineSnap.data!.docs.length
              : 0;

          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: _smsStorageService.watchQuarantineMessages(),
            builder: (context, localQuarantineSnap) {
              final int localQuarantined =
                  localQuarantineSnap.data?.length ?? 0;
              final int quarantined = onlineQuarantined + localQuarantined;

              return FutureBuilder<Map<String, int>>(
                future: _feedbackStatsFuture,
                builder: (context, feedbackSnap) {
              final stats = feedbackSnap.data ?? {};
              final falsePositives = stats['false_positive'] ?? 0;
              final falseNegatives = stats['false_negative'] ?? 0;
              final confirmedSmishing = stats['confirmed_smishing'] ?? 0;
              final totalFeedback =
                  falsePositives + falseNegatives + confirmedSmishing;

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Security Overview',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),

                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          title: 'Quarantined',
                          value: quarantined.toString(),
                          icon: Icons.report_gmailerrorred_outlined,
                          color: Colors.deepPurple,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          title: 'Total Reports',
                          value: totalFeedback.toString(),
                          icon: Icons.feedback_outlined,
                          color: Colors.orange,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  const Text('Model Retraining Data',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    'Your reports help improve the DistilBERT detection model',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          title: 'False Positives',
                          value: falsePositives.toString(),
                          icon: Icons.check_circle_outline,
                          color: const Color(0xFF075E54),
                          subtitle: 'AI wrong\n(safe msgs flagged)',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          title: 'False Negatives',
                          value: falseNegatives.toString(),
                          icon: Icons.warning_amber_outlined,
                          color: Colors.redAccent,
                          subtitle: 'AI missed\n(smishing not caught)',
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  _StatCard(
                    title: 'Confirmed Smishing',
                    value: confirmedSmishing.toString(),
                    icon: Icons.shield_outlined,
                    color: Colors.orange,
                    subtitle: 'AI correctly flagged & user confirmed',
                    fullWidth: true,
                  ),

                  const SizedBox(height: 24),

                  if (totalFeedback > 0) ...[
                    const Text('Detection Accuracy',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    _AccuracyCard(
                      confirmed: confirmedSmishing,
                      falsePositives: falsePositives,
                      falseNegatives: falseNegatives,
                    ),
                    const SizedBox(height: 24),
                  ],

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text(
                        'Open Contribution Hub',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ContributionHubScreen(),
                          ),
                        ).then((_) => _refreshFeedbackStats());
                      },
                    ),
                  ),
                  const SizedBox(height: 24),

                  const Text('Recent Alerts',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  StreamBuilder<QuerySnapshot>(
                    stream: currentUserId.isEmpty
                        ? const Stream.empty()
                        : FirebaseFirestore.instance
                            .collection('users')
                            .doc(currentUserId)
                            .collection('quarantine')
                            .orderBy('reportedAt', descending: true)
                            .limit(3)
                            .snapshots(),
                    builder: (context, alertSnap) {
                      if (!alertSnap.hasData ||
                          alertSnap.data!.docs.isEmpty) {
                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.verified_user_outlined,
                                  color: Colors.green.shade400),
                              const SizedBox(width: 12),
                              const Text('No recent alerts — you\'re safe!'),
                            ],
                          ),
                        );
                      }

                      return Column(
                        children: alertSnap.data!.docs.map((doc) {
                          final data = doc.data() as Map<String, dynamic>;
                          final sender = data['sender'] ?? 'Unknown';
                          final source = data['source'] ?? '';
                          final time = data['reportedAt'];
                          String timeStr = '';
                          if (time is Timestamp) {
                            final dt = time.toDate();
                            timeStr =
                                '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
                          }

                          return _AlertTile(
                            title: 'Suspicious message from $sender',
                            subtitle: source.startsWith('false_negative')
                                ? 'Manually reported by you'
                                : 'Auto-detected by AI',
                            time: timeStr,
                            color: source.startsWith('false_negative')
                                ? Colors.red
                                : Colors.orange,
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final String? subtitle;
  final bool fullWidth;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.subtitle,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: fullWidth ? double.infinity : null,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            // FIX: withOpacity → withValues
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
          ),
        ],
      ),
      child: fullWidth
          ? Row(
              children: [
                CircleAvatar(
                  // FIX: withOpacity → withValues
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(value,
                          style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold)),
                      Text(title,
                          style: const TextStyle(color: Colors.grey)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade400)),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  // FIX: withOpacity → withValues
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(height: 14),
                Text(value,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(title,
                    style: const TextStyle(color: Colors.grey)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!,
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade400)),
                ],
              ],
            ),
    );
  }
}

class _AccuracyCard extends StatelessWidget {
  final int confirmed;
  final int falsePositives;
  final int falseNegatives;

  const _AccuracyCard({
    required this.confirmed,
    required this.falsePositives,
    required this.falseNegatives,
  });

  @override
  Widget build(BuildContext context) {
    final total = confirmed + falsePositives + falseNegatives;
    final accuracy = total == 0 ? 0.0 : confirmed / total;
    final pct = (accuracy * 100).toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            // FIX: withOpacity → withValues
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('$pct%',
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: accuracy > 0.7
                          ? const Color(0xFF075E54)
                          : Colors.orange)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Detection Accuracy',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Text('Based on $total user feedback reports',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: accuracy,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                accuracy > 0.7
                    ? const Color(0xFF075E54)
                    : Colors.orange,
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This data will be used to retrain the DistilBERT model '
            'for improved Philippine smishing detection.',
            style: TextStyle(
                fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String time;
  final Color color;

  const _AlertTile({
    required this.title,
    required this.subtitle,
    required this.time,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        leading: CircleAvatar(
          // FIX: withOpacity → withValues
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(Icons.notifications_active_outlined, color: color),
        ),
        title: Text(title,
            style: const TextStyle(fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 12)),
        trailing: Text(time,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ),
    );
  }
}
