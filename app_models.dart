class UserProfile {
  final String uid;
  final String userId;
  final String name;
  final String? photoPath;
  const UserProfile({
    required this.uid,
    required this.userId,
    required this.name,
    this.photoPath,
  });

  Map<String, dynamic> toMap() => {
    'uid': uid, 'userId': userId, 'name': name, 'photoPath': photoPath,
  };

  factory UserProfile.fromMap(Map<String, dynamic> map) => UserProfile(
    uid: map['uid'] as String,
    userId: map['userId'] as String,
    name: map['name'] as String,
    photoPath: map['photoPath'] as String?,
  );
}

class ChatMessage {
  final String id;
  final String chatId;
  final String senderUid;
  final String senderName;
  final String body;
  final DateTime sentAt;
  final String source;

  const ChatMessage({
    required this.id, required this.chatId, required this.senderUid,
    required this.senderName, required this.body, required this.sentAt,
    this.source = 'online',
  });

  Map<String, dynamic> toMap() => {
    'id': id, 'chatId': chatId, 'senderUid': senderUid,
    'senderName': senderName, 'body': body,
    'sentAt': sentAt.millisecondsSinceEpoch, 'source': source,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'] as String,
    chatId: map['chatId'] as String,
    senderUid: map['senderUid'] as String,
    senderName: (map['senderName'] ?? 'Pengguna') as String,
    body: map['body'] as String,
    sentAt: map['sentAt'] is int
        ? DateTime.fromMillisecondsSinceEpoch(map['sentAt'] as int)
        : (map['sentAt'] as dynamic).toDate() as DateTime,
    source: (map['source'] ?? 'online') as String,
  );
}

class Contact {
  final String uid;
  final String userId;
  final String name;
  final String? photoUrl;
  const Contact({
    required this.uid, required this.userId, required this.name,
    this.photoUrl,
  });
}
