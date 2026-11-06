import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/app_models.dart';

/// Layanan online. Gunakan Firebase Authentication anonim dan Firestore.
class FirebaseChatService {
  final FirebaseAuth auth;
  final FirebaseFirestore firestore;

  FirebaseChatService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : auth = auth ?? FirebaseAuth.instance,
        firestore = firestore ?? FirebaseFirestore.instance;

  Future<User> signIn() async {
    final existing = auth.currentUser;
    if (existing != null) return existing;
    final result = await auth.signInAnonymously();
    return result.user!;
  }

  String conversationId(String uidA, String uidB) {
    final ids = [uidA, uidB]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  Future<void> publishProfile(UserProfile profile) async {
    await firestore.collection('users').doc(profile.uid).set({
      'uid': profile.uid,
      'userId': profile.userId,
      'name': profile.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    // Indeks nomor pengguna untuk pencarian kontak.
    await firestore.collection('user_lookup').doc(profile.userId).set({
      'uid': profile.uid,
    }, SetOptions(merge: true));
  }

  Future<Contact?> findContact(String userId) async {
    final lookup = await firestore.collection('user_lookup')
        .doc(userId.trim()).get();
    if (!lookup.exists) return null;
    final uid = lookup.data()?['uid'] as String?;
    if (uid == null || uid == auth.currentUser?.uid) return null;
    final user = await firestore.collection('users').doc(uid).get();
    if (!user.exists) return null;
    final data = user.data()!;
    return Contact(
      uid: uid,
      userId: data['userId'] as String,
      name: data['name'] as String,
    );
  }

  Stream<List<ChatMessage>> watchMessages(String peerUid) {
    final me = auth.currentUser!.uid;
    final id = conversationId(me, peerUid);
    return firestore.collection('conversations').doc(id)
      .collection('messages').orderBy('sentAt')
      .snapshots().map((snapshot) => snapshot.docs.map((doc) {
        final data = doc.data();
        return ChatMessage(
          id: doc.id, chatId: id,
          senderUid: data['senderUid'] as String,
          senderName: data['senderName'] as String? ?? 'Pengguna',
          body: data['body'] as String,
          sentAt: data['sentAt'] is Timestamp
              ? (data['sentAt'] as Timestamp).toDate()
              : DateTime.fromMillisecondsSinceEpoch(data['sentAt'] as int),
          source: 'online',
        );
      }).toList());
  }

  Future<void> sendMessage({
    required Contact peer,
    required UserProfile sender,
    required String body,
    required String messageId,
    required DateTime createdAt,
  }) async {
    final id = conversationId(sender.uid, peer.uid);
    final conversation = firestore.collection('conversations').doc(id);
    await conversation.set({
      'members': ([sender.uid, peer.uid]..sort()),
      'updatedAt': FieldValue.serverTimestamp(),
      'lastMessage': body,
    }, SetOptions(merge: true));
    // ID dokumen berasal dari antrean lokal: retry aman dan idempoten.
    await conversation.collection('messages').doc(messageId).set({
      'senderUid': sender.uid,
      'senderName': sender.name,
      'body': body,
      'sentAt': Timestamp.fromDate(createdAt),
    }, SetOptions(merge: false));
  }
}
