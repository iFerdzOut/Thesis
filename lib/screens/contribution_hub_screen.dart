import 'dart:io';

import 'package:flutter/material.dart';
import '../services/feedback/feedback_database_service.dart';
import '../services/feedback/feedback_local_db.dart';

class ContributionHubScreen extends StatefulWidget {
  const ContributionHubScreen({super.key});

  @override
  State<ContributionHubScreen> createState() => _ContributionHubScreenState();
}

class _ContributionHubScreenState extends State<ContributionHubScreen> {
  List<Map<String, dynamic>> _feedbackList = [];
  bool _isLoading = true;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _loadFeedback();
  }

  Future<void> _loadFeedback() async {
    setState(() => _isLoading = true);
    final data = await FeedbackLocalDb.getUnsyncedFeedback();
    if (!mounted) return;
    setState(() {
      _feedbackList = data;
      _isLoading = false;
    });
  }

  Future<void> _deleteItem(int id) async {
    await FeedbackLocalDb.deleteFeedbackBatch([id]);
    await _loadFeedback();
  }

  Future<void> _uploadData() async {
    if (_feedbackList.isEmpty) return;

    setState(() => _isUploading = true);

    try {
      final service = FeedbackDatabaseService();
      await service.syncFeedbackToPostgres();
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Successfully uploaded data anonymously. Thank you!'),
          backgroundColor: Color(0xFF25D366), // Signal/WhatsApp Green
        ),
      );
      await _loadFeedback();
    } on SocketException catch (_) {
      if (!mounted) return;
      // Rule 4: Network resilience fallback
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Network error. Reports queued, will try again when online.'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final falsePositives = _feedbackList
        .where((f) => f['label'] == 'false_positive')
        .toList();
    final missedThreats = _feedbackList
        .where((f) => f['label'] == 'false_negative' || f['label'] == 'confirmed_smishing')
        .toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Contribution Hub'),
          backgroundColor: const Color(0xFF075E54),
          bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(text: 'Recovered Safe'),
              Tab(text: 'Missed Threats'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF075E54),
                ),
              )
            : TabBarView(
                children: [
                  _buildListView(
                    items: falsePositives,
                    emptyMessage: 'No recovered safe messages to report.',
                  ),
                  _buildListView(
                    items: missedThreats,
                    emptyMessage: 'No missed threats to report.',
                  ),
                ],
              ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              onPressed: _feedbackList.isEmpty || _isUploading ? null : _uploadData,
              child: _isUploading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Upload Data to Developers',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildListView({
    required List<Map<String, dynamic>> items,
    required String emptyMessage,
  }) {
    if (items.isEmpty) {
      return Center(
        child: Text(emptyMessage, style: const TextStyle(color: Colors.grey)),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        return ListTile(
          title: Text(
            item['messageSanitized']?.toString() ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              'AI: ${item['aiPrediction'].toString().toUpperCase()} • You: ${item['userCorrection'].toString().toUpperCase()}',
              style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Remove from upload batch',
            onPressed: () => _deleteItem(item['id'] as int),
          ),
        );
      },
    );
  }
}