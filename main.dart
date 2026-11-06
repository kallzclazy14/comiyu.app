import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'firebase_options.dart'; // Dibuat melalui: flutterfire configure
import 'models/app_models.dart';
import 'services/firebase_chat_service.dart';
import 'services/lan_service.dart';
import 'services/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    // Firebase belum dikonfigurasi: mode LAN dan penyimpanan lokal tetap bisa dipakai.
  }
  final app = ComiyuState();
  await app.initialize();
  runApp(ChangeNotifierProvider.value(value: app, child: const ComiyuApp()));
}

class ComiyuState extends ChangeNotifier {
  final store = LocalStore();
  FirebaseChatService? online;
  final lan = LanService();
  UserProfile? profile;
  ThemeMode themeMode = ThemeMode.light;
  bool onlineReady = false;
  String connectionLabel = 'Memeriksa koneksi';
  StreamSubscription? _lanSub;
  StreamSubscription? _networkSub;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('user_id');
    final savedName = prefs.getString('user_name');
    if (savedId != null && savedName != null) {
      profile = UserProfile(uid: prefs.getString('local_uid') ?? const Uuid().v4(),
          userId: savedId, name: savedName, photoPath: prefs.getString('user_photo'));
      await ensureOnline(prefs);
    }
    themeMode = prefs.getBool('dark_mode') == true
        ? ThemeMode.dark : ThemeMode.light;

    _lanSub = lan.incomingMessages.listen((message) async {
      await store.saveMessage(message);
      notifyListeners();
    });
    _networkSub = Connectivity().onConnectivityChanged.listen((_) async {
      await checkConnection();
      if (onlineReady) await syncPendingMessages();
    });
    await checkConnection();
    if (onlineReady) await syncPendingMessages();
    notifyListeners();
  }

  Future<void> ensureOnline([SharedPreferences? existingPrefs]) async {
    if (Firebase.apps.isEmpty) { onlineReady = false; return; }
    try {
      online ??= FirebaseChatService();
      final authUser = await online!.signIn();
      if (profile != null) {
        profile = UserProfile(uid: authUser.uid, userId: profile!.userId,
          name: profile!.name, photoPath: profile!.photoPath);
        final prefs = existingPrefs ?? await SharedPreferences.getInstance();
        await prefs.setString('local_uid', authUser.uid);
        await online!.publishProfile(profile!);
      }
      onlineReady = true;
    } catch (_) { onlineReady = false; }
  }

  String generateUserId() =>
      '08${List.generate(10, (_) => Random.secure().nextInt(10)).join()}';

  Future<void> saveProfile(String name, String userId, String? photo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_id', userId);
    await prefs.setString('user_name', name.trim());
    if (photo == null) {
      await prefs.remove('user_photo');
    } else {
      await prefs.setString('user_photo', photo);
    }
    final localUid = prefs.getString('local_uid') ?? const Uuid().v4();
    await prefs.setString('local_uid', localUid);
    profile = UserProfile(uid: online?.auth.currentUser?.uid ?? localUid,
      userId: userId, name: name.trim(), photoPath: photo);
    await ensureOnline(prefs);
    notifyListeners();
  }

  Future<void> checkConnection() async {
    final result = await Connectivity().checkConnectivity();
    final hasNetwork = !result.contains(ConnectivityResult.none);
    connectionLabel = hasNetwork ? 'Jaringan tersedia' : 'Tanpa internet';
    if (hasNetwork && profile != null && !onlineReady) await ensureOnline();
    notifyListeners();
  }

  Future<void> toggleTheme(bool dark) async {
    themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', dark);
    notifyListeners();
  }

  Future<String> startLanHost() => lan.startHost();
  Future<String> joinLan(String address) => lan.connect(address);
  Future<void> stopLan() async {
    await lan.disconnectClient();
    await lan.stopHost();
    notifyListeners();
  }

  Future<void> sendLan(String body) async {
    await lan.send(sender: profile!, body: body);
  }

  Future<void> sendOnlineMessage(Contact peer, String body) async {
    final me = profile!;
    final id = const Uuid().v4();
    final createdAt = DateTime.now();
    final chatId = online!.conversationId(me.uid, peer.uid);
    await store.enqueueMessage(id: id, peerUid: peer.uid, senderUid: me.uid,
      senderName: me.name, body: body, createdAt: createdAt);
    await store.saveMessage(ChatMessage(id: id, chatId: chatId, senderUid: me.uid,
      senderName: me.name, body: body, sentAt: createdAt, source: 'pending'));
    await syncPendingMessages();
    notifyListeners();
  }

  Future<void> syncPendingMessages() async {
    if (!onlineReady || profile == null) return;
    final pending = await store.pendingMessages();
    for (final row in pending) {
      final id = row['id'] as String;
      try {
        final peer = Contact(uid: row['peer_uid'] as String, userId: '', name: 'Pengguna');
        await online!.sendMessage(peer: peer, sender: profile!,
          body: row['body'] as String, messageId: id,
          createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int));
        await store.updateMessageChatId(id, online!.conversationId(profile!.uid, peer.uid));
        await store.markMessageSent(id);
      } catch (_) {
        await store.recordSendFailure(id);
        break; // jangan membanjiri Firestore saat jaringan/server bermasalah
      }
    }
  }

  Future<void> disposeState() async {
    await _lanSub?.cancel();
    await _networkSub?.cancel();
    await lan.dispose();
  }
}

class ComiyuApp extends StatelessWidget {
  const ComiyuApp({super.key});
  @override
  Widget build(BuildContext context) => Consumer<ComiyuState>(
    builder: (context, state, _) {
      const teal = Color(0xFF087E75);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Comiyu App',
        themeMode: state.themeMode,
        theme: ThemeData(useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: teal),
          appBarTheme: const AppBarTheme(backgroundColor: teal, foregroundColor: Colors.white)),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: teal, brightness: Brightness.dark)),
        home: state.profile == null ? const SetupScreen() : const HomeScreen(),
      );
    },
  );
}

Widget avatar(String? path, {double radius = 24}) {
  final ok = path != null && File(path).existsSync();
  return CircleAvatar(radius: radius, backgroundColor: const Color(0xFFB8DCD5),
    backgroundImage: ok ? FileImage(File(path!)) : null,
    child: ok ? null : Icon(Icons.person, color: const Color(0xFF087E75), size: radius));
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override State<SetupScreen> createState() => _SetupScreenState();
}
class _SetupScreenState extends State<SetupScreen> {
  final name = TextEditingController();
  String number = '';
  String? photo;
  @override void initState() { super.initState(); number = context.read<ComiyuState>().generateUserId(); }
  Future<void> pick() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (image != null) setState(() => photo = image.path);
  }
  @override Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24), child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440), child: Column(children: [
          const SizedBox(height: 28),
          const Icon(Icons.forum_rounded, size: 62, color: Color(0xFF087E75)),
          const SizedBox(height: 12),
          const Text('Selamat datang di Comiyu', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const Text('Buat profil untuk mulai terhubung.'),
          const SizedBox(height: 28),
          GestureDetector(onTap: pick, child: avatar(photo, radius: 46)),
          TextButton(onPressed: pick, child: const Text('Pilih foto profil')),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama Pengguna', border: OutlineInputBorder())),
          const SizedBox(height: 14),
          Card(child: ListTile(title: const Text('Nomor Pengguna'),
            subtitle: SelectableText(number, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() => number = context.read<ComiyuState>().generateUserId())))),
          const SizedBox(height: 18),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nama pengguna wajib diisi.')));
                return;
              }
              await context.read<ComiyuState>().saveProfile(name.text, number, photo);
            }, child: const Text('Simpan dan Masuk'))),
        ]),
      ),
    ))),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> addOnlineContact(BuildContext context) async {
    final controller = TextEditingController();
    final id = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Cari pengguna'),
      content: TextField(controller: controller, keyboardType: TextInputType.phone,
        decoration: const InputDecoration(labelText: 'Nomor Pengguna')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Cari')),
      ],
    ));
    controller.dispose();
    if (id == null || id.isEmpty || !context.mounted) return;
    try {
      final service = context.read<ComiyuState>().online;
      if (service == null || !context.read<ComiyuState>().onlineReady) throw StateError('Firebase belum siap.');
      final contact = await service.findContact(id);
      if (!context.mounted) return;
      if (contact == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pengguna tidak ditemukan. Pastikan ia sudah membuat profil online.')));
      } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => OnlineChatScreen(peer: contact)));
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tidak dapat mencari pengguna. Periksa koneksi internet.')));
    }
  }

  Future<void> lanDialog(BuildContext context) async {
    final address = TextEditingController();
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Obrolan jaringan lokal', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Pilih satu perangkat sebagai host. Perangkat lain memasukkan alamat IP host. Keduanya harus berada di Wi-Fi yang sama.'),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          icon: const Icon(Icons.wifi_tethering), label: const Text('Jadikan perangkat ini host'),
          onPressed: () async {
            try {
              final ip = await context.read<ComiyuState>().startLanHost();
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Host aktif. Bagikan alamat $ip:4040 kepada teman.')));
                Navigator.push(context, MaterialPageRoute(builder: (_) => LanChatScreen(roomId: context.read<ComiyuState>().lan.roomId!, title: 'Obrolan Lokal')));
              }
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal membuat host: $e')));
            }
          })),
        TextField(controller: address, decoration: const InputDecoration(labelText: 'Alamat IP host', hintText: 'Contoh: 192.168.1.10')),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          icon: const Icon(Icons.wifi), label: const Text('Gabung ke host'),
          onPressed: () async {
            try {
              final roomId = await context.read<ComiyuState>().joinLan(address.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => LanChatScreen(roomId: roomId, title: 'Obrolan Lokal')));
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tidak dapat terhubung: $e')));
            }
          })),
      ]),
    ));
    address.dispose();
  }

  @override Widget build(BuildContext context) {
    final state = context.watch<ComiyuState>();
    final profile = state.profile!;
    return Scaffold(
      appBar: AppBar(title: const Text('Comiyu App', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())), icon: const Icon(Icons.settings_outlined))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: ListTile(leading: avatar(profile.photoPath), title: Text(profile.name),
          subtitle: Text('${profile.userId} • ${state.connectionLabel}'),
          trailing: Icon(state.onlineReady ? Icons.cloud_done : Icons.cloud_off))),
        const SizedBox(height: 12),
        Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.language)),
          title: const Text('Pesan melalui internet'), subtitle: const Text('Cari teman dengan Nomor Pengguna'),
          trailing: const Icon(Icons.chevron_right), onTap: () => addOnlineContact(context))),
        Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.wifi)),
          title: const Text('Pesan melalui jaringan lokal'), subtitle: const Text('Chat tanpa internet di Wi-Fi yang sama'),
          trailing: const Icon(Icons.chevron_right), onTap: () => lanDialog(context))),
        const SizedBox(height: 14),
        const Text('Riwayat lokal', style: TextStyle(fontWeight: FontWeight.bold)),
        FutureBuilder<List<Map<String, Object?>>>(future: state.store.getLanContacts(),
          builder: (context, snapshot) {
            final rows = snapshot.data ?? [];
            if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(18), child: Text('Belum ada kontak lokal tersimpan.'));
            return Column(children: rows.map((row) => ListTile(
              leading: const CircleAvatar(child: Icon(Icons.wifi)),
              title: Text(row['name'] as String), subtitle: Text(row['address'] as String),
            )).toList());
          }),
      ]),
    );
  }
}

class OnlineChatScreen extends StatefulWidget {
  final Contact peer;
  const OnlineChatScreen({super.key, required this.peer});
  @override State<OnlineChatScreen> createState() => _OnlineChatScreenState();
}
class _OnlineChatScreenState extends State<OnlineChatScreen> {
  final text = TextEditingController();
  final scroll = ScrollController();
  StreamSubscription<List<ChatMessage>>? sub;
  List<ChatMessage> messages = [];
  @override void initState() {
    super.initState();
    final state = context.read<ComiyuState>();
    final service = state.online;
    if (service == null) return;
    sub = service.watchMessages(widget.peer.uid).listen((items) async {
      for (final item in items) { await state.store.saveMessage(item); }
      final local = await state.store.getMessages(service.conversationId(state.profile!.uid, widget.peer.uid));
      final merged = <String, ChatMessage>{for (final m in items) m.id: m};
      for (final m in local) { merged.putIfAbsent(m.id, () => m); }
      final combined = merged.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      if (mounted) setState(() => messages = combined);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
      });
    }, onError: (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gagal memuat pesan online.')));
    });
  }
  Future<void> send() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    text.clear();
    try {
      final state = context.read<ComiyuState>();
      await state.sendOnlineMessage(widget.peer, body);
      final local = await state.store.getMessages(state.online!.conversationId(state.profile!.uid, widget.peer.uid));
      if (mounted) setState(() {
        final merged = <String, ChatMessage>{for (final m in messages) m.id: m};
        for (final m in local) { merged.putIfAbsent(m.id, () => m); }
        messages = merged.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pesan gagal dikirim. Periksa internet.')));
    }
  }
  @override void dispose() { sub?.cancel(); text.dispose(); scroll.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.peer.name, style: const TextStyle(fontSize: 16)),
      Text(widget.peer.userId, style: const TextStyle(fontSize: 11)),
    ])),
    body: Column(children: [
      Expanded(child: ListView.builder(controller: scroll, padding: const EdgeInsets.all(14),
        itemCount: messages.length, itemBuilder: (_, i) => MessageBubble(message: messages[i],
          mine: messages[i].senderUid == context.read<ComiyuState>().profile!.uid))),
      MessageComposer(controller: text, onSend: send),
    ]),
  );
}

class LanChatScreen extends StatefulWidget {
  final String roomId;
  final String title;
  const LanChatScreen({super.key, required this.roomId, required this.title});
  @override State<LanChatScreen> createState() => _LanChatScreenState();
}
class _LanChatScreenState extends State<LanChatScreen> {
  final text = TextEditingController();
  final scroll = ScrollController();
  StreamSubscription? sub;
  List<ChatMessage> messages = [];
  @override void initState() {
    super.initState();
    load();
    sub = context.read<ComiyuState>().lan.incomingMessages.listen((message) {
      if (message.chatId == widget.roomId && mounted && !messages.any((m) => m.id == message.id)) {
        setState(() { messages.add(message); messages.sort((a, b) => a.sentAt.compareTo(b.sentAt)); });
      }
    });
  }
  Future<void> load() async {
    final data = await context.read<ComiyuState>().store.getMessages(widget.roomId);
    if (mounted) setState(() {
      final merged = <String, ChatMessage>{for (final m in data) m.id: m};
      for (final m in messages) { merged.putIfAbsent(m.id, () => m); }
      messages = merged.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    });
  }
  Future<void> send() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    text.clear();
    try {
      await context.read<ComiyuState>().sendLan(body);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Pesan tidak terkirim: $e')));
    }
  }
  @override void dispose() { sub?.cancel(); text.dispose(); scroll.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title), actions: [
      IconButton(tooltip: 'Putuskan koneksi', onPressed: () async {
        await context.read<ComiyuState>().stopLan();
        if (mounted) Navigator.pop(context);
      }, icon: const Icon(Icons.link_off)),
    ]),
    body: Column(children: [
      Expanded(child: ListView.builder(controller: scroll, padding: const EdgeInsets.all(14),
        itemCount: messages.length, itemBuilder: (_, i) => MessageBubble(
          message: messages[i], mine: messages[i].senderUid == context.read<ComiyuState>().profile!.uid))),
      MessageComposer(controller: text, onSend: send),
    ]),
  );
}

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  const MessageBubble({super.key, required this.message, required this.mine});
  @override Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .8),
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.fromLTRB(13, 9, 11, 7),
        decoration: BoxDecoration(color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(15)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (!mine) Align(alignment: Alignment.centerLeft, child: Text(message.senderName,
            style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.bold))),
          Align(alignment: Alignment.centerLeft, child: Text(message.body)),
          const SizedBox(height: 4),
          Text(DateFormat('HH:mm').format(message.sentAt), style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        ]),
      ));
  }
}

class MessageComposer extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const MessageComposer({super.key, required this.controller, required this.onSend});
  @override Widget build(BuildContext context) => SafeArea(top: false,
    child: Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(children: [
        Expanded(child: TextField(controller: controller, minLines: 1, maxLines: 4,
          decoration: InputDecoration(hintText: 'Ketik pesan...', filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)))),
        const SizedBox(width: 8),
        CircleAvatar(backgroundColor: Theme.of(context).colorScheme.primary,
          child: IconButton(onPressed: onSend, icon: const Icon(Icons.send, color: Colors.white))),
      ]),
    ));
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override Widget build(BuildContext context) {
    final state = context.watch<ComiyuState>();
    final p = state.profile!;
    final dark = state.themeMode == ThemeMode.dark;
    return Scaffold(appBar: AppBar(title: const Text('Pengaturan')), body: ListView(children: [
      ListTile(leading: avatar(p.photoPath), title: Text(p.name), subtitle: Text('Nomor Pengguna: ${p.userId}')),
      const Divider(),
      SwitchListTile(title: const Text('Mode Gelap'), value: dark, onChanged: state.toggleTheme,
        secondary: const Icon(Icons.dark_mode_outlined)),
      const ListTile(leading: Icon(Icons.lock_outline), title: Text('Privasi dan keamanan'),
        subtitle: Text('Gunakan nomor pengguna hanya dengan orang yang Anda kenal.')),
      const ListTile(leading: Icon(Icons.info_outline), title: Text('Tentang Comiyu App'),
        subtitle: Text('Versi 2.0.0 • Mode Online dan Lokal')),
    ]));
  }
}
