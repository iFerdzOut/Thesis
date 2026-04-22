import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class LocalMessageCacheService {
  LocalMessageCacheService._internal();

  static final LocalMessageCacheService _instance =
      LocalMessageCacheService._internal();
  factory LocalMessageCacheService() => _instance;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _dbPasswordKey = 'e2ee_cache_db_password_v1';

  Database? _database;
  Future<Database>? _databaseFuture;
  static const int _schemaVersion = 4;

  Future<void> initialize() async {
    await _openDatabase();
  }

  Future<Database> _openDatabase() async {
    if (_database != null) return _database!;
    if (_databaseFuture != null) return _databaseFuture!;

    _databaseFuture = () async {
      final directory = await getApplicationDocumentsDirectory();
      final dbPath = p.join(directory.path, 'smishing_chat_cache.db');
      final password = await _getDatabasePassword();
      final database = await openDatabase(
        dbPath,
        password: password,
        version: _schemaVersion,
        onCreate: (db, version) async => _createSchema(db),
        onUpgrade: (db, oldVersion, newVersion) async {
          await _upgradeSchema(db, oldVersion, newVersion);
        },
      );
      _database = database;
      return database;
    }();

    try {
      return await _databaseFuture!;
    } finally {
      _databaseFuture = null;
    }
  }

  Future<String> _getDatabasePassword() async {
    final existing = await _secureStorage.read(key: _dbPasswordKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final random = Random.secure();
    final bytes = List<int>.generate(48, (_) => random.nextInt(256));
    final password = base64UrlEncode(bytes);
    await _secureStorage.write(key: _dbPasswordKey, value: password);
    return password;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE decrypted_messages (
        user_id TEXT NOT NULL,
        message_key TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        message_id TEXT,
        client_message_id TEXT,
        sender_id TEXT NOT NULL,
        receiver_id TEXT NOT NULL,
        message_type TEXT NOT NULL,
        plaintext TEXT,
        preview_text TEXT,
        decryption_status TEXT NOT NULL DEFAULT 'pending',
        failure_reason TEXT,
        algorithm TEXT,
        message_timestamp_ms INTEGER,
        cipher_text_present INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        is_suspicious INTEGER NOT NULL DEFAULT 0,
        safety_status TEXT NOT NULL DEFAULT 'safe',
        risk_score REAL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, message_key)
      )
    ''');
    await db.execute('''
      CREATE TABLE preview_cache (
        user_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        last_message_id TEXT,
        preview_text TEXT NOT NULL,
        preview_type TEXT NOT NULL,
        decryption_status TEXT NOT NULL DEFAULT 'pending',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, conversation_id)
      )
    ''');
    await _createMediaCacheSchema(db);
    await _createIndexes(db);
  }

  Future<void> _createMediaCacheSchema(Database db) async {
    await db.execute('''
      CREATE TABLE decrypted_media_cache (
        user_id TEXT NOT NULL,
        message_key TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        message_id TEXT,
        client_message_id TEXT,
        sender_id TEXT NOT NULL,
        receiver_id TEXT NOT NULL,
        message_type TEXT NOT NULL,
        file_name TEXT,
        local_file_path TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, message_key)
      )
    ''');
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_decrypted_messages_conversation_time
      ON decrypted_messages(user_id, conversation_id, message_timestamp_ms DESC, updated_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_decrypted_messages_message_id
      ON decrypted_messages(user_id, message_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_decrypted_messages_client_message_id
      ON decrypted_messages(user_id, client_message_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_decrypted_media_cache_message_id
      ON decrypted_media_cache(user_id, message_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_decrypted_media_cache_client_message_id
      ON decrypted_media_cache(user_id, client_message_id)
    ''');
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN preview_text TEXT",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN decryption_status TEXT NOT NULL DEFAULT 'pending'",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN failure_reason TEXT",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN algorithm TEXT",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN message_timestamp_ms INTEGER",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN cipher_text_present INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN is_suspicious INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE preview_cache ADD COLUMN decryption_status TEXT NOT NULL DEFAULT 'pending'",
      );
      await db.execute(
        "UPDATE decrypted_messages SET preview_text = COALESCE(preview_text, plaintext), decryption_status = COALESCE(decryption_status, 'success'), message_timestamp_ms = COALESCE(message_timestamp_ms, updated_at), cipher_text_present = COALESCE(cipher_text_present, 0), is_deleted = COALESCE(is_deleted, 0), is_suspicious = COALESCE(is_suspicious, 0)",
      );
      await db.execute(
        "UPDATE preview_cache SET decryption_status = COALESCE(decryption_status, 'success')",
      );
      await _createIndexes(db);
    }
    if (oldVersion < 3) {
      await _createMediaCacheSchema(db);
      await _createIndexes(db);
    }
    if (oldVersion < 4) {
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN safety_status TEXT NOT NULL DEFAULT 'safe'",
      );
      await db.execute(
        "ALTER TABLE decrypted_messages ADD COLUMN risk_score REAL",
      );
      await db.execute(
        "UPDATE decrypted_messages SET safety_status = CASE WHEN is_suspicious = 1 THEN 'malicious' ELSE 'safe' END WHERE safety_status IS NULL OR safety_status = ''",
      );
    }
  }

  Future<Directory> _decryptedMediaDirectory(String userId) async {
    final directory = await getApplicationSupportDirectory();
    final userDir = Directory(
      p.join(
        directory.path,
        'smishing_media_cache',
        _safeMediaCacheComponent(userId),
      ),
    );
    if (!await userDir.exists()) {
      await userDir.create(recursive: true);
    }
    return userDir;
  }

  String _safeMediaCacheComponent(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'default';
    final encoded = base64UrlEncode(utf8.encode(trimmed)).replaceAll('=', '');
    if (encoded.isEmpty) return 'default';
    return encoded.length > 120 ? encoded.substring(0, 120) : encoded;
  }

  String _normalizedMediaExtension(String? fileName) {
    final ext = p.extension(fileName?.trim() ?? '').toLowerCase();
    if (ext.isEmpty) return '.bin';
    if (ext.length > 12) return '.bin';
    if (!RegExp(r'^\.[a-z0-9]+$').hasMatch(ext)) return '.bin';
    return ext;
  }

  Future<String> _buildDecryptedMediaPath({
    required String userId,
    required String messageKey,
    String? fileName,
  }) async {
    final directory = await _decryptedMediaDirectory(userId);
    return p.join(
      directory.path,
      '${_safeMediaCacheComponent(messageKey)}${_normalizedMediaExtension(fileName)}',
    );
  }

  Future<void> saveDecryptedMessage({
    required String userId,
    required String messageKey,
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String senderId,
    required String receiverId,
    required String messageType,
    required String plaintext,
  }) async {
    await upsertMessageProjection(
      userId: userId,
      messageKey: messageKey,
      conversationId: conversationId,
      messageId: messageId,
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: messageType,
      plaintext: plaintext,
      previewText: plaintext,
      decryptionStatus: 'success',
      failureReason: null,
      algorithm: null,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      cipherTextPresent: true,
      isDeleted: false,
      isSuspicious: false,
    );
  }

  Future<void> upsertMessageProjection({
    required String userId,
    required String messageKey,
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String senderId,
    required String receiverId,
    required String messageType,
    required String? plaintext,
    required String previewText,
    required String decryptionStatus,
    required String? failureReason,
    required String? algorithm,
    required int timestampMs,
    required bool cipherTextPresent,
    required bool isDeleted,
    required bool isSuspicious,
    String safetyStatus = 'safe',
    double? riskScore,
  }) async {
    final db = await _openDatabase();
    await db.insert(
      'decrypted_messages',
      {
        'user_id': userId,
        'message_key': messageKey,
        'conversation_id': conversationId,
        'message_id': messageId,
        'client_message_id': clientMessageId,
        'sender_id': senderId,
        'receiver_id': receiverId,
        'message_type': messageType,
        'plaintext': plaintext ?? '',
        'preview_text': previewText,
        'decryption_status': decryptionStatus,
        'failure_reason': failureReason,
        'algorithm': algorithm,
        'message_timestamp_ms': timestampMs,
        'cipher_text_present': cipherTextPresent ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'is_suspicious': isSuspicious ? 1 : 0,
        'safety_status': safetyStatus,
        'risk_score': riskScore,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateMessageProjectionStatus({
    required String userId,
    required String clientMessageId,
    required Map<String, Object?> updates,
  }) async {
    final db = await _openDatabase();
    final updateData = Map<String, Object?>.from(updates);
    updateData['updated_at'] = DateTime.now().millisecondsSinceEpoch;

    await db.update(
      'decrypted_messages',
      updateData,
      where: 'user_id = ? AND client_message_id = ?',
      whereArgs: [userId, clientMessageId],
    );
  }

  Future<void> saveDecryptedMedia({
    required String userId,
    required String messageKey,
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String senderId,
    required String receiverId,
    required String messageType,
    required String? fileName,
    required Uint8List bytes,
  }) async {
    if (messageKey.trim().isEmpty || bytes.isEmpty) {
      return;
    }

    final db = await _openDatabase();
    final existing = await readDecryptedMediaEntryByIds(
      userId: userId,
      messageKey: messageKey,
    );
    final previousPath = existing?['local_file_path']?.toString().trim() ?? '';
    final newPath = await _buildDecryptedMediaPath(
      userId: userId,
      messageKey: messageKey,
      fileName: fileName,
    );
    await File(newPath).writeAsBytes(bytes, flush: false);
    if (previousPath.isNotEmpty && previousPath != newPath) {
      try {
        final oldFile = File(previousPath);
        if (await oldFile.exists()) {
          await oldFile.delete();
        }
      } catch (_) {}
    }

    await db.insert(
      'decrypted_media_cache',
      {
        'user_id': userId,
        'message_key': messageKey,
        'conversation_id': conversationId,
        'message_id': messageId,
        'client_message_id': clientMessageId,
        'sender_id': senderId,
        'receiver_id': receiverId,
        'message_type': messageType,
        'file_name': fileName,
        'local_file_path': newPath,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> readDecryptedMediaEntryByIds({
    required String userId,
    String? messageKey,
    String? messageId,
    String? clientMessageId,
  }) async {
    final db = await _openDatabase();
    final clauses = <String>[];
    final args = <Object?>[userId];
    if (messageKey != null && messageKey.trim().isNotEmpty) {
      clauses.add('message_key = ?');
      args.add(messageKey.trim());
    }
    if (messageId != null && messageId.trim().isNotEmpty) {
      clauses.add('message_id = ?');
      args.add(messageId.trim());
    }
    if (clientMessageId != null && clientMessageId.trim().isNotEmpty) {
      clauses.add('client_message_id = ?');
      args.add(clientMessageId.trim());
    }
    if (clauses.isEmpty) return null;

    final rows = await db.query(
      'decrypted_media_cache',
      where: 'user_id = ? AND (${clauses.join(' OR ')})',
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Uint8List?> readDecryptedMediaBytes({
    required String userId,
    String? messageKey,
    String? messageId,
    String? clientMessageId,
    String? fileName,
  }) async {
    final row = await readDecryptedMediaEntryByIds(
      userId: userId,
      messageKey: messageKey,
      messageId: messageId,
      clientMessageId: clientMessageId,
    );
    if (row == null) {
      return _readDecryptedMediaBytesFromFallbackFiles(
        userId: userId,
        fileName: fileName,
        messageKeys: <String?>[messageKey, clientMessageId, messageId],
      );
    }

    final filePath = row['local_file_path']?.toString().trim() ?? '';
    if (filePath.isEmpty) {
      return null;
    }

    final file = File(filePath);
    if (!await file.exists()) {
      final cachedMessageKey = row['message_key']?.toString().trim() ?? '';
      if (cachedMessageKey.isNotEmpty) {
        await deleteDecryptedMediaCacheEntry(
          userId: userId,
          messageKey: cachedMessageKey,
        );
      }
      return _readDecryptedMediaBytesFromFallbackFiles(
        userId: userId,
        fileName: fileName ?? row['file_name']?.toString(),
        messageKeys: <String?>[
          cachedMessageKey,
          row['client_message_id']?.toString(),
          row['message_id']?.toString(),
          messageKey,
          clientMessageId,
          messageId,
        ],
      );
    }

    return file.readAsBytes();
  }

  Future<Uint8List?> _readDecryptedMediaBytesFromFallbackFiles({
    required String userId,
    required Iterable<String?> messageKeys,
    String? fileName,
  }) async {
    final seen = <String>{};
    for (final rawKey in messageKeys) {
      final trimmedKey = rawKey?.trim() ?? '';
      if (trimmedKey.isEmpty || !seen.add(trimmedKey)) {
        continue;
      }
      final candidatePath = await _buildDecryptedMediaPath(
        userId: userId,
        messageKey: trimmedKey,
        fileName: fileName,
      );
      final candidateFile = File(candidatePath);
      if (await candidateFile.exists()) {
        try {
          return await candidateFile.readAsBytes();
        } catch (_) {}
      }
    }
    return null;
  }

  Future<void> deleteDecryptedMediaCacheEntry({
    required String userId,
    required String messageKey,
  }) async {
    final trimmedKey = messageKey.trim();
    if (trimmedKey.isEmpty) return;

    final db = await _openDatabase();
    final rows = await db.query(
      'decrypted_media_cache',
      columns: ['local_file_path'],
      where: 'user_id = ? AND message_key = ?',
      whereArgs: [userId, trimmedKey],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final filePath = rows.first['local_file_path']?.toString().trim() ?? '';
      if (filePath.isNotEmpty) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
    }

    await db.delete(
      'decrypted_media_cache',
      where: 'user_id = ? AND message_key = ?',
      whereArgs: [userId, trimmedKey],
    );
  }

  Future<void> clearDecryptedMediaCacheForUser(String userId) async {
    final trimmedUserId = userId.trim();
    if (trimmedUserId.isEmpty) return;

    final db = await _openDatabase();
    final rows = await db.query(
      'decrypted_media_cache',
      columns: ['local_file_path'],
      where: 'user_id = ?',
      whereArgs: [trimmedUserId],
    );

    for (final row in rows) {
      final filePath = row['local_file_path']?.toString().trim() ?? '';
      if (filePath.isEmpty) continue;
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    await db.delete(
      'decrypted_media_cache',
      where: 'user_id = ?',
      whereArgs: [trimmedUserId],
    );

    try {
      final userDir = await _decryptedMediaDirectory(trimmedUserId);
      if (await userDir.exists()) {
        await userDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<String?> readDecryptedMessage({
    required String userId,
    required String messageKey,
  }) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'decrypted_messages',
      columns: ['plaintext'],
      where: 'user_id = ? AND message_key = ?',
      whereArgs: [userId, messageKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['plaintext']?.toString();
  }

  Future<Map<String, dynamic>?> readMessageProjectionByIds({
    required String userId,
    String? messageKey,
    String? messageId,
    String? clientMessageId,
  }) async {
    final db = await _openDatabase();

    if (messageId != null && messageId.trim().isNotEmpty) {
      final rows = await db.query(
        'decrypted_messages',
        where: 'user_id = ? AND message_id = ?',
        whereArgs: [userId, messageId.trim()],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first;
    }

    if (clientMessageId != null && clientMessageId.trim().isNotEmpty) {
      final rows = await db.query(
        'decrypted_messages',
        where: 'user_id = ? AND client_message_id = ?',
        whereArgs: [userId, clientMessageId.trim()],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first;
    }

    if (messageKey != null && messageKey.trim().isNotEmpty) {
      final rows = await db.query(
        'decrypted_messages',
        where: 'user_id = ? AND message_key = ?',
        whereArgs: [userId, messageKey.trim()],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first;
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> readConversationMessages({
    required String userId,
    required String conversationId,
  }) async {
    final db = await _openDatabase();
    return db.query(
      'decrypted_messages',
      where: 'user_id = ? AND conversation_id = ?',
      whereArgs: [userId, conversationId],
      orderBy: 'message_timestamp_ms DESC, updated_at DESC',
    );
  }

  Future<void> saveConversationPreview({
    required String userId,
    required String conversationId,
    required String previewText,
    required String previewType,
    required String? lastMessageId,
    String decryptionStatus = 'success',
  }) async {
    final db = await _openDatabase();
    await db.insert(
      'preview_cache',
      {
        'user_id': userId,
        'conversation_id': conversationId,
        'last_message_id': lastMessageId,
        'preview_text': previewText,
        'preview_type': previewType,
        'decryption_status': decryptionStatus,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> readConversationPreview({
    required String userId,
    required String conversationId,
  }) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'preview_cache',
      where: 'user_id = ? AND conversation_id = ?',
      whereArgs: [userId, conversationId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> exportAllMessages(String userId) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'decrypted_messages',
      where: 'user_id = ? AND is_deleted = 0',
      whereArgs: [userId],
      orderBy: 'message_timestamp_ms ASC',
    );
    return rows.map((row) {
      final out = <String, dynamic>{};
      for (final e in row.entries) {
        out[e.key] = e.value;
      }
      return out;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> exportAllMessagesSince(
    String userId,
    int sinceTimestampMs,
  ) async {
    final db = await _openDatabase();
    final rows = await db.query(
      'decrypted_messages',
      where: 'user_id = ? AND is_deleted = 0 AND updated_at > ?',
      whereArgs: [userId, sinceTimestampMs],
      orderBy: 'updated_at ASC',
    );
    return rows.map((row) {
      final out = <String, dynamic>{};
      for (final e in row.entries) {
        out[e.key] = e.value;
      }
      return out;
    }).toList();
  }

  Future<void> importAllMessages(
    String userId,
    List<dynamic> rows,
  ) async {
    if (rows.isEmpty) return;
    final db = await _openDatabase();
    await db.transaction((txn) async {
      for (final row in rows) {
        if (row is! Map) continue;
        final normalized = <String, Object?>{};
        for (final e in row.entries) {
          normalized[e.key.toString()] = e.value;
        }
        normalized['user_id'] = userId;
        try {
          await txn.insert(
            'decrypted_messages',
            normalized,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        } catch (_) {}
      }
    });
  }
}
