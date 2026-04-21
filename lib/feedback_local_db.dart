import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

class FeedbackLocalDb {
  static Database? _db;
  static const String _tableName = 'feedback_buffer';

  /// Initializes the SQLCipher encrypted database
  static Future<Database> get database async {
    if (_db != null) return _db!;
    
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'smishing_shield_secure.db');
    
    // In a full production app, this password should be generated securely 
    // and stored in flutter_secure_storage.
    _db = await openDatabase(
      path,
      password: 'thesis_secure_local_key_2024',
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            label TEXT,
            aiPrediction TEXT,
            userCorrection TEXT,
            source TEXT,
            senderType TEXT,
            messageSanitized TEXT,
            messageLength INTEGER,
            hasUrl INTEGER,
            appVersion TEXT
          )
        ''');
      },
    );
    return _db!;
  }

  static Future<int> insertFeedback(Map<String, dynamic> data) async {
    final db = await database;
    return await db.insert(_tableName, data);
  }

  static Future<List<Map<String, dynamic>>> getUnsyncedFeedback() async {
    final db = await database;
    return await db.query(_tableName);
  }

  static Future<void> deleteFeedbackBatch(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete(
      _tableName,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }
}