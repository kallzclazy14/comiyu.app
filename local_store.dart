import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/app_models.dart';

/// Penyimpanan pesan lokal dan antrean kirim online yang tahan restart.
class LocalStore {
  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final base = await getDatabasesPath();
    _db = await openDatabase(p.join(base, 'comiyu_hybrid.db'),
      version: 2,
      onCreate: (database, version) async {
        await database.execute('''CREATE TABLE local_messages(
          id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, sender_uid TEXT NOT NULL,
          sender_name TEXT NOT NULL, body TEXT NOT NULL, sent_at INTEGER NOT NULL,
          source TEXT NOT NULL)''');
        await database.execute('''CREATE TABLE lan_contacts(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT NOT NULL,
          port INTEGER NOT NULL)''');
        await database.execute('''CREATE TABLE pending_messages(
          id TEXT PRIMARY KEY, peer_uid TEXT NOT NULL, sender_uid TEXT NOT NULL,
          sender_name TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0)''');
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute('''CREATE TABLE pending_messages(
            id TEXT PRIMARY KEY, peer_uid TEXT NOT NULL, sender_uid TEXT NOT NULL,
            sender_name TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0)''');
        }
      });
    return _db!;
  }

  Future<void> saveMessage(ChatMessage message) async {
    final database = await db;
    await database.insert('local_messages', {
      'id': message.id, 'chat_id': message.chatId,
      'sender_uid': message.senderUid, 'sender_name': message.senderName,
      'body': message.body, 'sent_at': message.sentAt.millisecondsSinceEpoch,
      'source': message.source,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<ChatMessage>> getMessages(String chatId) async {
    final database = await db;
    final rows = await database.query('local_messages', where: 'chat_id = ?',
      whereArgs: [chatId], orderBy: 'sent_at ASC, id ASC');
    return rows.map((row) => ChatMessage(
      id: row['id'] as String, chatId: row['chat_id'] as String,
      senderUid: row['sender_uid'] as String, senderName: row['sender_name'] as String,
      body: row['body'] as String,
      sentAt: DateTime.fromMillisecondsSinceEpoch(row['sent_at'] as int),
      source: row['source'] as String)).toList();
  }

  Future<void> enqueueMessage({required String id, required String peerUid,
    required String senderUid, required String senderName, required String body,
    required DateTime createdAt}) async {
    final database = await db;
    await database.insert('pending_messages', {
      'id': id, 'peer_uid': peerUid, 'sender_uid': senderUid,
      'sender_name': senderName, 'body': body,
      'created_at': createdAt.millisecondsSinceEpoch, 'attempts': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, Object?>>> pendingMessages() async {
    final database = await db;
    return database.query('pending_messages', orderBy: 'created_at ASC');
  }

  Future<void> updateMessageChatId(String id, String chatId) async {
    final database = await db;
    await database.update('local_messages', {'chat_id': chatId}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markMessageSent(String id) async {
    final database = await db;
    await database.delete('pending_messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> recordSendFailure(String id) async {
    final database = await db;
    await database.rawUpdate('UPDATE pending_messages SET attempts = attempts + 1 WHERE id = ?', [id]);
  }

  Future<void> saveLanContact({required String id, required String name,
    required String address, required int port}) async {
    final database = await db;
    await database.insert('lan_contacts', {
      'id': id, 'name': name, 'address': address, 'port': port,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> getLanContacts() async {
    final database = await db;
    return database.query('lan_contacts', orderBy: 'name COLLATE NOCASE');
  }
}
