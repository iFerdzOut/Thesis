import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/chat/online_chat_service.dart';
import '../services/feedback/feedback_database_service.dart';
import '../services/feedback/feedback_service.dart';
import '../smishing_detection_pipeline/pipeline_service.dart';
import '../services/sms/sms_storage_service.dart';
import '../services/system/window_service.dart';
import '../widgets/feedback_upload_consent_dialog.dart';

class QuarantineScreen extends StatefulWidget {
  const QuarantineScreen({super.key});

  @override
  State<QuarantineScreen> createState() => _QuarantineScreenState();
}

class _QuarantineScreenState extends State<QuarantineScreen> {
  static const Duration _trustCountdownDuration = Duration(seconds: 10);

  final OnlineChatService onlineChatService = OnlineChatService();
  final SmsStorageService smsStorageService = SmsStorageService();
  final FeedbackService feedbackService = FeedbackService();
  final UrlDefanger quarantineService = UrlDefanger();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _selectionMode = false;
  final Set<String> _selectedEntryIds = <String>{};

  @override
  void initState() {
    super.initState();
    WindowService.enableSecureScreen();
  }

  @override
  void dispose() {
    WindowService.disableSecureScreen();
    super.dispose();
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return 'Unknown time';
    DateTime dt;
    if (timestamp is Timestamp) {
      dt = timestamp.toDate();
    } else if (timestamp is DateTime) {
      dt = timestamp;
    } else if (timestamp is String) {
      dt = DateTime.tryParse(timestamp) ?? DateTime.now();
    } else {
      return 'Unknown time';
    }
    final h = dt.hour == 0
        ? 12
        : dt.hour > 12
            ? dt.hour - 12
            : dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.month}/${dt.day}/${dt.year}  $h:$m $s';
  }

  String _defang(String msg) {
    return quarantineService.defangText(msg);
  }

  String _sourceLabel(String source) {
    switch (source) {
      case 'sms':
        return 'SMS';
      case 'online':
        return 'Online Chat';
      case 'false_negative_sms':
        return 'Reported (SMS)';
      case 'false_negative_online':
        return 'Reported (Online)';
      default:
        return source;
    }
  }

  Color _sourceColor(String source) {
    if (source.startsWith('false_negative')) return Colors.red;
    return source == 'sms' ? Colors.orange : const Color(0xFF075E54);
  }

  List<_VaultEntry> _mergeEntries({
    required List<Map<String, dynamic>> smsEntries,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> onlineDocs,
  }) {
    final mergedById = <String, _VaultEntry>{};

    for (final entry in smsEntries) {
      final id = entry['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      mergedById[id] = _VaultEntry(
        id: id,
        sender: entry['sender']?.toString() ?? 'Unknown',
        message: entry['message']?.toString() ?? '',
        source: entry['source']?.toString() ?? 'sms',
        reportedAt: entry['reportedAt'] ?? entry['timestamp'],
        isLocalSms: true,
        raw: entry,
      );
    }

    for (final doc in onlineDocs) {
      final source = doc.data()['source']?.toString() ?? 'online';
      mergedById.putIfAbsent(
        doc.id,
        () => _VaultEntry(
          id: doc.id,
          sender: doc.data()['sender']?.toString() ?? 'Unknown',
          message: doc.data()['message']?.toString() ?? '',
          source: source,
          reportedAt:
              doc.data()['reportedAt'] ?? doc.data()['reportedAtClientMs'] ?? doc.data()['timestampMs'],
          isLocalSms: _isSmsSource(source),
          raw: Map<String, dynamic>.from(doc.data()),
        ),
      );
    }

    final merged = mergedById.values.toList(growable: false)
      ..sort((a, b) {
        final aMs = _timestampMs(a.reportedAt);
        final bMs = _timestampMs(b.reportedAt);
        return bMs.compareTo(aMs);
      });

    return merged;
  }

  bool _isSmsSource(String source) {
    return source == 'sms' || source == 'false_negative_sms';
  }

  bool _canMarkTrusted(_VaultEntry entry) {
    return entry.source == 'sms' || entry.source == 'online';
  }

  String _feedbackStatusLabel(FeedbackUploadStatus status) {
    switch (status) {
      case FeedbackUploadStatus.uploaded:
        return 'Uploaded to Firebase.';
      case FeedbackUploadStatus.queued:
        return 'Queued for Firebase retry.';
      case FeedbackUploadStatus.disabled:
        return 'Feedback upload is off in Settings.';
    }
  }

  int _timestampMs(dynamic value) {
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    if (value is String) {
      return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  void _setSelectionMode(bool enabled) {
    setState(() {
      _selectionMode = enabled;
      if (!enabled) {
        _selectedEntryIds.clear();
      }
    });
  }

  void _toggleEntrySelected(String id) {
    setState(() {
      if (_selectedEntryIds.contains(id)) {
        _selectedEntryIds.remove(id);
      } else {
        _selectedEntryIds.add(id);
      }
      if (_selectedEntryIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  Future<void> _restoreEntry(_VaultEntry entry) async {
    await ensureFeedbackUploadPreference(context);
    late final FeedbackUploadStatus uploadStatus;
    if (entry.isLocalSms) {
      uploadStatus = await feedbackService.markSmsFalsePositiveAndRestore(
        entry.id,
      );
    } else {
      uploadStatus = await onlineChatService.removeFalsePositiveFromQuarantine(
        entry.id,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Message marked as trusted and restored. ${_feedbackStatusLabel(uploadStatus)}',
        ),
        backgroundColor: const Color(0xFF075E54),
      ),
    );
  }

  Future<void> _deleteEntry(_VaultEntry entry) async {
    if (entry.isLocalSms) {
      await smsStorageService.deleteQuarantineMessage(entry.id);
      await onlineChatService.removeSmsQuarantineMirror(entry.id);
    } else {
      await onlineChatService.deleteQuarantineMessage(entry.id);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message deleted from quarantine.')),
    );
  }

  Future<void> _deleteEntries(List<_VaultEntry> entries) async {
    final smsIds = entries
        .where((entry) => entry.isLocalSms)
        .map((entry) => entry.id)
        .toList();
    final onlineIds = entries
        .where((entry) => !entry.isLocalSms)
        .map((entry) => entry.id)
        .toList();

    if (smsIds.isNotEmpty) {
      await smsStorageService.deleteQuarantineMessages(smsIds);
      for (final id in smsIds) {
        await onlineChatService.removeSmsQuarantineMirror(id);
      }
    }
    for (final id in onlineIds) {
      await onlineChatService.deleteQuarantineMessage(id);
    }
  }

  Future<void> _showDeleteDialog({
    required String title,
    required String message,
    required Future<void> Function() onDelete,
  }) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;
    await onDelete();
  }

  Future<void> _showTrustCountdownDialog(_VaultEntry entry) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TrustCountdownDialog(
        countdown: _trustCountdownDuration,
        onConfirm: () => _restoreEntry(entry),
      ),
    );
  }

  void _showMessageOptions(_VaultEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Quarantined Message Options',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const Divider(),
            if (_canMarkTrusted(entry))
              ListTile(
                leading: const Icon(Icons.verified_user_outlined,
                    color: Color(0xFF075E54)),
                title: const Text('Mark as Trusted'),
                subtitle: const Text(
                  'Wait 10 seconds before restoring this message',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showTrustCountdownDialog(entry);
                },
              ),
            ListTile(
              leading:
                  const Icon(Icons.delete_forever_outlined, color: Colors.red),
              title: const Text('Delete Permanently'),
              subtitle: const Text('Remove this message from quarantine'),
              onTap: () {
                Navigator.pop(context);
                _showDeleteDialog(
                  title: 'Delete Message?',
                  message:
                      'This will permanently delete the message from quarantine. It will not be restored to your inbox.',
                  onDelete: () => _deleteEntry(entry),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.copy_outlined, color: Colors.grey.shade400),
              title: Text(
                'Copy Text',
                style: TextStyle(color: Colors.grey.shade400),
              ),
              subtitle: Text(
                'Disabled - links in quarantined messages cannot be copied',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Copy is disabled in the Quarantine Vault to prevent accidental link opening.\nNaka-disable ang copy para maiwasan ang di-sinasadyang pag-open ng link.',
                    ),
                    backgroundColor: Colors.orange,
                    duration: Duration(seconds: 3),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildAppBarActions(List<_VaultEntry> entries) {
    if (_selectionMode) {
      return [
        Center(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '${_selectedEntryIds.length} selected',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.white),
          onPressed: _selectedEntryIds.isEmpty
              ? null
              : () {
                  final selectedEntries = entries
                      .where((entry) => _selectedEntryIds.contains(entry.id))
                      .toList();
                  _showDeleteDialog(
                    title: 'Delete Selected Messages?',
                    message:
                        'This will permanently delete ${selectedEntries.length} quarantined message${selectedEntries.length == 1 ? '' : 's'}.',
                    onDelete: () async {
                      await _deleteEntries(selectedEntries);
                      if (!mounted) return;
                      _setSelectionMode(false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${selectedEntries.length} message${selectedEntries.length == 1 ? '' : 's'} deleted.',
                          ),
                        ),
                      );
                    },
                  );
                },
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => _setSelectionMode(false),
        ),
      ];
    }

    return [
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.white),
        onSelected: (value) {
          if (value == 'select') {
            _setSelectionMode(true);
          } else if (value == 'delete_all') {
            _showDeleteDialog(
              title: 'Delete All Quarantined Messages?',
              message:
                  'This will permanently delete all quarantined messages currently shown in the vault.',
              onDelete: () async {
                await _deleteEntries(entries);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('All quarantined messages deleted.'),
                  ),
                );
              },
            );
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem<String>(
            value: 'select',
            child: Text('Mass delete'),
          ),
          PopupMenuItem<String>(
            value: 'delete_all',
            child: Text('Delete all'),
          ),
        ],
      ),
    ];
  }

  Widget _buildContent(List<_VaultEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.verified_user_outlined,
              size: 72,
              color: Colors.green.shade300,
            ),
            const SizedBox(height: 16),
            const Text(
              'Quarantine Vault is empty',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'No suspicious messages detected.\nYou\'re safe!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final defanged = _defang(entry.message);
        final hasLink = entry.message != defanged;
        final selected = _selectedEntryIds.contains(entry.id);

        final rawReasons = entry.raw['detectionReasons'];
        final detectionReasons = (rawReasons is List)
            ? rawReasons
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList()
            : const <String>[];

        return _QuarantineCard(
          key: ValueKey(entry.id),
          sender: entry.sender,
          defangedMessage: defanged,
          source: _sourceLabel(entry.source),
          sourceColor: _sourceColor(entry.source),
          time: _formatTime(entry.reportedAt),
          hasDefangedLinks: hasLink,
          selectionMode: _selectionMode,
          selected: selected,
          detectionReasons: detectionReasons,
          onTap: () {
            if (_selectionMode) {
              _toggleEntrySelected(entry.id);
              return;
            }
            _showMessageOptions(entry);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: smsStorageService.watchQuarantineMessages(),
      builder: (context, smsSnapshot) {
        final smsEntries = smsSnapshot.data ?? const <Map<String, dynamic>>[];
        return StreamBuilder<User?>(
          stream: _auth.authStateChanges(),
          builder: (context, authSnapshot) {
            final user = authSnapshot.data;

            if (user == null || user.isAnonymous) {
              final entries =
                  _mergeEntries(smsEntries: smsEntries, onlineDocs: const []);
              return _buildScaffold(entries);
            }

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: onlineChatService.getQuarantineMessages(),
              builder: (context, onlineSnapshot) {
                final onlineDocs = onlineSnapshot.hasData
                    ? onlineSnapshot.data!.docs
                    : const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                final entries = _mergeEntries(
                  smsEntries: smsEntries,
                  onlineDocs: onlineDocs,
                );
                return _buildScaffold(entries);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildScaffold(List<_VaultEntry> entries) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F0),
      appBar: AppBar(
        backgroundColor: Colors.orange.shade800,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Row(
          children: [
            Icon(Icons.lock, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('Quarantine Vault', style: TextStyle(color: Colors.white)),
          ],
        ),
        actions: _buildAppBarActions(entries),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.orange.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.security, size: 16, color: Colors.orange.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Screenshots disabled • Links defanged • Copy disabled\n'
                    'Tap for options. Trusted restore is delayed by 10 seconds for safety.\n'
                    'Na-block ang screenshot at pag-copy para sa kaligtasan mo.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildContent(entries)),
        ],
      ),
    );
  }
}

class _VaultEntry {
  final String id;
  final String sender;
  final String message;
  final String source;
  final dynamic reportedAt;
  final bool isLocalSms;
  final Map<String, dynamic> raw;

  const _VaultEntry({
    required this.id,
    required this.sender,
    required this.message,
    required this.source,
    required this.reportedAt,
    required this.isLocalSms,
    required this.raw,
  });
}

class _QuarantineCard extends StatefulWidget {
  final String sender;
  final String defangedMessage;
  final String source;
  final Color sourceColor;
  final String time;
  final bool hasDefangedLinks;
  final bool selectionMode;
  final bool selected;
  final List<String> detectionReasons;
  final VoidCallback onTap;

  const _QuarantineCard({
    super.key,
    required this.sender,
    required this.defangedMessage,
    required this.source,
    required this.sourceColor,
    required this.time,
    required this.hasDefangedLinks,
    required this.selectionMode,
    required this.selected,
    required this.detectionReasons,
    required this.onTap,
  });

  @override
  State<_QuarantineCard> createState() => _QuarantineCardState();
}

class _QuarantineCardState extends State<_QuarantineCard> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.orange.shade200),
        ),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (widget.selectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Checkbox(
                        value: widget.selected,
                        onChanged: (_) => widget.onTap(),
                      ),
                    )
                  else
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.orange.shade100,
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange,
                        size: 20,
                      ),
                    ),
                  if (!widget.selectionMode) const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.sender,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: widget.sourceColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.source,
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.sourceColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade100),
                ),
                child: Text(
                  widget.defangedMessage,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
              const SizedBox(height: 8),
              if (widget.detectionReasons.isNotEmpty) ...[
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 12, color: Colors.orange.shade700),
                    const SizedBox(width: 4),
                    Text(
                      'Why flagged:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: widget.detectionReasons.map((reason) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Text(
                        reason,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 6),
              ],
              if (widget.hasDefangedLinks)
                Row(
                  children: [
                    Icon(Icons.link_off, size: 13, color: Colors.red.shade300),
                    const SizedBox(width: 4),
                    Text(
                      'Links defanged — cannot be clicked or copied',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.red.shade400,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 12,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.time,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const Spacer(),
                  Text(
                    widget.selectionMode
                        ? 'Tap to select'
                        : 'Tap for options',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrustCountdownDialog extends StatefulWidget {
  final Duration countdown;
  final Future<void> Function() onConfirm;

  const _TrustCountdownDialog({
    required this.countdown,
    required this.onConfirm,
  });

  @override
  State<_TrustCountdownDialog> createState() => _TrustCountdownDialogState();
}

class _TrustCountdownDialogState extends State<_TrustCountdownDialog> {
  Timer? _timer;
  late int _secondsRemaining;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.countdown.inSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_secondsRemaining <= 1) {
        timer.cancel();
        setState(() => _secondsRemaining = 0);
        return;
      }
      setState(() => _secondsRemaining--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.shield_outlined, color: Color(0xFF075E54)),
          SizedBox(width: 8),
          Text('Mark as Trusted?'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This message was flagged as suspicious. Mark it as trusted only if you are sure it is safe.\nNa-flag ang mensaheng ito bilang kahina-hinala. I-mark lang ito bilang trusted kung sigurado kang ligtas ito.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange.shade700,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'If this is actually a scam, restoring it may expose you to fraud, fake verification, or OTP theft.\nKapag scam ito, maaaring malagay sa panganib ang account o pera mo.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _secondsRemaining == 0
                    ? Colors.green.shade50
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _secondsRemaining == 0
                      ? Colors.green
                      : Colors.grey.shade300,
                ),
              ),
              child: Text(
                _secondsRemaining == 0
                    ? 'You can now mark this message as trusted.'
                    : 'Please wait $_secondsRemaining second${_secondsRemaining == 1 ? '' : 's'} before restoring this message.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _secondsRemaining == 0
                      ? Colors.green.shade800
                      : Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _secondsRemaining == 0
                ? const Color(0xFF075E54)
                : Colors.grey.shade300,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _secondsRemaining > 0 || _submitting
              ? null
              : () async {
                  setState(() => _submitting = true);
                  Navigator.pop(context);
                  await widget.onConfirm();
                },
          child: Text(
            _secondsRemaining == 0
                ? 'Mark as Trusted'
                : 'Wait ${_secondsRemaining}s',
            style: TextStyle(
              color:
                  _secondsRemaining == 0 ? Colors.white : Colors.grey.shade500,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}
