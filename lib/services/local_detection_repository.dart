import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/detection_result_model.dart';
import '../models/feedback_log_model.dart';
import '../models/screened_message_model.dart';
import '../models/trusted_domain_model.dart';

class LocalDetectionRepository {
  LocalDetectionRepository._internal();

  static final LocalDetectionRepository instance =
      LocalDetectionRepository._internal();
  factory LocalDetectionRepository() => instance;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _dbPasswordKey = 'smishing_detection_db_password_v1';
  static const int _schemaVersion = 1;
  static const String _warningThresholdKey = 'warning_threshold';
  static const String _quarantineThresholdKey = 'quarantine_threshold';

  Database? _database;
  Future<Database>? _databaseFuture;
  bool _memoryMode = false;
  final Map<String, TrustedDomainModel> _memoryTrustedDomains =
      <String, TrustedDomainModel>{};
  final Map<String, _MemoryScreeningRecord> _memoryScreeningResults =
      <String, _MemoryScreeningRecord>{};
  final List<FeedbackLogModel> _memoryFeedbackLogs = <FeedbackLogModel>[];
  final Map<String, String> _memorySettings = <String, String>{
    _warningThresholdKey: '0.42',
    _quarantineThresholdKey: '0.72',
  };

  Future<void> initialize() async {
    await _maybeOpenDatabase();
  }

  Future<Database> _openDatabase() async {
    if (_database != null) {
      return _database!;
    }
    if (_databaseFuture != null) {
      return _databaseFuture!;
    }

    _databaseFuture = () async {
      Directory directory;
      try {
        directory = await getApplicationDocumentsDirectory();
      } catch (_) {
        directory = Directory.systemTemp.createTempSync('smishing_detection');
      }
      final dbPath = p.join(directory.path, 'smishing_detection.db');
      final password = await _getDatabasePassword();
      try {
        final database = await openDatabase(
          dbPath,
          password: password,
          version: _schemaVersion,
          onCreate: (Database db, int version) async {
            await _createSchema(db);
          },
        );
        _database = database;
        return database;
      } catch (_) {
        _memoryMode = true;
        rethrow;
      }
    }();

    try {
      return await _databaseFuture!;
    } finally {
      _databaseFuture = null;
    }
  }

  Future<Database?> _maybeOpenDatabase() async {
    if (_memoryMode) {
      return null;
    }
    try {
      return await _openDatabase();
    } catch (_) {
      _memoryMode = true;
      return null;
    }
  }

  Future<String> _getDatabasePassword() async {
    String? existing;
    try {
      existing = await _secureStorage.read(key: _dbPasswordKey);
    } catch (_) {
      existing = null;
    }
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final random = Random.secure();
    final bytes = List<int>.generate(48, (_) => random.nextInt(256));
    final password = base64UrlEncode(bytes);
    try {
      await _secureStorage.write(key: _dbPasswordKey, value: password);
    } catch (_) {
      return 'test_detection_password_v1';
    }
    return password;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE trusted_domains (
        domain TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        note TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE screening_results (
        message_key TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        sender TEXT NOT NULL,
        peer TEXT,
        body_preview TEXT,
        body_hash TEXT NOT NULL,
        raw_body TEXT,
        timestamp_ms INTEGER NOT NULL,
        provider_id INTEGER,
        provider_thread_id TEXT,
        sim_slot INTEGER,
        subscription_id INTEGER,
        has_url INTEGER NOT NULL DEFAULT 0,
        extracted_urls_json TEXT NOT NULL,
        primary_url TEXT,
        primary_domain TEXT,
        trusted_match INTEGER NOT NULL DEFAULT 0,
        ml_invoked INTEGER NOT NULL DEFAULT 0,
        raw_logits_json TEXT NOT NULL,
        risk_score REAL NOT NULL,
        warning_threshold REAL NOT NULL,
        quarantine_threshold REAL NOT NULL,
        decision TEXT NOT NULL,
        reason TEXT NOT NULL,
        explanations_json TEXT NOT NULL,
        needs_rescan INTEGER NOT NULL DEFAULT 0,
        heuristic_score REAL NOT NULL DEFAULT 0,
        model_score REAL,
        risk_level TEXT NOT NULL,
        detection_source TEXT NOT NULL,
        pipeline_stage TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE feedback_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_key TEXT NOT NULL,
        label TEXT NOT NULL,
        source TEXT NOT NULL,
        sender TEXT NOT NULL,
        primary_domain TEXT,
        risk_score REAL,
        notes TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE detection_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'detection_settings',
      <String, Object>{
        'key': _warningThresholdKey,
        'value': '0.42',
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      'detection_settings',
      <String, Object>{
        'key': _quarantineThresholdKey,
        'value': '0.72',
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.execute('''
      CREATE INDEX idx_screening_results_provider_id
      ON screening_results(provider_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_screening_results_needs_rescan
      ON screening_results(needs_rescan, source, updated_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX idx_feedback_logs_label
      ON feedback_logs(label)
    ''');
  }

  Future<double> getWarningThreshold({
    double fallback = 0.42,
  }) async {
    return _getDoubleSetting(_warningThresholdKey, fallback);
  }

  Future<double> getQuarantineThreshold({
    double fallback = 0.72,
  }) async {
    return _getDoubleSetting(_quarantineThresholdKey, fallback);
  }

  Future<String?> getSetting(String key) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memorySettings[key];
    }
    final rows = await db.query(
      'detection_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object>[key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value']?.toString();
  }

  Future<void> setSetting({
    required String key,
    required String value,
  }) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memorySettings[key] = value;
      return;
    }
    await db.insert(
      'detection_settings',
      <String, Object>{
        'key': key,
        'value': value,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<double> _getDoubleSetting(String key, double fallback) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return double.tryParse(_memorySettings[key] ?? '') ?? fallback;
    }
    final rows = await db.query(
      'detection_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object>[key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return fallback;
    }
    return double.tryParse(rows.first['value']?.toString() ?? '') ?? fallback;
  }

  Future<void> setThresholds({
    required double warningThreshold,
    required double quarantineThreshold,
  }) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memorySettings[_warningThresholdKey] = warningThreshold.toString();
      _memorySettings[_quarantineThresholdKey] = quarantineThreshold.toString();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((Transaction txn) async {
      await txn.insert(
        'detection_settings',
        <String, Object>{
          'key': _warningThresholdKey,
          'value': warningThreshold.toString(),
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'detection_settings',
        <String, Object>{
          'key': _quarantineThresholdKey,
          'value': quarantineThreshold.toString(),
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<TrustedDomainModel>> listTrustedDomains() async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryTrustedDomains.values.toList(growable: false);
    }
    final rows = await db.query(
      'trusted_domains',
      orderBy: 'domain ASC',
    );
    return rows
        .map((Map<String, Object?> row) =>
            TrustedDomainModel.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  Future<void> upsertTrustedDomain({
    required String domain,
    required String source,
    String? note,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final model = TrustedDomainModel(
      domain: domain,
      source: source,
      note: note,
      createdAtMs: now,
      updatedAtMs: now,
    );
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryTrustedDomains[domain] = model;
      return;
    }
    await db.insert(
      'trusted_domains',
      <String, Object?>{
        'domain': domain,
        'source': source,
        'note': note,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<TrustedDomainModel?> getTrustedDomain(String domain) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryTrustedDomains[domain];
    }
    final rows = await db.query(
      'trusted_domains',
      where: 'domain = ?',
      whereArgs: <Object>[domain],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return TrustedDomainModel.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<bool> isTrustedDomain(String domain) async {
    return (await getTrustedDomain(domain)) != null;
  }

  Future<void> saveScreeningResult({
    required DetectionResultModel result,
    required ScreenedMessageModel message,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryScreeningResults[result.messageKey] = _MemoryScreeningRecord(
        result: result,
        message: message,
      );
      return;
    }
    await db.insert(
      'screening_results',
      <String, Object?>{
        'message_key': result.messageKey,
        'source': message.source,
        'sender': message.sender,
        'peer': message.peer,
        'body_preview': _buildBodyPreview(message.body),
        'body_hash': computeBodyHash(message.body),
        'raw_body': message.body,
        'timestamp_ms': message.timestampMs,
        'provider_id': message.providerId,
        'provider_thread_id': message.providerThreadId,
        'sim_slot': message.simSlot,
        'subscription_id': message.subscriptionId,
        'has_url': result.hasUrl ? 1 : 0,
        'extracted_urls_json': jsonEncode(result.extractedUrls),
        'primary_url': result.primaryUrl,
        'primary_domain': result.primaryDomain,
        'trusted_match': result.trustedMatch ? 1 : 0,
        'ml_invoked': result.mlInvoked ? 1 : 0,
        'raw_logits_json': jsonEncode(result.rawLogits),
        'risk_score': result.riskScore,
        'warning_threshold': result.warningThreshold,
        'quarantine_threshold': result.quarantineThreshold,
        'decision': result.decision,
        'reason': result.reason,
        'explanations_json': jsonEncode(result.explanations),
        'needs_rescan': result.needsRescan ? 1 : 0,
        'heuristic_score': result.heuristicScore,
        'model_score': result.modelScore,
        'risk_level': result.riskLevel,
        'detection_source': result.detectionSource,
        'pipeline_stage': result.pipelineStage,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> bindProviderIdentity({
    required String messageKey,
    int? providerId,
    String? providerThreadId,
  }) async {
    if (messageKey.trim().isEmpty) {
      return;
    }
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final existing = _memoryScreeningResults[messageKey];
      if (existing != null) {
        _memoryScreeningResults[messageKey] = _MemoryScreeningRecord(
          result: existing.result,
          message: existing.message.copyWith(
            providerId: providerId,
            providerThreadId: providerThreadId,
          ),
        );
      }
      return;
    }
    await db.update(
      'screening_results',
      <String, Object?>{
        'provider_id': providerId,
        'provider_thread_id': providerThreadId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'message_key = ?',
      whereArgs: <Object>[messageKey],
    );
  }

  Future<DetectionResultModel?> getScreeningResultByMessageKey(
    String messageKey,
  ) async {
    if (messageKey.trim().isEmpty) {
      return null;
    }
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryScreeningResults[messageKey]?.result;
    }
    final rows = await db.query(
      'screening_results',
      where: 'message_key = ?',
      whereArgs: <Object>[messageKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _resultFromRow(rows.first);
  }

  Future<Map<int, DetectionResultModel>> getScreeningResultsForProviderIds(
    Iterable<int> providerIds,
  ) async {
    final ids = providerIds.where((int id) => id > 0).toSet().toList(growable: false);
    if (ids.isEmpty) {
      return <int, DetectionResultModel>{};
    }
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final results = <int, DetectionResultModel>{};
      for (final record in _memoryScreeningResults.values) {
        final providerId = record.message.providerId;
        if (providerId != null && ids.contains(providerId)) {
          results[providerId] = record.result;
        }
      }
      return results;
    }
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM screening_results WHERE provider_id IN ($placeholders)',
      ids,
    );
    final results = <int, DetectionResultModel>{};
    for (final row in rows) {
      final providerId = (row['provider_id'] as num?)?.toInt();
      if (providerId == null || providerId <= 0) {
        continue;
      }
      results[providerId] = _resultFromRow(row);
    }
    return results;
  }

  Future<List<ScreenedMessageModel>> listPendingRescanMessages({
    int limit = 20,
  }) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      return _memoryScreeningResults.values
          .where((record) =>
              record.result.needsRescan && record.message.source.startsWith('sms'))
          .map((record) => record.message)
          .take(limit)
          .toList(growable: false);
    }
    final rows = await db.query(
      'screening_results',
      where: 'needs_rescan = 1 AND source = ?',
      whereArgs: <Object>['sms'],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_screenedMessageFromRow).toList(growable: false);
  }

  Future<void> logFeedback(FeedbackLogModel log) async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      _memoryFeedbackLogs.add(log);
      return;
    }
    await db.insert(
      'feedback_logs',
      <String, Object?>{
        'message_key': log.messageKey,
        'label': log.label,
        'source': log.source,
        'sender': log.sender,
        'primary_domain': log.primaryDomain,
        'risk_score': log.riskScore,
        'notes': log.notes,
        'created_at': log.createdAtMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, int>> getFeedbackStats() async {
    final db = await _maybeOpenDatabase();
    if (db == null) {
      final stats = <String, int>{
        'false_positive': 0,
        'false_negative': 0,
        'confirmed_smishing': 0,
      };
      for (final log in _memoryFeedbackLogs) {
        if (stats.containsKey(log.label)) {
          stats[log.label] = stats[log.label]! + 1;
        }
      }
      return stats;
    }
    final rows = await db.rawQuery('''
      SELECT label, COUNT(*) AS total
      FROM feedback_logs
      GROUP BY label
    ''');
    final stats = <String, int>{
      'false_positive': 0,
      'false_negative': 0,
      'confirmed_smishing': 0,
    };
    for (final row in rows) {
      final label = row['label']?.toString() ?? '';
      if (stats.containsKey(label)) {
        stats[label] = (row['total'] as num?)?.toInt() ?? 0;
      }
    }
    return stats;
  }

  static String computeBodyHash(String text) {
    final bytes = utf8.encode(text.trim());
    var hash = 0xcbf29ce484222325;
    for (final int byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16);
  }

  DetectionResultModel _resultFromRow(Map<String, Object?> row) {
    return DetectionResultModel.fromMap(<String, dynamic>{
      'messageKey': row['message_key'],
      'hasUrl': (row['has_url'] as num?)?.toInt() == 1,
      'extractedUrls': _decodeStringList(row['extracted_urls_json']),
      'primaryUrl': row['primary_url'],
      'primaryDomain': row['primary_domain'],
      'trustedMatch': (row['trusted_match'] as num?)?.toInt() == 1,
      'mlInvoked': (row['ml_invoked'] as num?)?.toInt() == 1,
      'rawLogits': _decodeDoubleList(row['raw_logits_json']),
      'riskScore': row['risk_score'],
      'warningThreshold': row['warning_threshold'],
      'quarantineThreshold': row['quarantine_threshold'],
      'decision': row['decision'],
      'reason': row['reason'],
      'explanations': _decodeStringList(row['explanations_json']),
      'needsRescan': (row['needs_rescan'] as num?)?.toInt() == 1,
      'heuristicScore': row['heuristic_score'],
      'modelScore': row['model_score'],
      'riskLevel': row['risk_level'],
      'detectionSource': row['detection_source'],
      'pipelineStage': row['pipeline_stage'],
    });
  }

  ScreenedMessageModel _screenedMessageFromRow(Map<String, Object?> row) {
    return ScreenedMessageModel(
      source: row['source']?.toString() ?? 'sms',
      sender: row['sender']?.toString() ?? '',
      peer: row['peer']?.toString(),
      body: row['raw_body']?.toString() ?? '',
      timestampMs: (row['timestamp_ms'] as num?)?.toInt() ?? 0,
      messageKey: row['message_key']?.toString() ?? '',
      providerId: (row['provider_id'] as num?)?.toInt(),
      providerThreadId: row['provider_thread_id']?.toString(),
      simSlot: (row['sim_slot'] as num?)?.toInt(),
      subscriptionId: (row['subscription_id'] as num?)?.toInt(),
    );
  }

  List<String> _decodeStringList(Object? raw) {
    if (raw == null) {
      return const <String>[];
    }
    try {
      final decoded = jsonDecode(raw.toString()) as List<dynamic>;
      return decoded
          .map((dynamic item) => item.toString())
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  List<double> _decodeDoubleList(Object? raw) {
    if (raw == null) {
      return const <double>[];
    }
    try {
      final decoded = jsonDecode(raw.toString()) as List<dynamic>;
      return decoded
          .map((dynamic item) => (item as num).toDouble())
          .toList(growable: false);
    } catch (_) {
      return const <double>[];
    }
  }

  String _buildBodyPreview(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.length <= 180 ? trimmed : '${trimmed.substring(0, 177)}...';
  }
}

class _MemoryScreeningRecord {
  const _MemoryScreeningRecord({
    required this.result,
    required this.message,
  });

  final DetectionResultModel result;
  final ScreenedMessageModel message;
}
