import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import '../models/app_models.dart';

/// Server LAN satu ruang: host membuat roomId, lalu mengirimkannya melalui
/// paket hello. Semua pesan memiliki ID yang sama di seluruh perangkat.
class LanService {
  HttpServer? _server;
  IOWebSocketChannel? _client;
  final _incoming = StreamController<ChatMessage>.broadcast();
  final List<WebSocket> _peers = [];
  final Set<String> _acceptedIds = <String>{};
  final _uuid = const Uuid();
  String? _roomId;
  String? _hostAddress;

  Stream<ChatMessage> get incomingMessages => _incoming.stream;
  bool get isHosting => _server != null;
  bool get isConnected => _client != null || _server != null;
  String? get roomId => _roomId;

  Future<String> startHost({int port = 4040}) async {
    if (_server != null) return _hostAddress ?? _server!.address.address;
    _roomId = _uuid.v4();
    _acceptedIds.clear();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('Comiyu LAN aktif');
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _peers.add(socket);
      socket.add(jsonEncode({'type': 'hello', 'roomId': _roomId}));
      socket.listen((raw) => _receiveFromPeer(raw),
        onDone: () => _peers.remove(socket),
        onError: (_) => _peers.remove(socket));
    }, onError: (_) {});

    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false);
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback && !address.address.startsWith('169.254.')) {
          _hostAddress = address.address;
          return address.address;
        }
      }
    }
    _hostAddress = server.address.address;
    return _hostAddress!;
  }

  Future<String> connect(String address, {int port = 4040}) async {
    await disconnectClient();
    final channel = IOWebSocketChannel.connect(
      Uri(scheme: 'ws', host: address.trim(), port: port, path: '/chat'));
    _client = channel;
    final hello = Completer<String>();
    channel.stream.listen((raw) {
      try {
        final packet = jsonDecode(raw as String) as Map<String, dynamic>;
        if (packet['type'] == 'hello') {
          final id = packet['roomId'] as String?;
          if (id == null || id.isEmpty) throw const FormatException('Room ID kosong');
          _roomId = id;
          if (!hello.isCompleted) hello.complete(id);
          return;
        }
        _acceptMessage(packet);
      } catch (_) {
        // Paket invalid tidak diteruskan ke UI.
      }
    }, onDone: () {
      _client = null;
      if (!hello.isCompleted) hello.completeError(StateError('Koneksi host terputus.'));
    }, onError: (Object error) {
      _client = null;
      if (!hello.isCompleted) hello.completeError(error);
    });
    try {
      return await hello.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      await disconnectClient();
      rethrow;
    }
  }

  void _receiveFromPeer(dynamic raw) {
    try {
      final packet = jsonDecode(raw as String) as Map<String, dynamic>;
      if (packet['type'] == 'message') {
        _acceptMessage(packet);
        // Broadcast ke SEMUA peer, termasuk pengirim. ID pesan tetap sama;
        // penyimpanan SQLite memakai primary key sehingga echo tidak duplikat.
        final encoded = jsonEncode(packet);
        for (final peer in List<WebSocket>.from(_peers)) {
          if (peer.readyState == WebSocket.open) peer.add(encoded);
        }
      }
    } catch (_) {
      // Abaikan data yang tidak valid.
    }
  }

  void _acceptMessage(Map<String, dynamic> packet) {
    final activeRoom = _roomId;
    if (activeRoom == null || packet['type'] != 'message' || packet['roomId'] != activeRoom) return;
    final id = packet['id'];
    if (id is! String || id.isEmpty || !_acceptedIds.add(id)) return;
    final body = packet['body'];
    final senderId = packet['senderId'];
    final senderName = packet['senderName'];
    final sentAt = packet['sentAt'];
    if (body is! String || senderId is! String || senderName is! String || sentAt is! int) {
      _acceptedIds.remove(id);
      return;
    }
    _incoming.add(ChatMessage(
      id: id, chatId: activeRoom, senderUid: senderId,
      senderName: senderName, body: body,
      sentAt: DateTime.fromMillisecondsSinceEpoch(sentAt), source: 'lan'));
  }

  Future<void> send({required UserProfile sender, required String body}) async {
    final room = _roomId;
    if (room == null || body.trim().isEmpty) {
      throw StateError('Belum terhubung ke ruang obrolan lokal.');
    }
    final packet = <String, dynamic>{
      'type': 'message', 'id': _uuid.v4(), 'roomId': room,
      'senderId': sender.uid, 'senderName': sender.name,
      'body': body.trim(), 'sentAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (_client != null) {
      _client!.sink.add(jsonEncode(packet));
    } else if (_server != null) {
      // Jalur host memakai handler yang sama dengan pesan dari klien.
      _acceptMessage(packet);
      final encoded = jsonEncode(packet);
      for (final peer in List<WebSocket>.from(_peers)) {
        if (peer.readyState == WebSocket.open) peer.add(encoded);
      }
    } else {
      throw StateError('Koneksi jaringan lokal terputus.');
    }
  }

  Future<void> disconnectClient() async {
    final old = _client;
    _client = null;
    _roomId = _server == null ? null : _roomId;
    await old?.sink.close();
  }

  Future<void> stopHost() async {
    for (final peer in List<WebSocket>.from(_peers)) {
      await peer.close();
    }
    _peers.clear();
    await _server?.close(force: true);
    _server = null;
    _roomId = null;
    _hostAddress = null;
    _acceptedIds.clear();
  }

  Future<void> dispose() async {
    await disconnectClient();
    await stopHost();
    await _incoming.close();
  }
}
