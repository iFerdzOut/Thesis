import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/contacts_service.dart';
import '../services/device_contact_sync_service.dart';
import '../services/sms_service.dart';
import '../services/sms_storage_service.dart';
import 'chat_screen.dart';
import 'quarantine_screen.dart';

class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final SmsStorageService _storage = SmsStorageService();
  final DeviceContactSyncService _deviceContacts = DeviceContactSyncService();
  final ContactsServiceHelper _contactsService = ContactsServiceHelper();
  final TextEditingController _contactSearchController =
      TextEditingController();

  late final TabController _tabController;
  Timer? _contactSearchDebounceTimer;
  bool _loadingContacts = true;
  bool _checkingDefaultSms = true;
  bool _contactsPermissionGranted = true;
  bool _isDefaultSmsApp = true;
  bool _isEditingSms = false;
  bool _isRefreshingSms = false;
  bool _isSyncingContacts = false;
  bool _isBootstrappingSmsContactNames = false;
  String _contactSearch = '';
  List<Contact> _phoneContacts = <Contact>[];
  List<Map<String, dynamic>> _syncedContacts = <Map<String, dynamic>>[];
  Map<String, String> _localContactNameByPhoneKey = const <String, String>{};
  final Set<String> _selectedSmsThreadIds = <String>{};
  DateTime? _lastSmsRefreshAt;
  DateTime? _lastContactsSyncAt;
  int _smsRefreshGeneration = 0;
  bool _hasPrimedSmsInbox = false;
  int _phoneContactsVersion = 0;
  int _syncedContactsVersion = 0;
  String? _smsThreadsCacheKey;
  List<Map<String, dynamic>> _smsThreadsCache = const <Map<String, dynamic>>[];
  String? _contactsEntriesCacheKey;
  List<_PhoneContactEntry> _contactsEntriesCache = const <_PhoneContactEntry>[];
  static const Color _bgColor = Color(0xFF07131D);
  static const Color _surfaceColor = Color(0xFF10212E);
  static const Color _surfaceElevatedColor = Color(0xFF132837);
  static const Color _accentColor = Color(0xFF25D366);
  static const Color _warningColor = Color(0xFFFFB74D);
  static const Color _textPrimary = Color(0xFFF5FAFF);
  static const Color _textMuted = Color(0xFF93A4B5);
  static const Duration _smsRefreshCooldown = Duration(seconds: 20);
  static const Duration _contactsRefreshCooldown = Duration(minutes: 2);
  static const Duration _contactSearchDebounceDuration =
      Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SmsService.enterSmsExperience();
    _contactSearchController.addListener(_handleContactSearchChanged);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabSelection);
    _checkDefaultSmsApp(refreshIfDefault: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_primeSmsInboxAfterFirstFrame());
      unawaited(_bootstrapSmsContactNames());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SmsService.leaveSmsExperience();
    _contactSearchController.removeListener(_handleContactSearchChanged);
    _contactSearchDebounceTimer?.cancel();
    _tabController.removeListener(_handleTabSelection);
    _contactSearchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkDefaultSmsApp(refreshIfDefault: false));
      if (_tabController.index == 0) {
        unawaited(_refreshSmsThreads());
      }
      if (_tabController.index == 1 &&
          _isRefreshStale(_lastContactsSyncAt, _contactsRefreshCooldown)) {
        unawaited(_syncDeviceContacts());
      }
    }
  }

  void _handleTabSelection() {
    if (_tabController.indexIsChanging) return;
    if (mounted) {
      setState(() {});
    }
    if (_tabController.index == 0) {
      unawaited(_refreshSmsThreads());
    } else if (_tabController.index == 1) {
      unawaited(_syncDeviceContacts());
    }
  }

  void _handleContactSearchChanged() {
    final nextValue = _contactSearchController.text;
    if (nextValue == _contactSearch) {
      return;
    }
    _contactSearchDebounceTimer?.cancel();
    _contactSearchDebounceTimer = Timer(_contactSearchDebounceDuration, () {
      if (!mounted) return;
      setState(() {
        _contactSearch = nextValue;
      });
    });
  }

  bool _isRefreshStale(DateTime? lastRun, Duration cooldown) {
    if (lastRun == null) return true;
    return DateTime.now().difference(lastRun) >= cooldown;
  }

  String _avatarInitial(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed[0].toUpperCase();
  }

  Future<void> _checkDefaultSmsApp({bool refreshIfDefault = true}) async {
    final capability = await SmsService.getCapabilityState();
    final isDefault = capability.isDefault;
    if (!mounted) return;
    setState(() {
      _isDefaultSmsApp = isDefault;
      _checkingDefaultSms = false;
    });
    if (isDefault && refreshIfDefault) {
      await _refreshSmsThreads(force: true);
    }
  }

  Future<void> _primeSmsInboxAfterFirstFrame() async {
    if (_hasPrimedSmsInbox || !mounted) {
      return;
    }
    _hasPrimedSmsInbox = true;
    await _refreshSmsThreads(force: true);
    unawaited(SmsService.scheduleInboxMaintenance());
  }

  Future<void> _bootstrapSmsContactNames() async {
    if (_isBootstrappingSmsContactNames) {
      return;
    }
    _isBootstrappingSmsContactNames = true;
    try {
      final syncedContacts = await _deviceContacts.getSyncedContactsOnce();
      if (mounted && syncedContacts.isNotEmpty) {
        setState(() {
          _syncedContacts = syncedContacts;
          _syncedContactsVersion++;
        });
      }

      final contactsPermission = await Permission.contacts.status;
      if (!mounted) return;
      setState(() {
        _contactsPermissionGranted = contactsPermission.isGranted;
      });
      if (!contactsPermission.isGranted) {
        return;
      }

      final contacts = await _contactsService.getContacts();
      if (!mounted) return;
      setState(() {
        _phoneContacts = contacts
            .where((contact) => contact.phones.isNotEmpty)
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
        _localContactNameByPhoneKey = _buildLocalContactNameMap(_phoneContacts);
        _phoneContactsVersion++;
      });
    } catch (_) {
      // Best-effort bootstrap only. The Contacts tab still offers full refresh/sync.
    } finally {
      _isBootstrappingSmsContactNames = false;
    }
  }

  Map<String, String> _buildLocalContactNameMap(List<Contact> contacts) {
    final directory = <String, String>{};
    for (final contact in contacts) {
      final displayName = contact.displayName.trim();
      if (displayName.isEmpty) continue;
      for (final phone in contact.phones) {
        final phoneKey = DeviceContactSyncService.normalizePhone(phone.number);
        if (phoneKey.isEmpty || directory.containsKey(phoneKey)) continue;
        directory[phoneKey] = displayName;
      }
    }
    return directory;
  }

  Future<void> _syncDeviceContacts({bool force = false}) async {
    if (_isSyncingContacts) return;
    if (!force &&
        !_isRefreshStale(_lastContactsSyncAt, _contactsRefreshCooldown)) {
      return;
    }

    _isSyncingContacts = true;
    final hadContacts = _phoneContacts.isNotEmpty || _syncedContacts.isNotEmpty;
    if (mounted && !hadContacts) {
      setState(() => _loadingContacts = true);
    }

    final contactsPermission = await Permission.contacts.status;
    if (mounted) {
      setState(() {
        _contactsPermissionGranted = contactsPermission.isGranted;
      });
    }

    try {
      final contacts = await _contactsService.getContacts();
      final refreshedPermission = await Permission.contacts.status;
      if (mounted) {
        setState(() {
          _contactsPermissionGranted = refreshedPermission.isGranted;
          _phoneContacts = contacts
              .where((contact) => contact.phones.isNotEmpty)
              .toList()
            ..sort((a, b) => a.displayName.compareTo(b.displayName));
          _localContactNameByPhoneKey =
              _buildLocalContactNameMap(_phoneContacts);
          _phoneContactsVersion++;
          _loadingContacts = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingContacts = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load phone contacts: $e')),
        );
      }
    }

    try {
      await _deviceContacts.syncDeviceContacts();
      final syncedContacts = await _deviceContacts.getSyncedContactsOnce();
      if (!mounted) return;
      setState(() {
        _syncedContacts = syncedContacts;
        _syncedContactsVersion++;
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;
      final message = e.code == 'permission-denied'
          ? 'Cloud contact sync is unavailable right now. Local contacts still work.'
          : 'Cloud contact sync failed: ${e.message ?? e.code}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cloud contact sync failed: $e')),
      );
    } finally {
      _lastContactsSyncAt = DateTime.now();
      _isSyncingContacts = false;
      if (mounted) {
        setState(() => _loadingContacts = false);
      }
    }
  }

  bool _matchesQuery(List<String> values) {
    final query = _contactSearch.trim().toLowerCase();
    if (query.isEmpty) return true;
    return values.any((value) => value.trim().toLowerCase().contains(query));
  }

  String _buildSmsThreadsCacheKey(List<Map<String, dynamic>> rawThreads) {
    final query = _contactSearch.trim().toLowerCase();
    final signature = Object.hashAll(
      rawThreads.map(
        (data) => Object.hash(
          data['threadId'],
          data['sender'],
          data['lastTime'],
          data['unread'],
          data['lastMessage'],
          data['quarantinedCount'],
        ),
      ),
    );
    return '$signature|$query|$_phoneContactsVersion|$_syncedContactsVersion';
  }

  List<Map<String, dynamic>> _resolveSmsThreads(
    List<Map<String, dynamic>> rawThreads,
  ) {
    final cacheKey = _buildSmsThreadsCacheKey(rawThreads);
    if (_smsThreadsCacheKey == cacheKey) {
      return _smsThreadsCache;
    }

    final threads = rawThreads.where((data) {
      final sender = (data['sender'] ?? '').toString();
      final senderLabel = _smsThreadDisplayName(
        sender,
        storedDisplay: data['senderDisplay']?.toString(),
      );
      final lastMessage = (data['lastMessage'] ?? '').toString();
      return _matchesQuery([sender, senderLabel, lastMessage]);
    }).toList(growable: false);

    _smsThreadsCacheKey = cacheKey;
    _smsThreadsCache = threads;
    return threads;
  }

  List<_PhoneContactEntry> _resolveContactEntries() {
    final cacheKey =
        '$_phoneContactsVersion|$_syncedContactsVersion|${_contactSearch.trim().toLowerCase()}';
    if (_contactsEntriesCacheKey == cacheKey) {
      return _contactsEntriesCache;
    }

    final entries = <_PhoneContactEntry>[];
    final seenKeys = <String>{};

    void addEntry({
      required String displayName,
      required String primaryPhone,
      Map<String, dynamic>? matchedMeta,
    }) {
      final cleanPhone = primaryPhone.trim();
      final phoneKey = DeviceContactSyncService.normalizePhone(cleanPhone);
      if (phoneKey.isEmpty || seenKeys.contains(phoneKey)) return;
      if (!_matchesQuery([displayName, cleanPhone])) return;

      seenKeys.add(phoneKey);
      entries.add(
        _PhoneContactEntry(
          displayName: displayName.trim().isNotEmpty
              ? displayName.trim()
              : _displayPhone(cleanPhone),
          primaryPhone: _displayPhone(cleanPhone),
          matchedMeta: matchedMeta,
        ),
      );
    }

    for (final contact in _phoneContacts) {
      final displayName = contact.displayName.trim().isNotEmpty
          ? contact.displayName.trim()
          : 'Unnamed Contact';
      for (final phone in contact.phones) {
        final number = phone.number.trim();
        if (number.isEmpty) continue;
        addEntry(
          displayName: displayName,
          primaryPhone: number,
          matchedMeta: _matchForPhone(number),
        );
      }
    }

    entries.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );

    _contactsEntriesCacheKey = cacheKey;
    _contactsEntriesCache = entries;
    return entries;
  }

  String _normalizeSmsPhone(String raw) {
    final compact = raw.trim().replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (compact.startsWith('+63') && compact.length > 3) {
      return '0${compact.substring(3)}';
    }
    if (compact.startsWith('63') && compact.length > 2) {
      return '0${compact.substring(2)}';
    }
    return compact;
  }

  String _displayPhone(String raw) {
    final normalized = _normalizeSmsPhone(raw);
    return normalized.isEmpty ? raw.trim() : normalized;
  }

  String _smsThreadDisplayName(String raw, {String? storedDisplay}) {
    final stored = storedDisplay?.trim() ?? '';
    if (stored.isNotEmpty) {
      return stored;
    }
    final matched = _matchedLabelForNumber(raw)?.trim() ?? '';
    if (matched.isNotEmpty) {
      return matched;
    }
    return _displayPhone(raw);
  }

  String? _smsThreadSecondaryLabel(String raw) {
    final matched = _matchedLabelForNumber(raw)?.trim() ?? '';
    if (matched.isEmpty) {
      return null;
    }
    final phone = _displayPhone(raw);
    if (phone.isEmpty || phone == matched) {
      return null;
    }
    return phone;
  }

  String? _matchedLabelForNumber(String raw) {
    final match = _matchForPhone(raw);
    final phoneKey = DeviceContactSyncService.normalizePhone(raw);
    if (phoneKey.isEmpty) return null;

    final localDisplayName =
        _localContactNameByPhoneKey[phoneKey]?.trim() ?? '';
    if (localDisplayName.isNotEmpty) {
      return localDisplayName;
    }

    for (final contact in _phoneContacts) {
      for (final phone in contact.phones) {
        if (DeviceContactSyncService.normalizePhone(phone.number) == phoneKey) {
          final displayName = contact.displayName.trim();
          if (displayName.isNotEmpty) {
            return displayName;
          }
        }
      }
    }

    final matchedName = match?['matchedName']?.toString().trim() ?? '';
    if (matchedName.isNotEmpty) {
      return matchedName;
    }

    final syncedDisplayName = match?['displayName']?.toString().trim() ?? '';
    if (syncedDisplayName.isNotEmpty) {
      return syncedDisplayName;
    }

    return null;
  }

  bool _canOfferAddToContacts(String raw) {
    final phone = raw.trim();
    if (phone.isEmpty) return false;
    final matched = _matchedLabelForNumber(phone);
    if (matched == null || matched.isEmpty) return true;
    return DeviceContactSyncService.normalizePhone(matched) ==
        DeviceContactSyncService.normalizePhone(phone);
  }

  void _openSmsChat({
    required String name,
    required String phone,
  }) {
    final smsPhone = _normalizeSmsPhone(phone);
    final displayName =
        name.trim() == phone.trim() ? _displayPhone(phone) : name.trim();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactName: displayName,
          phone: smsPhone,
          chatType: 'sms',
        ),
      ),
    );
  }

  Future<void> _openAddContact(String phone, {String? name}) async {
    await SmsService.openAddContact(phone: phone, name: name ?? phone);
  }

  Future<void> _showNewSmsNumberDialog() async {
    final controller = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'Message new number',
            style: TextStyle(color: Colors.white),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Enter phone number',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1A1A1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                final phone = controller.text.trim();
                if (phone.isEmpty) {
                  Navigator.pop(dialogContext);
                  return;
                }
                final name = _matchedLabelForNumber(phone) ?? phone;
                Navigator.pop(dialogContext);
                _openSmsChat(name: name, phone: phone);
              },
              child: const Text('Open chat'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showNewSmsContactPicker() async {
    if (!_isDefaultSmsApp) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Set Smishing Shield PH as the default SMS app to start new SMS conversations.',
          ),
        ),
      );
      return;
    }

    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contacts permission is required.')),
      );
      return;
    }

    final contacts = await FlutterContacts.getContacts(withProperties: true);
    if (!mounted) return;

    final smsContacts = contacts
        .where((contact) => contact.phones.isNotEmpty)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.72,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Start new SMS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    key: const PageStorageKey<String>('phone_new_sms_picker'),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: smsContacts.length + 1,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: const BoxDecoration(
                              color: Color(0xFF25D366),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.dialpad_rounded,
                              color: Colors.white,
                            ),
                          ),
                          title: const Text(
                            'New number',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: const Text(
                            'Type any phone number to start an SMS',
                            style: TextStyle(color: Colors.white54),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _showNewSmsNumberDialog();
                          },
                        );
                      }

                      final contact = smsContacts[index - 1];
                      final displayName = contact.displayName.trim().isEmpty
                          ? 'Unnamed Contact'
                          : contact.displayName.trim();
                      final primaryPhone = contact.phones.first.number.trim();

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF2B2B2B),
                          child: Text(
                            _avatarInitial(displayName),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(
                          displayName,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          _displayPhone(primaryPhone),
                          style: const TextStyle(color: Colors.white54),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _openSmsChat(name: displayName, phone: primaryPhone);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSystemDialer(String phone) async {
    await SmsService.openDialer(phone);
  }

  Map<String, dynamic>? _matchForPhone(String phone) {
    final phoneKey = DeviceContactSyncService.normalizePhone(phone);
    if (phoneKey.isEmpty) return null;

    for (final entry in _syncedContacts) {
      final entryKey = entry['phoneMatchKey']?.toString() ?? '';
      final matchesAllPhones =
          ((entry['allPhones'] as List<dynamic>?) ?? const [])
              .map((e) => DeviceContactSyncService.normalizePhone(e.toString()))
              .any((value) => value == phoneKey);

      if (entryKey == phoneKey || matchesAllPhones) {
        return entry;
      }
    }

    return null;
  }

  Future<void> _startCarrierCall(String phone) async {
    try {
      await _openSystemDialer(phone);
      return;
    } catch (_) {}

    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open phone dialer.')),
    );
  }

  Future<void> _refreshSmsThreads({
    bool force = false,
    bool hardRefresh = false,
  }) async {
    if (_isRefreshingSms) return;
    if (!force && !_isRefreshStale(_lastSmsRefreshAt, _smsRefreshCooldown)) {
      return;
    }

    final generation = ++_smsRefreshGeneration;
    if (mounted) {
      setState(() => _isRefreshingSms = true);
    } else {
      _isRefreshingSms = true;
    }
    try {
      await _checkDefaultSmsApp(refreshIfDefault: false);
      if (hardRefresh) {
        await SmsService.refreshInbox(forceFullHistory: _isDefaultSmsApp);
      } else {
        await SmsService.primeInboxThreads(force: force);
        unawaited(SmsService.scheduleInboxMaintenance(force: force));
      }
      _lastSmsRefreshAt = DateTime.now();
    } finally {
      if (!mounted || generation != _smsRefreshGeneration) {
        _isRefreshingSms = false;
      } else {
        setState(() => _isRefreshingSms = false);
      }
    }
  }

  void _toggleSmsEditMode() {
    setState(() {
      _isEditingSms = !_isEditingSms;
      if (!_isEditingSms) {
        _selectedSmsThreadIds.clear();
      }
    });
  }

  void _toggleSmsThreadSelection(String threadId) {
    setState(() {
      if (_selectedSmsThreadIds.contains(threadId)) {
        _selectedSmsThreadIds.remove(threadId);
      } else {
        _selectedSmsThreadIds.add(threadId);
      }
    });
  }

  Future<void> _markSelectedThreadsAsRead() async {
    if (_selectedSmsThreadIds.isEmpty) return;
    await _storage.markThreadsAsRead(_selectedSmsThreadIds);
    if (!mounted) return;
    setState(() {
      _selectedSmsThreadIds.clear();
      _isEditingSms = false;
    });
  }

  Future<void> _deleteSelectedThreads() async {
    if (_selectedSmsThreadIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete selected SMS threads?'),
            content: Text(
              'This will remove ${_selectedSmsThreadIds.length} selected SMS ${_selectedSmsThreadIds.length == 1 ? 'thread' : 'threads'} from your app only.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    for (final threadId in _selectedSmsThreadIds.toList()) {
      await _storage.deleteThreadForMe(threadId);
    }
    if (!mounted) return;
    setState(() {
      _selectedSmsThreadIds.clear();
      _isEditingSms = false;
    });
  }

  Future<void> _handleSmsMenuAction(String value) async {
    switch (value) {
      case 'toggle_edit_sms':
        if (_tabController.index == 0) {
          _toggleSmsEditMode();
        }
        break;
      case 'refresh_sms':
        await _refreshSmsThreads(force: true, hardRefresh: true);
        break;
      case 'rescan_sms':
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rescanning stored SMS...')),
        );
        final summary =
            await SmsService.rescanStoredMessagesWithCurrentPipeline();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_formatSmsRescanSummary(summary))),
        );
        break;
      case 'set_default_sms':
        await SmsService.requestDefaultSmsApp();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await _checkDefaultSmsApp();
        break;
      case 'quarantine':
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const QuarantineScreen()),
        );
        break;
      case 'sync_contacts':
        await _syncDeviceContacts();
        break;
    }
  }

  DateTime? _coerceDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  String _formatThreadDate(dynamic timestamp) {
    final dt = _coerceDateTime(timestamp);
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}/${dt.year.toString().substring(2)}';
  }

  String _formatSmsRescanSummary(SmsRescanSummary summary) {
    final seconds = summary.elapsed.inMilliseconds / 1000;
    return 'Rescanned ${summary.totalRescanned} SMS in ${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s. '
        '${summary.movedToQuarantine} moved to quarantine, '
        '${summary.restoredToInbox} restored to inbox'
        '${summary.errors > 0 ? ', ${summary.errors} errors' : ''}.';
  }

  void _showContactActions({
    required String name,
    required String phone,
  }) {
    final smsPhone = _normalizeSmsPhone(phone);
    final visiblePhone = _displayPhone(phone);
    final canAddToContacts = _canOfferAddToContacts(phone);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  visiblePhone,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 18),
                _buildBottomActionTile(
                  icon: Icons.call_outlined,
                  label: 'Call',
                  onTap: () {
                    Navigator.pop(context);
                    _startCarrierCall(phone);
                  },
                ),
                _buildBottomActionTile(
                  icon: Icons.sms_outlined,
                  label: 'Text message',
                  onTap: () {
                    Navigator.pop(context);
                    _openSmsChat(name: name, phone: smsPhone);
                  },
                ),
                if (canAddToContacts)
                  _buildBottomActionTile(
                    icon: Icons.person_add_alt_1_outlined,
                    label: 'Add to contacts',
                    onTap: () {
                      Navigator.pop(context);
                      _openAddContact(visiblePhone, name: name);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSmsThreadActions({
    required String threadId,
    required String sender,
    required String lastMessage,
    String? storedDisplay,
  }) {
    final senderLabel = _smsThreadDisplayName(sender, storedDisplay: storedDisplay);
    final senderPhoneLabel = _smsThreadSecondaryLabel(sender);
    final canAddToContacts = _canOfferAddToContacts(sender);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  senderLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (senderPhoneLabel != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    senderPhoneLabel,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                    ),
                  ),
                ],
                if (lastMessage.trim().isNotEmpty) ...[
                  SizedBox(height: senderPhoneLabel != null ? 10 : 6),
                  Text(
                    lastMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                _buildBottomActionTile(
                  icon: Icons.chat_bubble_outline,
                  label: 'Open conversation',
                  onTap: () {
                    Navigator.pop(context);
                    _openSmsChat(name: senderLabel, phone: sender);
                  },
                ),
                if (canAddToContacts)
                  _buildBottomActionTile(
                    icon: Icons.person_add_alt_1_outlined,
                    label: 'Add to contacts',
                    onTap: () {
                      Navigator.pop(context);
                      _openAddContact(sender, name: senderLabel);
                    },
                  ),
                _buildBottomActionTile(
                  icon: Icons.done_all_outlined,
                  label: 'Select thread',
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      _isEditingSms = true;
                      _selectedSmsThreadIds.add(threadId);
                    });
                  },
                ),
                _buildBottomActionTile(
                  icon: Icons.info_outline,
                  label: 'Thread actions',
                  onTap: () {
                    Navigator.pop(context);
                    _showContactActions(name: senderLabel, phone: sender);
                  },
                ),
                _buildBottomActionTile(
                  icon: Icons.delete_outline,
                  label: 'Delete chat',
                  onTap: () async {
                    Navigator.pop(context);
                    final confirmed = await showDialog<bool>(
                          context: this.context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Delete SMS chat?'),
                            content: Text(
                              'Remove the whole conversation with $sender from this app?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red,
                                ),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ) ??
                        false;

                    if (!confirmed) return;
                    await _storage.deleteThreadForMe(threadId);
                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      SnackBar(content: Text('Deleted SMS chat with $sender')),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: Colors.white),
      title: Text(
        label,
        style: const TextStyle(color: Colors.white),
      ),
      onTap: onTap,
    );
  }

  Widget _buildDefaultSmsBanner() {
    if (_checkingDefaultSms || _isDefaultSmsApp) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF8E5BFF).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.sms_outlined, color: Color(0xFF8E5BFF)),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Smishing Shield PH is in limited SMS mode. Set it as the default SMS app to receive, send, and sync SMS directly inside the app.',
              style: TextStyle(color: _textPrimary, fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8E5BFF),
            ),
            onPressed: () async {
              await SmsService.requestDefaultSmsApp();
              await Future<void>.delayed(const Duration(milliseconds: 900));
              final isDefaultNow = await SmsService.isDefaultSmsApp();
              if (!isDefaultNow) {
                await SmsService.openDefaultSmsSettings();
              }
              await _refreshSmsThreads(force: true);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  Widget _buildTopSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Messaging',
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _tabController.index == 0
                      ? _isDefaultSmsApp
                          ? 'Default SMS inbox with quarantine and thread controls.'
                          : 'Read-only SMS history until this app becomes the default SMS app.'
                      : 'People from your device contact list.',
                  style: const TextStyle(
                    color: _textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            color: _surfaceElevatedColor,
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: _handleSmsMenuAction,
            itemBuilder: (context) => [
              if (_tabController.index == 0)
                PopupMenuItem(
                  value: 'toggle_edit_sms',
                  child: Text(
                    _isEditingSms ? 'Done editing' : 'Edit threads',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              const PopupMenuItem(
                value: 'refresh_sms',
                child:
                    Text('Refresh SMS', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: 'rescan_sms',
                child: Text(
                  'Rescan saved SMS',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const PopupMenuItem(
                value: 'set_default_sms',
                child: Text(
                  'Set as default SMS app',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const PopupMenuItem(
                value: 'quarantine',
                child: Text(
                  'Open Quarantine Vault',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const PopupMenuItem(
                value: 'sync_contacts',
                child: Text(
                  'Refresh Contacts',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSmsInboxTab() {
    return RefreshIndicator(
      onRefresh: () => _refreshSmsThreads(force: true, hardRefresh: true),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _storage.watchThreads(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final threads = _resolveSmsThreads(snapshot.data!);

          if (threads.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 180),
                Icon(Icons.sms_outlined, size: 54, color: Colors.white24),
                SizedBox(height: 14),
                Text(
                  'No offline SMS messages yet.',
                  style: TextStyle(color: Colors.white54, fontSize: 15),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    'Received SMS messages will appear here. Pull down to refresh if Android delays delivery.',
                    style: TextStyle(color: Colors.white38, fontSize: 12.5),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            );
          }

          return Column(
            children: [
              if (_isEditingSms)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: _surfaceColor,
                  child: Row(
                    children: [
                      Text(
                        '${_selectedSmsThreadIds.length} selected',
                        style: const TextStyle(
                          color: _textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _selectedSmsThreadIds.isEmpty
                            ? null
                            : _markSelectedThreadsAsRead,
                        icon: const Icon(Icons.mark_email_read_outlined),
                        label: const Text('Mark read'),
                      ),
                      TextButton.icon(
                        onPressed: _selectedSmsThreadIds.isEmpty
                            ? null
                            : _deleteSelectedThreads,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  key: const PageStorageKey<String>('phone_sms_inbox'),
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  cacheExtent: 800,
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                  itemCount: threads.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final data = threads[index];
                    final threadId = data['threadId']?.toString() ??
                        _storage.threadIdForPeer(
                          data['sender']?.toString() ?? '',
                        );
                    final sender = (data['sender'] ?? 'Unknown').toString();
                    final storedDisplay = data['senderDisplay']?.toString();
                    final senderLabel = _smsThreadDisplayName(
                      sender,
                      storedDisplay: storedDisplay,
                    );
                    final senderPhoneLabel = _smsThreadSecondaryLabel(sender);
                    final lastMessage = (data['lastMessage'] ?? '').toString();
                    final lastTime = data['lastTime'];
                    final unread = (data['unread'] as num?)?.toInt() ?? 0;
                    final quarantinedCount =
                        (data['quarantinedCount'] as num?)?.toInt() ?? 0;
                    final hasQuarantine = quarantinedCount > 0;
                    final lastIsQuarantined =
                        data['lastMessageIsQuarantined'] == true;
                    final isSelected = _selectedSmsThreadIds.contains(threadId);

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          if (_isEditingSms) {
                            _toggleSmsThreadSelection(threadId);
                            return;
                          }
                          _openSmsChat(
                            name: senderLabel,
                            phone: sender,
                          );
                        },
                        onLongPress: () {
                          if (_isEditingSms) {
                            _toggleSmsThreadSelection(threadId);
                            return;
                          }
                          _showSmsThreadActions(
                            threadId: threadId,
                            sender: sender,
                            lastMessage: lastMessage,
                            storedDisplay: storedDisplay,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? _surfaceElevatedColor
                                : _surfaceColor,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF8E5BFF)
                                  : Colors.white10,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x22000000),
                                blurRadius: 14,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              _isEditingSms
                                  ? Checkbox(
                                      value: isSelected,
                                      onChanged: (_) =>
                                          _toggleSmsThreadSelection(threadId),
                                      activeColor: const Color(0xFF8E5BFF),
                                    )
                                  : CircleAvatar(
                                      radius: 26,
                                      backgroundColor: hasQuarantine
                                          ? const Color(0xFFFF6B81)
                                              .withValues(alpha: 0.22)
                                          : Colors.white10,
                                      child: Icon(
                                        hasQuarantine
                                            ? Icons.warning_amber_rounded
                                            : Icons.sms_outlined,
                                        color: Colors.white,
                                      ),
                                    ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      senderLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 17,
                                      ),
                                    ),
                                    if (senderPhoneLabel != null) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        senderPhoneLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: _textMuted,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    Text(
                                      lastMessage.isEmpty
                                          ? 'No messages yet'
                                          : lastMessage,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: lastIsQuarantined
                                            ? _warningColor
                                            : _textMuted,
                                      ),
                                    ),
                                    if (hasQuarantine)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 5),
                                        child: Text(
                                          '$quarantinedCount suspicious ${quarantinedCount == 1 ? 'message is' : 'messages are'} in quarantine',
                                          style: const TextStyle(
                                            color: _warningColor,
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    _formatThreadDate(lastTime),
                                    style: const TextStyle(
                                      color: _textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (hasQuarantine)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(right: 6),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _warningColor.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            'Q$quarantinedCount',
                                            style: const TextStyle(
                                              color: _warningColor,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      if (unread > 0)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 9,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _accentColor,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            unread.toString(),
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContactsTab() {
    if (_loadingContacts && _phoneContacts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final entries = _resolveContactEntries();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: TextField(
            controller: _contactSearchController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search contacts',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              suffixIcon: _contactSearch.trim().isNotEmpty
                  ? IconButton(
                      onPressed: () {
                        _contactSearchDebounceTimer?.cancel();
                        _contactSearchController.clear();
                        setState(() => _contactSearch = '');
                      },
                      icon: const Icon(Icons.close, color: Colors.white54),
                    )
                  : IconButton(
                      onPressed: _syncDeviceContacts,
                      icon: const Icon(Icons.refresh, color: Colors.white54),
                    ),
              filled: true,
              fillColor: const Color(0xFF161616),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? RefreshIndicator(
                  onRefresh: _syncDeviceContacts,
                  child: ListView(
                    key: const PageStorageKey<String>('phone_contacts_empty'),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    children: [
                      const SizedBox(height: 160),
                      Icon(
                        _contactsPermissionGranted
                            ? Icons.contact_phone_outlined
                            : Icons.lock_outline,
                        size: 52,
                        color: Colors.white24,
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          _contactsPermissionGranted
                              ? 'No phone contacts found.'
                              : 'Contacts permission is not enabled.',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Text(
                          _contactsPermissionGranted
                              ? 'Only contacts saved in your device contact list are shown here.'
                              : 'Enable Contacts permission so the app can read your phone book.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF8E5BFF),
                          ),
                          onPressed: () async {
                            if (_contactsPermissionGranted) {
                              await _syncDeviceContacts();
                            } else {
                              await openAppSettings();
                            }
                          },
                          child: Text(
                            _contactsPermissionGranted
                                ? 'Refresh Contacts'
                                : 'Open Settings',
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _syncDeviceContacts,
                  child: ListView.separated(
                    key: const PageStorageKey<String>('phone_contacts_list'),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    cacheExtent: 900,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final displayName = entry.displayName;
                      final primaryPhone = entry.primaryPhone;
                      final matchedMeta = entry.matchedMeta;

                      final matchedName =
                          matchedMeta?['matchedName']?.toString().trim() ?? '';
                      final isRegistered = matchedMeta?['isRegistered'] == true;

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF2B2B2B),
                          child: Text(
                            _avatarInitial(displayName),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(
                          displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              primaryPhone.isNotEmpty
                                  ? _displayPhone(primaryPhone)
                                  : 'No phone number saved',
                              style: const TextStyle(color: Colors.white54),
                            ),
                            if (isRegistered && matchedName.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'Matched app user: $matchedName',
                                  style: const TextStyle(
                                    color: Color(0xFF25D366),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'SMS',
                              onPressed: primaryPhone.isEmpty
                                  ? null
                                  : () => _openSmsChat(
                                        name: displayName,
                                        phone: primaryPhone,
                                      ),
                              icon: const Icon(
                                Icons.sms_outlined,
                                color: Colors.white70,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Call',
                              onPressed: primaryPhone.isEmpty
                                  ? null
                                  : () => _startCarrierCall(primaryPhone),
                              icon: const Icon(
                                Icons.call_outlined,
                                color: Colors.white,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Info',
                              onPressed: primaryPhone.isEmpty
                                  ? null
                                  : () => _showContactActions(
                                        name: displayName,
                                        phone: primaryPhone,
                                      ),
                              icon: const Icon(
                                Icons.info_outline,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                        onTap: primaryPhone.isEmpty
                            ? null
                            : () => _openSmsChat(
                                  name: displayName,
                                  phone: primaryPhone,
                                ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bgColor,
        floatingActionButton: _tabController.index == 0
            ? (_isDefaultSmsApp
                ? FloatingActionButton(
                    backgroundColor: _accentColor,
                    onPressed: _showNewSmsContactPicker,
                    child: const Icon(Icons.chat, color: Colors.white),
                  )
                : null)
            : null,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopSection(),
              _buildDefaultSmsBanner(),
              TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFF8E5BFF),
                indicatorWeight: 3,
                labelColor: Colors.white,
                unselectedLabelColor: _textMuted,
                labelStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                tabs: const [
                  Tab(text: 'SMS'),
                  Tab(text: 'Contacts'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  physics: const ClampingScrollPhysics(),
                  children: [
                    RepaintBoundary(child: _buildSmsInboxTab()),
                    RepaintBoundary(child: _buildContactsTab()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhoneContactEntry {
  final String displayName;
  final String primaryPhone;
  final Map<String, dynamic>? matchedMeta;

  const _PhoneContactEntry({
    required this.displayName,
    required this.primaryPhone,
    this.matchedMeta,
  });
}
