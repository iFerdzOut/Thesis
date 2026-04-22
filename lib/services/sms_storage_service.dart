import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/safety_status.dart';

class SmsMessage {
  const SmsMessage({
    required this.sender,
    required this.body,
    required this.time,
    this.receiver,
    this.isSuspicious = false,
    this.simSlot = 0,
    this.isOutgoing = false,
    this.status,
    this.source,
    this.riskScore,
    this.riskLevel,
    this.detectionReasons = const <String>[],
    this.modelScore,
    this.heuristicScore,
    this.detectionSource,
    this.pipelineStage,
    this.providerId,
    this.providerThreadId,
    this.messageKey,
    this.detectionDecision,
    this.extractedUrls = const <String>[],
    this.primaryUrl,
    this.primaryDomain,
    this.needsRescan = false,
    this.safetyStatus = SafetyStatus.safe,
  });

  final String sender;
  final String body;
  final DateTime time;
  final String? receiver;
  final bool isSuspicious;
  final int simSlot;
  final bool isOutgoing;
  final String? status;
  final String? source;
  final double? riskScore;
  final String? riskLevel;
  final List<String> detectionReasons;
  final double? modelScore;
  final double? heuristicScore;
  final String? detectionSource;
  final String? pipelineStage;
  final int? providerId;
  final String? providerThreadId;
  final String? messageKey;
  final String? detectionDecision;
  final List<String> extractedUrls;
  final String? primaryUrl;
  final String? primaryDomain;
  final bool needsRescan;
  final SafetyStatus safetyStatus;
}

class SmsSyncCursor {
  const SmsSyncCursor({
    this.latestTimestampMs = 0,
    this.latestProviderId = 0,
    this.lastPrimeAtMs = 0,
    this.lastMaintenanceAtMs = 0,
  });

  final int latestTimestampMs;
  final int latestProviderId;
  final int lastPrimeAtMs;
  final int lastMaintenanceAtMs;
}

class SmsStorageService {
  SmsStorageService._internal();

  static final SmsStorageService _instance = SmsStorageService._internal();
  factory SmsStorageService() => _instance;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _dbPasswordKey = 'sms_projection_db_password_v1';
  static const String _migrationFlagKey = 'sms_storage_sql_migrated_v1';
  static const String _legacyThreadsKey = 'sms_local_threads_v2';
  static const String _legacyMessagesKey = 'sms_local_messages_v2';
  static const String _legacyQuarantineKey = 'sms_local_quarantine_v2';
  static const String _legacyHiddenThreadsKey = 'sms_hidden_threads_v1';
  static const int _schemaVersion = 2;

  Database? _database;
  Future<Database>? _databaseFuture;
  bool _memoryMode = false;
  bool _initialized = false;
  Future<void>? _initializeFuture;

  final StreamController<List<Map<String, dynamic>>> _threadsController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final StreamController<List<Map<String, dynamic>>> _quarantineController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final Map<String, StreamController<List<Map<String, dynamic>>>>
      _messageControllers =
      <String, StreamController<List<Map<String, dynamic>>>>{};

  final Map<String, String?> _providerThreadIdCache = <String, String?>{};

  final Map<String, Map<String, dynamic>> _memoryThreads =
      <String, Map<String, dynamic>>{};
  final Map<String, List<Map<String, dynamic>>> _memoryMessages =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, Map<String, dynamic>> _memoryQuarantine =
      <String, Map<String, dynamic>>{};
  SmsSyncCursor _memoryCursor = const SmsSyncCursor();

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    final inFlight = _initializeFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = () async {
      await _maybeOpenDatabase();
      await _migrateLegacyDataIfNeeded();
      _initialized = true;
      await _emitLocalState();
    }();
    _initializeFuture = future;
    try {
      await future;
    } finally {
      if (identical(_initializeFuture, future)) {
        _initializeFuture = null;
      }
    }
  }

  Future<Database> _openDatabase() async {
    if (_database != null) {
      return _database!;
    }
    final inFlight = _databaseFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = () async {
      Directory directory;
      try {
        directory = await getApplicationDocumentsDirectory();
      } catch (_) {
        directory = Directory.systemTemp.createTempSync('sms_projection_cache');
      }
      final dbPath = p.join(directory.path, 'smishing_sms_projection.db');
      final password = await _getDatabasePassword();
      final database = await openDatabase(
        dbPath,
        password: password,
        version: _schemaVersion,
        onCreate: (Database db, int version) async {
          await _createSchema(db);
        },
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          await _upgradeSchema(db, oldVersion, newVersion);
        },
      );
      _database = database;
      return database;
    }();

    _databaseFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_databaseFuture, future)) {
        _databaseFuture = null;
      }
    }
  }

  Future<Database?> _maybeOpenDatabase() async {
    if (_memoryMode) {
      return null;
    }
    try {
      return await _openDatabase();
    } catch (error) {
      _memoryMode = true;
      debugPrint('[SmsStorageService] Falling back to memory mode: $error');
      return null;
    }
  }

  Future<String> _getDatabasePassword() async {
    try {
      final existing = await _secureStorage.read(key: _dbPasswordKey);
      if (existing != null && existing.isNotEmpty) {
        return existing;
      }
    } catch (_) {}

    final random = Random.secure();
    final bytes = List<int>.generate(48, (_) => random.nextInt(256));
    final password = base64UrlEncode(bytes);
    try {
      await _secureStorage.write(key: _dbPasswordKey, value: password);
    } catch (_) {
      return 'sms_projection_test_password_v1';
    }
    return password;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE sms_threads (
        thread_id TEXT PRIMARY KEY,
        provider_thread_id TEXT,
        sender TEXT NOT NULL,
        sender_display TEXT,
        phone TEXT,
        last_message TEXT,
        last_time TEXT,
        last_timestamp_ms INTEGER NOT NULL DEFAULT 0,
        last_direction TEXT,
        last_message_is_quarantined INTEGER NOT NULL DEFAULT 0,
        last_message_is_suspicious INTEGER NOT NULL DEFAULT 0,
        last_sim_slot INTEGER NOT NULL DEFAULT 0,
        visible_message_count INTEGER NOT NULL DEFAULT 0,
        unread INTEGER NOT NULL DEFAULT 0,
        has_suspicious INTEGER NOT NULL DEFAULT 0,
        quarantined_count INTEGER NOT NULL DEFAULT 0,
        hidden_at_ms INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE sms_messages (
        message_id TEXT PRIMARY KEY,
        provider_id INTEGER,
        provider_thread_id TEXT,
        thread_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        receiver TEXT,
        peer TEXT NOT NULL,
        body TEXT,
        text TEXT,
        time TEXT,
        timestamp TEXT,
        timestamp_ms INTEGER NOT NULL,
        is_suspicious INTEGER NOT NULL DEFAULT 0,
        sim_slot INTEGER NOT NULL DEFAULT 0,
        is_outgoing INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        source TEXT NOT NULL,
        risk_score REAL NOT NULL DEFAULT 0,
        risk_level TEXT NOT NULL DEFAULT 'safe',
        detection_reasons_json TEXT NOT NULL DEFAULT '[]',
        model_score REAL,
        heuristic_score REAL NOT NULL DEFAULT 0,
        detection_source TEXT NOT NULL DEFAULT 'provider_sync',
        pipeline_stage TEXT NOT NULL DEFAULT 'provider_sync',
        message_key TEXT,
        detection_decision TEXT,
        extracted_urls_json TEXT NOT NULL DEFAULT '[]',
        primary_url TEXT,
        primary_domain TEXT,
        needs_rescan INTEGER NOT NULL DEFAULT 0,
        safety_status TEXT NOT NULL DEFAULT 'safe',
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE sms_quarantine (
        id TEXT PRIMARY KEY,
        sender TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        message TEXT NOT NULL,
        source TEXT NOT NULL,
        restore_mode TEXT,
        sim_slot INTEGER,
        provider_id INTEGER,
        provider_thread_id TEXT,
        message_key TEXT,
        detection_decision TEXT,
        extracted_urls_json TEXT NOT NULL DEFAULT '[]',
        primary_url TEXT,
        primary_domain TEXT,
        needs_rescan INTEGER NOT NULL DEFAULT 0,
        safety_status TEXT NOT NULL DEFAULT 'malicious',
        time TEXT,
        timestamp TEXT,
        timestamp_ms INTEGER NOT NULL,
        is_suspicious INTEGER NOT NULL DEFAULT 1,
        risk_score REAL NOT NULL DEFAULT 0,
        risk_level TEXT NOT NULL DEFAULT 'warning',
        detection_reasons_json TEXT NOT NULL DEFAULT '[]',
        model_score REAL,
        heuristic_score REAL NOT NULL DEFAULT 0,
        detection_source TEXT,
        pipeline_stage TEXT,
        quarantine_reason TEXT,
        reported_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE sms_sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_sms_messages_provider_id
      ON sms_messages(provider_id)
      WHERE provider_id IS NOT NULL
    ''');
    await db.execute('''
      CREATE INDEX idx_sms_messages_thread_timestamp
      ON sms_messages(thread_id, timestamp_ms DESC)
    ''');
    await db.execute('''
      CREATE INDEX idx_sms_quarantine_thread_timestamp
      ON sms_quarantine(thread_id, timestamp_ms DESC)
    ''');
    await db.execute('''
      CREATE INDEX idx_sms_threads_last_timestamp
      ON sms_threads(last_timestamp_ms DESC)
    ''');
  }

  Future<void> _upgradeSchema(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE sms_messages ADD COLUMN safety_status TEXT NOT NULL DEFAULT 'safe'",
      );
      await db.execute(
        "ALTER TABLE sms_quarantine ADD COLUMN safety_status TEXT NOT NULL DEFAULT 'malicious'",
      );
      await db.execute(
        "UPDATE sms_messages SET safety_status = CASE WHEN is_suspicious = 1 THEN 'malicious' ELSE 'safe' END",
      );
      await db.execute(
        "UPDATE sms_quarantine SET safety_status = 'malicious'",
      );
    }
  }

  Future<void> _migrateLegacyDataIfNeeded() async {
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }

    if (prefs.getBool(_migrationFlagKey) == true) {
      return;
    }

    final String? rawThreads = prefs.getString(_legacyThreadsKey);
    final String? rawMessages = prefs.getString(_legacyMessagesKey);
    final String? rawQuarantine = prefs.getString(_legacyQuarantineKey);
    final String? rawHiddenThreads = prefs.getString(_legacyHiddenThreadsKey);

    if ((rawThreads == null || rawThreads.isEmpty) &&
        (rawMessages == null || rawMessages.isEmpty) &&
        (rawQuarantine == null || rawQuarantine.isEmpty)) {
      await prefs.setBool(_migrationFlagKey, true);
      return;
    }

    final threads = _decodeLegacyThreadEntries(rawThreads);
    final messages = _decodeLegacyMessageEntries(rawMessages);
    final quarantine = _decodeLegacyQuarantineEntries(rawQuarantine);
    final hiddenThreadIds = _decodeLegacyHiddenThreads(rawHiddenThreads);

    if (_memoryMode) {
      for (final thread in threads) {
        final threadId = thread['threadId']?.toString();
        if (threadId == null || threadId.isEmpty) {
          continue;
        }
        final merged = Map<String, dynamic>.from(thread);
        if (hiddenThreadIds.contains(threadId)) {
          merged['hiddenAtMs'] = DateTime.now().millisecondsSinceEpoch;
        }
        _memoryThreads[threadId] = merged;
      }
      for (final entry in messages.entries) {
        _memoryMessages[entry.key] = entry.value;
      }
      for (final entry in quarantine) {
        final id = entry['id']?.toString();
        if (id == null || id.isEmpty) {
          continue;
        }
        _memoryQuarantine[id] = entry;
      }
    } else {
      final db = await _maybeOpenDatabase();
      if (db != null) {
        await db.transaction((Transaction txn) async {
          for (final thread in threads) {
            final threadId = thread['threadId']?.toString();
            if (threadId == null || threadId.isEmpty) {
              continue;
            }
            await txn.insert(
              'sms_threads',
              <String, Object?>{
                'thread_id': threadId,
                'provider_thread_id': thread['providerThreadId']?.toString(),
                'sender': thread['sender']?.toString() ?? threadId,
                'sender_display': thread['senderDisplay']?.toString(),
                'phone': thread['phone']?.toString() ??
                    thread['sender']?.toString() ??
                    threadId,
                'last_message': thread['lastMessage']?.toString() ?? '',
                'last_time': thread['lastTime']?.toString(),
                'last_timestamp_ms': _coerceInt(thread['lastTimestampMs']) ??
                    _parseTimestampMs(thread['lastTime']) ??
                    0,
                'last_direction': thread['lastDirection']?.toString(),
                'last_message_is_quarantined':
                    thread['lastMessageIsQuarantined'] == true ? 1 : 0,
                'last_message_is_suspicious':
                    thread['lastMessageIsSuspicious'] == true ? 1 : 0,
                'last_sim_slot': _coerceInt(thread['lastSimSlot']) ?? 0,
                'visible_message_count':
                    _coerceInt(thread['visibleMessageCount']) ?? 0,
                'unread': _coerceInt(thread['unread']) ?? 0,
                'has_suspicious': thread['hasSuspicious'] == true ? 1 : 0,
                'quarantined_count':
                    _coerceInt(thread['quarantinedCount']) ?? 0,
                'hidden_at_ms': hiddenThreadIds.contains(threadId)
                    ? DateTime.now().millisecondsSinceEpoch
                    : (_coerceInt(thread['hiddenAtMs']) ?? 0),
                'updated_at': DateTime.now().millisecondsSinceEpoch,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          for (final entry in messages.entries) {
            for (final message in entry.value) {
              await txn.insert(
                'sms_messages',
                _messageRowFromMap(entry.key, message),
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
            await _recomputeThreadSummary(txn, entry.key);
          }
          for (final entry in quarantine) {
            await txn.insert(
              'sms_quarantine',
              _quarantineRowFromMap(entry),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            await _recomputeThreadSummary(
              txn,
              entry['threadId']?.toString() ??
                  threadIdForPeer(entry['sender']?.toString() ?? ''),
            );
          }
        });
      }
    }

    await prefs.setBool(_migrationFlagKey, true);
    await prefs.remove(_legacyThreadsKey);
    await prefs.remove(_legacyMessagesKey);
    await prefs.remove(_legacyQuarantineKey);
    await prefs.remove(_legacyHiddenThreadsKey);
  }

  String threadIdForPeer(String peer) => _normalizePhone(peer);

  String? cachedProviderThreadIdForPeer(String peer) {
    return _providerThreadIdCache[threadIdForPeer(peer)];
  }

  Stream<List<Map<String, dynamic>>> watchThreads() {
    unawaited(initialize());
    unawaited(_emitThreads());
    return _threadsController.stream;
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String peer) {
    final threadId = threadIdForPeer(peer);
    final controller = _messageControllers.putIfAbsent(
      threadId,
      () => StreamController<List<Map<String, dynamic>>>.broadcast(),
    );
    unawaited(initialize());
    unawaited(_emitMessagesForThread(threadId));
    return controller.stream;
  }

  Stream<List<Map<String, dynamic>>> watchQuarantineMessages() {
    unawaited(initialize());
    unawaited(_emitQuarantine());
    return _quarantineController.stream;
  }

  Future<List<Map<String, dynamic>>> listAllVisibleMessages() async {
    await initialize();
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final rows = _memoryMessages.values
          .expand((List<Map<String, dynamic>> entries) => entries)
          .map((Map<String, dynamic> row) => Map<String, dynamic>.from(row))
          .toList(growable: true)
        ..sort(
          (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
              .compareTo(_coerceInt(b['timestampMs']) ?? 0),
        );
      return rows;
    }
    final rows = await db.query(
      'sms_messages',
      orderBy: 'timestamp_ms ASC, provider_id ASC',
    );
    return rows
        .map((row) => _messageDisplayMapFromRow(row))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> listAllQuarantineMessages() async {
    await initialize();
    return _loadQuarantineEntries();
  }

  Future<void> saveMessage(SmsMessage message) async {
    await initialize();
    final peerForThread = message.isOutgoing
        ? ((message.receiver?.trim().isNotEmpty ?? false)
            ? message.receiver!.trim()
            : message.sender)
        : message.sender;
    final threadId = threadIdForPeer(peerForThread);
    final row = _messageRowFromSmsMessage(
      threadId: threadId,
      messageId: _buildLocalMessageId(message),
      message: message,
      peer: peerForThread,
      isOutgoing: message.isOutgoing,
      status: message.status ?? (message.isOutgoing ? 'sending' : 'received'),
      source: message.source ?? 'local_projection',
    );

    final db = await _maybeOpenDatabase();
    if (db == null) {
      final list = List<Map<String, dynamic>>.from(
        _memoryMessages[threadId] ?? const [],
      );
      list.removeWhere((item) => item['messageId'] == row['message_id']);
      list.add(_messageDisplayMapFromRow(row));
      list.sort(
        (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
            .compareTo(_coerceInt(b['timestampMs']) ?? 0),
      );
      _memoryMessages[threadId] = list;
      await _rebuildMemoryThread(threadId);
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      await txn.insert(
        'sms_messages',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _recomputeThreadSummary(txn, threadId);
    });
    await _emitLocalState(threadId: threadId);
  }

  Future<void> saveOutgoingMessage({
    required String receiver,
    required String body,
    int simSlot = 0,
  }) async {
    await saveMessage(
      SmsMessage(
        sender: 'Me',
        receiver: receiver,
        body: body,
        time: DateTime.now(),
        simSlot: simSlot,
        isOutgoing: true,
        status: 'sending',
        source: 'local_outgoing',
      ),
    );
  }

  Future<void> saveToQuarantine(SmsMessage message) async {
    await initialize();
    final threadId = threadIdForPeer(message.sender);
    final row = _quarantineRowFromSmsMessage(message, threadId);

    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryQuarantine[row['id']!.toString()] =
          _quarantineDisplayMapFromRow(row);
      await _rebuildMemoryThread(threadId);
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      await txn.insert(
        'sms_quarantine',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (message.providerId != null && message.providerId! > 0) {
        await txn.delete(
          'sms_messages',
          where: 'provider_id = ?',
          whereArgs: <Object>[message.providerId!],
        );
      }
      await _recomputeThreadSummary(txn, threadId);
    });
    await _emitLocalState(threadId: threadId);
  }

  Future<void> syncVisibleThreads(
      List<Map<String, dynamic>> nativeThreads) async {
    await initialize();
    final db = await _maybeOpenDatabase();
    if (db == null) {
      for (final thread in nativeThreads) {
        final normalized = _normalizeThreadMap(thread);
        final threadId = normalized['threadId']?.toString();
        if (threadId == null || threadId.isEmpty) {
          continue;
        }
        final merged = <String, dynamic>{
          ...(_memoryThreads[threadId] ?? const <String, dynamic>{}),
          ...normalized,
        };
        _memoryThreads[threadId] = merged;
        final providerThreadId = merged['providerThreadId']?.toString();
        if (providerThreadId != null && providerThreadId.isNotEmpty) {
          _providerThreadIdCache[threadId] = providerThreadId;
        }
      }
      await _emitThreads();
      return;
    }

    await db.transaction((Transaction txn) async {
      for (final thread in nativeThreads) {
        final normalized = _normalizeThreadMap(thread);
        final threadId = normalized['threadId']?.toString();
        if (threadId == null || threadId.isEmpty) {
          continue;
        }
        final existingRows = await txn.query(
          'sms_threads',
          where: 'thread_id = ?',
          whereArgs: <Object>[normalized['threadId']?.toString() ?? ''],
          limit: 1,
        );
        if (existingRows.isNotEmpty) {
          final existing = _threadDisplayMapFromRow(existingRows.first);
          normalized['quarantinedCount'] =
              _coerceInt(existing['quarantinedCount']) ??
                  _coerceInt(normalized['quarantinedCount']) ??
                  0;
          normalized['hiddenAtMs'] = _coerceInt(existing['hiddenAtMs']) ??
              _coerceInt(normalized['hiddenAtMs']) ??
              0;
          if ((normalized['unread'] as num?)?.toInt() == 0) {
            normalized['unread'] = _coerceInt(existing['unread']) ?? 0;
          }
          if (normalized['senderDisplay'] == null ||
              normalized['senderDisplay'].toString().trim().isEmpty) {
            normalized['senderDisplay'] = existing['senderDisplay'];
          }
        }
        await txn.insert(
          'sms_threads',
          _threadRowFromThreadMap(normalized),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        final providerThreadId = normalized['providerThreadId']?.toString();
        if (providerThreadId != null && providerThreadId.isNotEmpty) {
          _providerThreadIdCache[threadId] = providerThreadId;
        }
      }
    });
    await _emitThreads();
  }

  Future<void> syncVisibleMessages({
    required String peer,
    required List<Map<String, dynamic>> nativeMessages,
  }) async {
    await initialize();
    final threadId = _resolveThreadIdForMessages(peer, nativeMessages);

    final db = await _maybeOpenDatabase();
    if (db == null) {
      final List<Map<String, dynamic>> rows = nativeMessages
          .map(
            (message) => _messageDisplayMapFromRow(
                _messageRowFromMap(threadId, message)),
          )
          .toList(growable: true)
        ..sort(
          (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
              .compareTo(_coerceInt(b['timestampMs']) ?? 0),
        );
      _memoryMessages[threadId] = rows;
      final providerThreadId = nativeMessages.isEmpty
          ? null
          : nativeMessages.first['providerThreadId']?.toString();
      if (providerThreadId != null && providerThreadId.isNotEmpty) {
        _providerThreadIdCache[threadId] = providerThreadId;
      }
      await _rebuildMemoryThread(threadId);
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      await txn.delete(
        'sms_messages',
        where: 'thread_id = ?',
        whereArgs: <Object>[threadId],
      );
      for (final message in nativeMessages) {
        final row = _messageRowFromMap(threadId, message);
        await txn.insert(
          'sms_messages',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await _recomputeThreadSummary(txn, threadId);
    });

    if (nativeMessages.isNotEmpty) {
      final providerThreadId =
          nativeMessages.first['providerThreadId']?.toString();
      if (providerThreadId != null && providerThreadId.isNotEmpty) {
        _providerThreadIdCache[threadId] = providerThreadId;
      }
    }
    await _emitLocalState(threadId: threadId);
  }

  Future<void> upsertVisibleMessageMap(Map<String, dynamic> message) async {
    await initialize();
    final peer = message['peer']?.toString().trim().isNotEmpty == true
        ? message['peer']!.toString().trim()
        : (message['sender']?.toString() == 'Me'
            ? message['receiver']?.toString() ?? ''
            : message['sender']?.toString() ?? '');
    final threadId = message['threadId']?.toString().trim().isNotEmpty == true
        ? message['threadId']!.toString().trim()
        : _resolveThreadIdForMessages(peer, <Map<String, dynamic>>[message]);
    final row = _messageRowFromMap(threadId, message);

    final db = await _maybeOpenDatabase();
    if (db == null) {
      final list = List<Map<String, dynamic>>.from(
        _memoryMessages[threadId] ?? const [],
      );
      list.removeWhere((item) {
        final providerId = _coerceInt(message['providerId']);
        if (providerId != null && providerId > 0) {
          return (_coerceInt(item['providerId']) ?? 0) == providerId;
        }
        return item['messageId'] == row['message_id'];
      });
      list.add(_messageDisplayMapFromRow(row));
      list.sort(
        (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
            .compareTo(_coerceInt(b['timestampMs']) ?? 0),
      );
      _memoryMessages[threadId] = list;
      final providerThreadId = message['providerThreadId']?.toString();
      if (providerThreadId != null && providerThreadId.isNotEmpty) {
        _providerThreadIdCache[threadId] = providerThreadId;
      }
      await _rebuildMemoryThread(threadId);
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      await txn.insert(
        'sms_messages',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _recomputeThreadSummary(txn, threadId);
    });
    final providerThreadId = message['providerThreadId']?.toString();
    if (providerThreadId != null && providerThreadId.isNotEmpty) {
      _providerThreadIdCache[threadId] = providerThreadId;
    }
    await _emitLocalState(threadId: threadId);
  }

  Future<void> removeVisibleMessage({
    required String peer,
    int? providerId,
    String? messageId,
  }) async {
    if ((providerId == null || providerId <= 0) &&
        (messageId == null || messageId.trim().isEmpty)) {
      return;
    }
    await initialize();
    final threadId = threadIdForPeer(peer);
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final list = List<Map<String, dynamic>>.from(
        _memoryMessages[threadId] ?? const [],
      );
      list.removeWhere((item) {
        if (providerId != null && providerId > 0) {
          return (_coerceInt(item['providerId']) ?? 0) == providerId;
        }
        return item['messageId']?.toString() == messageId;
      });
      _memoryMessages[threadId] = list;
      await _rebuildMemoryThread(threadId);
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      if (providerId != null && providerId > 0) {
        await txn.delete(
          'sms_messages',
          where: 'provider_id = ?',
          whereArgs: <Object>[providerId],
        );
      } else {
        await txn.delete(
          'sms_messages',
          where: 'message_id = ?',
          whereArgs: <Object>[messageId!.trim()],
        );
      }
      await _recomputeThreadSummary(txn, threadId);
    });
    await _emitLocalState(threadId: threadId);
  }

  Future<void> removeVisibleProviderMessage({
    required String peer,
    required int providerId,
  }) async {
    await removeVisibleMessage(peer: peer, providerId: providerId);
  }

  Future<Map<String, dynamic>?> getQuarantineMessage(
      String quarantineId) async {
    await initialize();
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryQuarantine[quarantineId];
    }
    final rows = await db.query(
      'sms_quarantine',
      where: 'id = ?',
      whereArgs: <Object>[quarantineId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _quarantineDisplayMapFromRow(rows.first);
  }

  Future<void> markAsRead(String peer) async {
    await initialize();
    final threadId = threadIdForPeer(peer);
    await _setUnreadCount(threadId, 0);
    await _emitThreads();
  }

  Future<void> markThreadsAsRead(Set<String> threadIds) async {
    await initialize();
    if (threadIds.isEmpty) {
      return;
    }
    final db = await _maybeOpenDatabase();
    if (db == null) {
      for (final threadId in threadIds) {
        final existing = _memoryThreads[threadId];
        if (existing != null) {
          existing['unread'] = 0;
        }
      }
      await _emitThreads();
      return;
    }
    final batch = db.batch();
    for (final threadId in threadIds) {
      batch.update(
        'sms_threads',
        <String, Object?>{
          'unread': 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'thread_id = ?',
        whereArgs: <Object>[threadId],
      );
    }
    await batch.commit(noResult: true);
    await _emitThreads();
  }

  Future<void> deleteThreadForMe(String threadId) async {
    await initialize();
    final hideAtMs = DateTime.now().millisecondsSinceEpoch;
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryMessages.remove(threadId);
      final existing = _memoryThreads[threadId];
      if (existing != null) {
        existing['hiddenAtMs'] = hideAtMs;
        existing['lastTimestampMs'] = max(
          _coerceInt(existing['lastTimestampMs']) ?? 0,
          hideAtMs,
        );
      }
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      await txn.delete(
        'sms_messages',
        where: 'thread_id = ?',
        whereArgs: <Object>[threadId],
      );
      await txn.update(
        'sms_threads',
        <String, Object?>{
          'hidden_at_ms': hideAtMs,
          'updated_at': hideAtMs,
        },
        where: 'thread_id = ?',
        whereArgs: <Object>[threadId],
      );
      await _recomputeThreadSummary(txn, threadId);
    });
    await _emitLocalState(threadId: threadId);
  }

  Future<void> restoreQuarantineMessage(String quarantineId) async {
    final entry = await getQuarantineMessage(quarantineId);
    if (entry == null) {
      return;
    }

    await saveMessage(
      SmsMessage(
        sender: entry['sender']?.toString() ?? '',
        body: entry['message']?.toString() ?? '',
        time: _parseDateTime(entry['time']) ??
            DateTime.fromMillisecondsSinceEpoch(
              _coerceInt(entry['timestampMs']) ??
                  DateTime.now().millisecondsSinceEpoch,
            ),
        isSuspicious: false,
        simSlot: _coerceInt(entry['simSlot']) ?? 0,
        providerId: _coerceInt(entry['providerId']),
        providerThreadId: entry['providerThreadId']?.toString(),
        messageKey: entry['messageKey']?.toString(),
        detectionDecision: 'allow_trusted',
        extractedUrls: _stringListFromAny(entry['extractedUrls']),
        primaryUrl: entry['primaryUrl']?.toString(),
        primaryDomain: entry['primaryDomain']?.toString(),
        detectionReasons: const <String>['Restored from quarantine'],
      ),
    );
    await deleteQuarantineMessage(quarantineId);
  }

  Future<void> deleteQuarantineMessage(String quarantineId) async {
    await initialize();
    final entry = await getQuarantineMessage(quarantineId);
    final threadId = entry == null
        ? null
        : entry['threadId']?.toString().trim().isNotEmpty == true
            ? entry['threadId']!.toString().trim()
            : threadIdForPeer(entry['sender']?.toString() ?? '');

    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryQuarantine.remove(quarantineId);
      if (threadId != null && threadId.isNotEmpty) {
        await _rebuildMemoryThread(threadId);
      }
      await _emitLocalState(threadId: threadId);
      return;
    }

    await db.transaction((Transaction txn) async {
      await txn.delete(
        'sms_quarantine',
        where: 'id = ?',
        whereArgs: <Object>[quarantineId],
      );
      if (threadId != null && threadId.isNotEmpty) {
        await _recomputeThreadSummary(txn, threadId);
      }
    });
    await _emitLocalState(threadId: threadId);
  }

  Future<void> deleteQuarantineMessages(List<String> quarantineIds) async {
    await initialize();
    if (quarantineIds.isEmpty) {
      return;
    }
    final touchedThreadIds = <String>{};
    for (final id in quarantineIds) {
      final entry = await getQuarantineMessage(id);
      if (entry != null) {
        touchedThreadIds.add(
          entry['threadId']?.toString() ??
              threadIdForPeer(entry['sender']?.toString() ?? ''),
        );
      }
    }

    final db = await _maybeOpenDatabase();
    if (db == null) {
      for (final id in quarantineIds) {
        _memoryQuarantine.remove(id);
      }
      for (final threadId in touchedThreadIds) {
        await _rebuildMemoryThread(threadId);
      }
      await _emitLocalState();
      return;
    }

    await db.transaction((Transaction txn) async {
      final placeholders =
          List<String>.filled(quarantineIds.length, '?').join(',');
      await txn.delete(
        'sms_quarantine',
        where: 'id IN ($placeholders)',
        whereArgs: quarantineIds,
      );
      for (final threadId in touchedThreadIds) {
        if (threadId.trim().isEmpty) {
          continue;
        }
        await _recomputeThreadSummary(txn, threadId);
      }
    });
    await _emitLocalState();
  }

  Future<int> getLatestThreadTimestampMs() async {
    await initialize();
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryThreads.values.fold<int>(
        0,
        (int previous, Map<String, dynamic> row) =>
            max(previous, _coerceInt(row['lastTimestampMs']) ?? 0),
      );
    }
    final rows = await db.rawQuery(
      'SELECT MAX(last_timestamp_ms) AS latest FROM sms_threads',
    );
    return _coerceInt(rows.first['latest']) ?? 0;
  }

  Future<void> updateThreadSenderDisplay(
      String peer, String senderDisplay) async {
    if (senderDisplay.trim().isEmpty) {
      return;
    }
    await initialize();
    final threadId = threadIdForPeer(peer);
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final existing = _memoryThreads[threadId];
      if (existing != null) {
        existing['senderDisplay'] = senderDisplay;
        await _emitThreads();
      }
      return;
    }
    final updated = await db.update(
      'sms_threads',
      <String, Object?>{
        'sender_display': senderDisplay,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where:
          'thread_id = ? AND (sender_display IS NULL OR sender_display = \'\')',
      whereArgs: <Object>[threadId],
    );
    if (updated > 0) {
      await _emitThreads();
    }
  }

  Future<void> reconcileThreadMetadataForSender(String sender) async {
    await initialize();
    final threadId = threadIdForPeer(sender);
    final db = await _maybeOpenDatabase();
    if (db == null) {
      await _rebuildMemoryThread(threadId);
      await _emitLocalState(threadId: threadId);
      return;
    }
    await db.transaction((Transaction txn) async {
      await _recomputeThreadSummary(txn, threadId);
    });
    await _emitLocalState(threadId: threadId);
  }

  Future<SmsSyncCursor> readSyncCursor() async {
    await initialize();
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryCursor;
    }
    final rows = await db.query('sms_sync_state');
    final values = <String, String>{
      for (final row in rows)
        row['key']?.toString() ?? '': row['value']?.toString() ?? '',
    };
    return SmsSyncCursor(
      latestTimestampMs: int.tryParse(values['latestTimestampMs'] ?? '') ?? 0,
      latestProviderId: int.tryParse(values['latestProviderId'] ?? '') ?? 0,
      lastPrimeAtMs: int.tryParse(values['lastPrimeAtMs'] ?? '') ?? 0,
      lastMaintenanceAtMs:
          int.tryParse(values['lastMaintenanceAtMs'] ?? '') ?? 0,
    );
  }

  Future<void> writeSyncCursor({
    int? latestTimestampMs,
    int? latestProviderId,
    int? lastPrimeAtMs,
    int? lastMaintenanceAtMs,
  }) async {
    await initialize();
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryCursor = SmsSyncCursor(
        latestTimestampMs: latestTimestampMs ?? _memoryCursor.latestTimestampMs,
        latestProviderId: latestProviderId ?? _memoryCursor.latestProviderId,
        lastPrimeAtMs: lastPrimeAtMs ?? _memoryCursor.lastPrimeAtMs,
        lastMaintenanceAtMs:
            lastMaintenanceAtMs ?? _memoryCursor.lastMaintenanceAtMs,
      );
      return;
    }

    final updates = <String, int?>{
      'latestTimestampMs': latestTimestampMs,
      'latestProviderId': latestProviderId,
      'lastPrimeAtMs': lastPrimeAtMs,
      'lastMaintenanceAtMs': lastMaintenanceAtMs,
    }..removeWhere((String key, int? value) => value == null);
    if (updates.isEmpty) {
      return;
    }

    final batch = db.batch();
    updates.forEach((String key, int? value) {
      batch.insert(
        'sms_sync_state',
        <String, Object?>{
          'key': key,
          'value': value.toString(),
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await batch.commit(noResult: true);
  }

  Future<void> _setUnreadCount(String threadId, int unread) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final existing = _memoryThreads[threadId];
      if (existing != null) {
        existing['unread'] = unread;
      }
      return;
    }
    await db.update(
      'sms_threads',
      <String, Object?>{
        'unread': unread,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'thread_id = ?',
      whereArgs: <Object>[threadId],
    );
  }

  Future<void> _emitLocalState({String? threadId}) async {
    await _emitThreads();
    await _emitQuarantine();
    if (threadId != null && threadId.isNotEmpty) {
      await _emitMessagesForThread(threadId);
      return;
    }
    for (final id in _messageControllers.keys.toList(growable: false)) {
      await _emitMessagesForThread(id);
    }
  }

  Future<void> _emitThreads() async {
    final threads = await _loadVisibleThreads();
    if (!_threadsController.isClosed) {
      _threadsController.add(threads);
    }
  }

  Future<void> _emitQuarantine() async {
    final entries = await _loadQuarantineEntries();
    if (!_quarantineController.isClosed) {
      _quarantineController.add(entries);
    }
  }

  Future<void> _emitMessagesForThread(String threadId) async {
    final controller = _messageControllers[threadId];
    if (controller == null || controller.isClosed) {
      return;
    }
    final messages = await _loadMessagesForThread(threadId);
    controller.add(messages);
  }

  Future<List<Map<String, dynamic>>> _loadVisibleThreads() async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final rows = _memoryThreads.values
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) {
        final hiddenAtMs = _coerceInt(row['hiddenAtMs']) ?? 0;
        final lastTimestampMs = _coerceInt(row['lastTimestampMs']) ?? 0;
        return !(hiddenAtMs > 0 && lastTimestampMs <= hiddenAtMs);
      }).toList(growable: true)
        ..sort(
          (a, b) => (_coerceInt(b['lastTimestampMs']) ?? 0)
              .compareTo(_coerceInt(a['lastTimestampMs']) ?? 0),
        );
      return rows;
    }

    final rows = await db.query(
      'sms_threads',
      orderBy: 'last_timestamp_ms DESC, updated_at DESC',
    );
    return rows.map((row) => _threadDisplayMapFromRow(row)).where((row) {
      final hiddenAtMs = _coerceInt(row['hiddenAtMs']) ?? 0;
      final lastTimestampMs = _coerceInt(row['lastTimestampMs']) ?? 0;
      return !(hiddenAtMs > 0 && lastTimestampMs <= hiddenAtMs);
    }).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _loadMessagesForThread(
    String threadId,
  ) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return List<Map<String, dynamic>>.from(
          _memoryMessages[threadId] ?? const [])
        ..sort(
          (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
              .compareTo(_coerceInt(b['timestampMs']) ?? 0),
        );
    }
    final rows = await db.query(
      'sms_messages',
      where: 'thread_id = ?',
      whereArgs: <Object>[threadId],
      orderBy: 'timestamp_ms ASC, provider_id ASC',
    );
    return rows
        .map((row) => _messageDisplayMapFromRow(row))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _loadQuarantineEntries() async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final rows = _memoryQuarantine.values
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: true)
        ..sort(
          (a, b) => (_coerceInt(b['timestampMs']) ?? 0)
              .compareTo(_coerceInt(a['timestampMs']) ?? 0),
        );
      return rows;
    }
    final rows = await db.query(
      'sms_quarantine',
      orderBy: 'timestamp_ms DESC, reported_at DESC',
    );
    return rows
        .map((row) => _quarantineDisplayMapFromRow(row))
        .toList(growable: false);
  }

  Future<void> _recomputeThreadSummary(
    DatabaseExecutor executor,
    String threadId,
  ) async {
    if (threadId.trim().isEmpty) {
      return;
    }

    final existingRows = await executor.query(
      'sms_threads',
      where: 'thread_id = ?',
      whereArgs: <Object>[threadId],
      limit: 1,
    );
    final existing = existingRows.isEmpty ? null : existingRows.first;

    final visibleRows = await executor.query(
      'sms_messages',
      where: 'thread_id = ?',
      whereArgs: <Object>[threadId],
      orderBy: 'timestamp_ms DESC, provider_id DESC',
      limit: 1,
    );
    final visibleLatest = visibleRows.isEmpty ? null : visibleRows.first;
    final visibleCount = Sqflite.firstIntValue(
          await executor.rawQuery(
            'SELECT COUNT(*) AS count FROM sms_messages WHERE thread_id = ?',
            <Object>[threadId],
          ),
        ) ??
        0;
    final hasSuspicious = (Sqflite.firstIntValue(
              await executor.rawQuery(
                'SELECT COUNT(*) AS count FROM sms_messages WHERE thread_id = ? AND is_suspicious = 1',
                <Object>[threadId],
              ),
            ) ??
            0) >
        0;

    final quarantineRows = await executor.query(
      'sms_quarantine',
      where: 'thread_id = ?',
      whereArgs: <Object>[threadId],
      orderBy: 'timestamp_ms DESC',
      limit: 1,
    );
    final quarantineLatest =
        quarantineRows.isEmpty ? null : quarantineRows.first;
    final quarantinedCount = Sqflite.firstIntValue(
          await executor.rawQuery(
            'SELECT COUNT(*) AS count FROM sms_quarantine WHERE thread_id = ?',
            <Object>[threadId],
          ),
        ) ??
        0;

    if (visibleLatest == null && quarantineLatest == null) {
      await executor.delete(
        'sms_threads',
        where: 'thread_id = ?',
        whereArgs: <Object>[threadId],
      );
      _providerThreadIdCache.remove(threadId);
      return;
    }

    final visibleTimestampMs = _coerceInt(visibleLatest?['timestamp_ms']) ?? 0;
    final quarantineTimestampMs =
        _coerceInt(quarantineLatest?['timestamp_ms']) ?? 0;
    final useQuarantine =
        quarantineLatest != null && quarantineTimestampMs >= visibleTimestampMs;

    final latestSender = useQuarantine
        ? quarantineLatest['sender']?.toString()
        : visibleLatest?['peer']?.toString() ??
            visibleLatest?['sender']?.toString();
    final latestMessage = useQuarantine
        ? quarantineLatest['message']?.toString() ?? ''
        : visibleLatest?['body']?.toString() ??
            visibleLatest?['text']?.toString() ??
            '';
    final latestTime = useQuarantine
        ? quarantineLatest['time']?.toString()
        : visibleLatest?['time']?.toString();
    final latestTimestampMs = max(visibleTimestampMs, quarantineTimestampMs);
    final latestSimSlot = useQuarantine
        ? _coerceInt(quarantineLatest['sim_slot']) ?? 0
        : _coerceInt(visibleLatest?['sim_slot']) ?? 0;
    final providerThreadId = visibleLatest?['provider_thread_id']?.toString() ??
        existing?['provider_thread_id']?.toString();
    final unread = _coerceInt(existing?['unread']) ?? 0;
    final hiddenAtMs = _coerceInt(existing?['hidden_at_ms']) ?? 0;
    final row = <String, Object?>{
      'thread_id': threadId,
      'provider_thread_id': providerThreadId,
      'sender': latestSender ?? existing?['sender']?.toString() ?? threadId,
      'sender_display': existing?['sender_display']?.toString(),
      'phone': latestSender ?? existing?['phone']?.toString() ?? threadId,
      'last_message': latestMessage,
      'last_time': latestTime,
      'last_timestamp_ms': latestTimestampMs,
      'last_direction': useQuarantine
          ? 'incoming'
          : ((_coerceInt(visibleLatest?['is_outgoing']) ?? 0) == 1
              ? 'outgoing'
              : 'incoming'),
      'last_message_is_quarantined': useQuarantine ? 1 : 0,
      'last_message_is_suspicious': useQuarantine
          ? 1
          : (_coerceInt(visibleLatest?['is_suspicious']) ?? 0),
      'last_sim_slot': latestSimSlot,
      'visible_message_count': visibleCount,
      'unread': unread,
      'has_suspicious': hasSuspicious ? 1 : 0,
      'quarantined_count': quarantinedCount,
      'hidden_at_ms': hiddenAtMs,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    await executor.insert(
      'sms_threads',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (providerThreadId != null && providerThreadId.isNotEmpty) {
      _providerThreadIdCache[threadId] = providerThreadId;
    }
  }

  Future<void> _rebuildMemoryThread(String threadId) async {
    final visible = List<Map<String, dynamic>>.from(
      _memoryMessages[threadId] ?? const [],
    );
    visible.sort(
      (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
          .compareTo(_coerceInt(b['timestampMs']) ?? 0),
    );
    final quarantine = _memoryQuarantine.values
        .where((row) => (row['threadId']?.toString() ?? '') == threadId)
        .toList(growable: true)
      ..sort(
        (a, b) => (_coerceInt(a['timestampMs']) ?? 0)
            .compareTo(_coerceInt(b['timestampMs']) ?? 0),
      );

    if (visible.isEmpty && quarantine.isEmpty) {
      _memoryThreads.remove(threadId);
      _providerThreadIdCache.remove(threadId);
      return;
    }

    final existing = _memoryThreads[threadId] ?? <String, dynamic>{};
    final latestVisible = visible.isEmpty ? null : visible.last;
    final latestQuarantine = quarantine.isEmpty ? null : quarantine.last;
    final visibleTimestampMs = _coerceInt(latestVisible?['timestampMs']) ?? 0;
    final quarantineTimestampMs =
        _coerceInt(latestQuarantine?['timestampMs']) ?? 0;
    final useQuarantine =
        latestQuarantine != null && quarantineTimestampMs >= visibleTimestampMs;
    final latest = useQuarantine ? latestQuarantine : latestVisible;
    if (latest == null) {
      _memoryThreads.remove(threadId);
      _providerThreadIdCache.remove(threadId);
      return;
    }
    final providerThreadId = latest['providerThreadId']?.toString() ??
        existing['providerThreadId']?.toString();
    _memoryThreads[threadId] = <String, dynamic>{
      ...existing,
      'threadId': threadId,
      'providerThreadId': providerThreadId,
      'sender': (useQuarantine
              ? latest['sender']
              : latest['peer'] ?? latest['sender']) ??
          existing['sender'] ??
          threadId,
      'senderDisplay': existing['senderDisplay'],
      'phone': (useQuarantine
              ? latest['sender']
              : latest['peer'] ?? latest['sender']) ??
          existing['phone'] ??
          threadId,
      'lastMessage':
          latest['message'] ?? latest['body'] ?? latest['text'] ?? '',
      'lastTime': latest['time'],
      'lastTimestampMs': max(visibleTimestampMs, quarantineTimestampMs),
      'lastDirection': useQuarantine
          ? 'incoming'
          : ((latest['isOutgoing'] == true) ? 'outgoing' : 'incoming'),
      'lastMessageIsQuarantined': useQuarantine,
      'lastMessageIsSuspicious':
          useQuarantine ? true : (latest['isSuspicious'] == true),
      'lastSimSlot': _coerceInt(latest['simSlot']) ?? 0,
      'visibleMessageCount': visible.length,
      'unread': _coerceInt(existing['unread']) ?? 0,
      'hasSuspicious': visible.any((row) => row['isSuspicious'] == true),
      'quarantinedCount': quarantine.length,
      'hiddenAtMs': _coerceInt(existing['hiddenAtMs']) ?? 0,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (providerThreadId != null && providerThreadId.isNotEmpty) {
      _providerThreadIdCache[threadId] = providerThreadId;
    }
  }

  Map<String, Object?> _threadRowFromThreadMap(Map<String, dynamic> map) {
    return <String, Object?>{
      'thread_id': map['threadId']?.toString() ?? '',
      'provider_thread_id': map['providerThreadId']?.toString(),
      'sender': map['sender']?.toString() ?? '',
      'sender_display': map['senderDisplay']?.toString(),
      'phone': map['phone']?.toString() ?? map['sender']?.toString(),
      'last_message': map['lastMessage']?.toString() ?? '',
      'last_time': map['lastTime']?.toString(),
      'last_timestamp_ms': _coerceInt(map['lastTimestampMs']) ??
          _parseTimestampMs(map['lastTime']) ??
          0,
      'last_direction': map['lastDirection']?.toString(),
      'last_message_is_quarantined':
          map['lastMessageIsQuarantined'] == true ? 1 : 0,
      'last_message_is_suspicious':
          map['lastMessageIsSuspicious'] == true ? 1 : 0,
      'last_sim_slot': _coerceInt(map['lastSimSlot']) ?? 0,
      'visible_message_count': _coerceInt(map['visibleMessageCount']) ?? 0,
      'unread': _coerceInt(map['unread']) ?? 0,
      'has_suspicious': map['hasSuspicious'] == true ? 1 : 0,
      'quarantined_count': _coerceInt(map['quarantinedCount']) ?? 0,
      'hidden_at_ms': _coerceInt(map['hiddenAtMs']) ?? 0,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> _normalizeThreadMap(Map<String, dynamic> map) {
    final sender = map['sender']?.toString() ?? '';
    final phone = map['phone']?.toString() ?? sender;
    return <String, dynamic>{
      'threadId': threadIdForPeer(phone.isNotEmpty ? phone : sender),
      'providerThreadId': map['providerThreadId']?.toString(),
      'sender': sender,
      'senderDisplay': map['senderDisplay']?.toString(),
      'phone': phone,
      'lastMessage': map['lastMessage']?.toString() ?? '',
      'lastTime': map['lastTime']?.toString(),
      'lastTimestampMs': _coerceInt(map['lastTimestampMs']) ??
          _parseTimestampMs(map['lastTime']) ??
          0,
      'lastDirection': map['lastDirection']?.toString(),
      'lastMessageIsQuarantined': map['lastMessageIsQuarantined'] == true,
      'lastMessageIsSuspicious': map['lastMessageIsSuspicious'] == true,
      'lastSimSlot': _coerceInt(map['lastSimSlot']) ?? 0,
      'visibleMessageCount': _coerceInt(map['visibleMessageCount']) ?? 0,
      'unread': _coerceInt(map['unread']) ?? 0,
      'hasSuspicious': map['hasSuspicious'] == true,
      'quarantinedCount': _coerceInt(map['quarantinedCount']) ?? 0,
      'hiddenAtMs': _coerceInt(map['hiddenAtMs']) ?? 0,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> _messageRowFromMap(
    String threadId,
    Map<String, dynamic> map,
  ) {
    final timestampMs = _coerceInt(map['timestampMs']) ??
        _parseTimestampMs(map['time'] ?? map['timestamp']) ??
        DateTime.now().millisecondsSinceEpoch;
    final peer = map['peer']?.toString().trim().isNotEmpty == true
        ? map['peer']!.toString().trim()
        : (map['sender']?.toString() == 'Me'
            ? map['receiver']?.toString() ?? threadId
            : map['sender']?.toString() ?? threadId);
    return <String, Object?>{
      'message_id': map['messageId']?.toString() ??
          'provider_${map['providerId'] ?? timestampMs}',
      'provider_id': _coerceInt(map['providerId']),
      'provider_thread_id': map['providerThreadId']?.toString(),
      'thread_id': threadId,
      'sender': map['sender']?.toString() ?? '',
      'receiver': map['receiver']?.toString(),
      'peer': peer,
      'body': map['body']?.toString() ?? map['text']?.toString() ?? '',
      'text': map['text']?.toString() ?? map['body']?.toString() ?? '',
      'time': map['time']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
      'timestamp': map['timestamp']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
      'timestamp_ms': timestampMs,
      'is_suspicious': map['isSuspicious'] == true ? 1 : 0,
      'sim_slot': _coerceInt(map['simSlot']) ?? 0,
      'is_outgoing': map['isOutgoing'] == true || map['sender'] == 'Me' ? 1 : 0,
      'status': map['status']?.toString() ??
          ((map['isOutgoing'] == true || map['sender'] == 'Me')
              ? 'sending'
              : 'received'),
      'source': map['source']?.toString() ?? 'telephony_provider',
      'risk_score': _coerceDouble(map['riskScore']) ?? 0.0,
      'risk_level': map['riskLevel']?.toString() ?? 'safe',
      'detection_reasons_json': jsonEncode(
        _stringListFromAny(map['detectionReasons']),
      ),
      'model_score': _coerceDouble(map['modelScore']),
      'heuristic_score': _coerceDouble(map['heuristicScore']) ?? 0.0,
      'detection_source': map['detectionSource']?.toString() ?? 'provider_sync',
      'pipeline_stage': map['pipelineStage']?.toString() ?? 'provider_sync',
      'message_key': map['messageKey']?.toString(),
      'detection_decision': map['detectionDecision']?.toString(),
      'extracted_urls_json':
          jsonEncode(_stringListFromAny(map['extractedUrls'])),
      'primary_url': map['primaryUrl']?.toString(),
      'primary_domain': map['primaryDomain']?.toString(),
      'needs_rescan': map['needsRescan'] == true ? 1 : 0,
      'safety_status': map['safetyStatus']?.toString() ??
          (map['isSuspicious'] == true ? 'malicious' : 'safe'),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> _messageRowFromSmsMessage({
    required String threadId,
    required String messageId,
    required SmsMessage message,
    required String peer,
    required bool isOutgoing,
    required String status,
    required String source,
  }) {
    return <String, Object?>{
      'message_id': messageId,
      'provider_id': message.providerId,
      'provider_thread_id': message.providerThreadId,
      'thread_id': threadId,
      'sender': isOutgoing ? 'Me' : message.sender,
      'receiver': isOutgoing ? peer : message.receiver,
      'peer': peer,
      'body': message.body,
      'text': message.body,
      'time': message.time.toIso8601String(),
      'timestamp': message.time.toIso8601String(),
      'timestamp_ms': message.time.millisecondsSinceEpoch,
      'is_suspicious': message.isSuspicious ? 1 : 0,
      'sim_slot': message.simSlot,
      'is_outgoing': isOutgoing ? 1 : 0,
      'status': status,
      'source': source,
      'risk_score': message.riskScore ?? 0.0,
      'risk_level':
          message.riskLevel ?? (message.isSuspicious ? 'high' : 'safe'),
      'detection_reasons_json': jsonEncode(message.detectionReasons),
      'model_score': message.modelScore,
      'heuristic_score': message.heuristicScore ?? 0.0,
      'detection_source': message.detectionSource ?? source,
      'pipeline_stage': message.pipelineStage ?? source,
      'message_key': message.messageKey,
      'detection_decision': message.detectionDecision,
      'extracted_urls_json': jsonEncode(message.extractedUrls),
      'primary_url': message.primaryUrl,
      'primary_domain': message.primaryDomain,
      'needs_rescan': message.needsRescan ? 1 : 0,
      'safety_status': message.safetyStatus.value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> _quarantineRowFromSmsMessage(
    SmsMessage message,
    String threadId,
  ) {
    final timestampMs = message.time.millisecondsSinceEpoch;
    final id = message.messageKey?.trim().isNotEmpty == true
        ? 'q_${message.messageKey!.trim()}'
        : 'q_${message.providerId ?? timestampMs}_${message.sender.hashCode}';
    return <String, Object?>{
      'id': id,
      'sender': message.sender,
      'thread_id': threadId,
      'message': message.body,
      'source': 'sms',
      'restore_mode': 'smsThread',
      'sim_slot': message.simSlot,
      'provider_id': message.providerId,
      'provider_thread_id': message.providerThreadId,
      'message_key': message.messageKey,
      'detection_decision': message.detectionDecision,
      'extracted_urls_json': jsonEncode(message.extractedUrls),
      'primary_url': message.primaryUrl,
      'primary_domain': message.primaryDomain,
      'needs_rescan': message.needsRescan ? 1 : 0,
      'safety_status': message.safetyStatus.value,
      'time': message.time.toIso8601String(),
      'timestamp': message.time.toIso8601String(),
      'timestamp_ms': timestampMs,
      'is_suspicious': 1,
      'risk_score': message.riskScore ?? 0.0,
      'risk_level': message.riskLevel ?? 'high',
      'detection_reasons_json': jsonEncode(message.detectionReasons),
      'model_score': message.modelScore,
      'heuristic_score': message.heuristicScore ?? 0.0,
      'detection_source': message.detectionSource,
      'pipeline_stage': message.pipelineStage,
      'quarantine_reason': message.detectionDecision ?? 'quarantine_high_risk',
      'reported_at': message.time.toIso8601String(),
    };
  }

  Map<String, Object?> _quarantineRowFromMap(Map<String, dynamic> map) {
    final timestampMs = _coerceInt(map['timestampMs']) ??
        _parseTimestampMs(
            map['reportedAt'] ?? map['time'] ?? map['timestamp']) ??
        DateTime.now().millisecondsSinceEpoch;
    final sender = map['sender']?.toString() ?? '';
    final threadId = map['threadId']?.toString() ?? threadIdForPeer(sender);
    return <String, Object?>{
      'id': map['id']?.toString() ??
          'q_${map['messageKey'] ?? map['providerId'] ?? timestampMs}',
      'sender': sender,
      'thread_id': threadId,
      'message': map['message']?.toString() ?? '',
      'source': map['source']?.toString() ?? 'sms',
      'restore_mode': map['restoreMode']?.toString() ?? 'smsThread',
      'sim_slot': _coerceInt(map['simSlot']) ?? 0,
      'provider_id': _coerceInt(map['providerId']),
      'provider_thread_id': map['providerThreadId']?.toString(),
      'message_key': map['messageKey']?.toString(),
      'detection_decision': map['detectionDecision']?.toString(),
      'extracted_urls_json':
          jsonEncode(_stringListFromAny(map['extractedUrls'])),
      'primary_url': map['primaryUrl']?.toString(),
      'primary_domain': map['primaryDomain']?.toString(),
      'needs_rescan': map['needsRescan'] == true ? 1 : 0,
      'safety_status': map['safetyStatus']?.toString() ??
          (map['isSuspicious'] == true ? 'malicious' : 'safe'),
      'time': map['time']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
      'timestamp': map['timestamp']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
      'timestamp_ms': timestampMs,
      'is_suspicious': 1,
      'risk_score': _coerceDouble(map['riskScore']) ?? 0.0,
      'risk_level': map['riskLevel']?.toString() ?? 'high',
      'detection_reasons_json': jsonEncode(
        _stringListFromAny(map['detectionReasons']),
      ),
      'model_score': _coerceDouble(map['modelScore']),
      'heuristic_score': _coerceDouble(map['heuristicScore']) ?? 0.0,
      'detection_source': map['detectionSource']?.toString(),
      'pipeline_stage': map['pipelineStage']?.toString(),
      'quarantine_reason': map['quarantineReason']?.toString() ??
          map['detectionDecision']?.toString(),
      'reported_at': map['reportedAt']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
    };
  }

  Map<String, dynamic> _threadDisplayMapFromRow(Map<String, Object?> row) {
    return <String, dynamic>{
      'threadId': row['thread_id']?.toString() ?? '',
      'providerThreadId': row['provider_thread_id']?.toString(),
      'sender': row['sender']?.toString() ?? '',
      'senderDisplay': row['sender_display']?.toString(),
      'phone': row['phone']?.toString(),
      'lastMessage': row['last_message']?.toString() ?? '',
      'lastTime': row['last_time']?.toString(),
      'lastTimestampMs': _coerceInt(row['last_timestamp_ms']) ?? 0,
      'lastDirection': row['last_direction']?.toString(),
      'lastMessageIsQuarantined':
          (_coerceInt(row['last_message_is_quarantined']) ?? 0) == 1,
      'lastMessageIsSuspicious':
          (_coerceInt(row['last_message_is_suspicious']) ?? 0) == 1,
      'lastSimSlot': _coerceInt(row['last_sim_slot']) ?? 0,
      'visibleMessageCount': _coerceInt(row['visible_message_count']) ?? 0,
      'unread': _coerceInt(row['unread']) ?? 0,
      'hasSuspicious': (_coerceInt(row['has_suspicious']) ?? 0) == 1,
      'quarantinedCount': _coerceInt(row['quarantined_count']) ?? 0,
      'hiddenAtMs': _coerceInt(row['hidden_at_ms']) ?? 0,
      'updatedAt': _coerceInt(row['updated_at']) ?? 0,
    };
  }

  Map<String, dynamic> _messageDisplayMapFromRow(Map<String, Object?> row) {
    return <String, dynamic>{
      'messageId': row['message_id']?.toString() ?? '',
      'providerId': _coerceInt(row['provider_id']),
      'providerThreadId': row['provider_thread_id']?.toString(),
      'threadId': row['thread_id']?.toString() ?? '',
      'sender': row['sender']?.toString() ?? '',
      'receiver': row['receiver']?.toString(),
      'peer': row['peer']?.toString() ?? '',
      'body': row['body']?.toString() ?? '',
      'text': row['text']?.toString() ?? '',
      'time': row['time']?.toString(),
      'timestamp': row['timestamp']?.toString(),
      'timestampMs': _coerceInt(row['timestamp_ms']) ?? 0,
      'isSuspicious': (_coerceInt(row['is_suspicious']) ?? 0) == 1,
      'simSlot': _coerceInt(row['sim_slot']) ?? 0,
      'isOutgoing': (_coerceInt(row['is_outgoing']) ?? 0) == 1,
      'status': row['status']?.toString() ?? 'received',
      'source': row['source']?.toString() ?? 'local_projection',
      'riskScore': _coerceDouble(row['risk_score']) ?? 0.0,
      'riskLevel': row['risk_level']?.toString() ?? 'safe',
      'detectionReasons': _decodeStringList(row['detection_reasons_json']),
      'modelScore': _coerceDouble(row['model_score']),
      'heuristicScore': _coerceDouble(row['heuristic_score']) ?? 0.0,
      'detectionSource': row['detection_source']?.toString(),
      'pipelineStage': row['pipeline_stage']?.toString(),
      'messageKey': row['message_key']?.toString(),
      'detectionDecision': row['detection_decision']?.toString(),
      'extractedUrls': _decodeStringList(row['extracted_urls_json']),
      'primaryUrl': row['primary_url']?.toString(),
      'primaryDomain': row['primary_domain']?.toString(),
      'needsRescan': (_coerceInt(row['needs_rescan']) ?? 0) == 1,
      'safetyStatus': row['safety_status']?.toString() ?? 'safe',
    };
  }

  Map<String, dynamic> _quarantineDisplayMapFromRow(Map<String, Object?> row) {
    return <String, dynamic>{
      'id': row['id']?.toString() ?? '',
      'sender': row['sender']?.toString() ?? '',
      'threadId': row['thread_id']?.toString() ?? '',
      'message': row['message']?.toString() ?? '',
      'source': row['source']?.toString() ?? 'sms',
      'restoreMode': row['restore_mode']?.toString(),
      'simSlot': _coerceInt(row['sim_slot']) ?? 0,
      'providerId': _coerceInt(row['provider_id']),
      'providerThreadId': row['provider_thread_id']?.toString(),
      'messageKey': row['message_key']?.toString(),
      'detectionDecision': row['detection_decision']?.toString(),
      'extractedUrls': _decodeStringList(row['extracted_urls_json']),
      'primaryUrl': row['primary_url']?.toString(),
      'primaryDomain': row['primary_domain']?.toString(),
      'needsRescan': (_coerceInt(row['needs_rescan']) ?? 0) == 1,
      'safetyStatus': row['safety_status']?.toString() ?? 'malicious',
      'time': row['time']?.toString(),
      'timestamp': row['timestamp']?.toString(),
      'timestampMs': _coerceInt(row['timestamp_ms']) ?? 0,
      'isSuspicious': (_coerceInt(row['is_suspicious']) ?? 0) == 1,
      'riskScore': _coerceDouble(row['risk_score']) ?? 0.0,
      'riskLevel': row['risk_level']?.toString() ?? 'high',
      'detectionReasons': _decodeStringList(row['detection_reasons_json']),
      'modelScore': _coerceDouble(row['model_score']),
      'heuristicScore': _coerceDouble(row['heuristic_score']) ?? 0.0,
      'detectionSource': row['detection_source']?.toString(),
      'pipelineStage': row['pipeline_stage']?.toString(),
      'quarantineReason': row['quarantine_reason']?.toString(),
      'reportedAt': row['reported_at']?.toString(),
    };
  }

  String _resolveThreadIdForMessages(
    String peer,
    List<Map<String, dynamic>> messages,
  ) {
    return threadIdForPeer(peer);
  }

  String _buildLocalMessageId(SmsMessage message) {
    if (message.messageKey?.trim().isNotEmpty == true) {
      return 'local_${message.messageKey!.trim()}';
    }
    final peer = message.receiver?.trim().isNotEmpty == true
        ? message.receiver!.trim()
        : message.sender;
    return 'local_${threadIdForPeer(peer)}_${message.time.millisecondsSinceEpoch}_${message.body.hashCode}';
  }

  int? _coerceInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  double? _coerceDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  int? _parseTimestampMs(Object? value) {
    final date = _parseDateTime(value);
    return date?.millisecondsSinceEpoch;
  }

  DateTime? _parseDateTime(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    final raw = value.toString().trim();
    if (raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  List<String> _decodeStringList(Object? raw) {
    if (raw == null) {
      return const <String>[];
    }
    if (raw is List) {
      return raw
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(growable: false);
    }
    final text = raw.toString();
    if (text.trim().isEmpty) {
      return const <String>[];
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        return decoded
            .map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {}
    return const <String>[];
  }

  List<String> _stringListFromAny(Object? raw) {
    if (raw is List) {
      return raw
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(growable: false);
    }
    if (raw == null) {
      return const <String>[];
    }
    return _decodeStringList(raw);
  }

  String _normalizePhone(String raw) {
    final compact = raw.trim().replaceAll(RegExp(r'[^0-9+]'), '');
    if (compact.startsWith('+63') && compact.length > 3) {
      return '0${compact.substring(3)}';
    }
    if (compact.startsWith('63') && compact.length > 2) {
      return '0${compact.substring(2)}';
    }
    return compact;
  }

  List<Map<String, dynamic>> _decodeLegacyThreadEntries(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
      if (decoded is Map) {
        return decoded.values
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
    } catch (_) {}
    return const <Map<String, dynamic>>[];
  }

  Map<String, List<Map<String, dynamic>>> _decodeLegacyMessageEntries(
    String? raw,
  ) {
    final result = <String, List<Map<String, dynamic>>>{};
    if (raw == null || raw.trim().isEmpty) {
      return result;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return result;
      }
      for (final MapEntry<dynamic, dynamic> entry in decoded.entries) {
        final threadId = entry.key?.toString() ?? '';
        if (threadId.isEmpty || entry.value is! List) {
          continue;
        }
        result[threadId] = (entry.value as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
    } catch (_) {}
    return result;
  }

  List<Map<String, dynamic>> _decodeLegacyQuarantineEntries(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
      if (decoded is Map) {
        return decoded.values
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
    } catch (_) {}
    return const <Map<String, dynamic>>[];
  }

  Set<String> _decodeLegacyHiddenThreads(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return <String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((item) => item.toString()).toSet();
      }
      if (decoded is Map) {
        return decoded.keys.map((item) => item.toString()).toSet();
      }
    } catch (_) {}
    return <String>{};
  }
}
