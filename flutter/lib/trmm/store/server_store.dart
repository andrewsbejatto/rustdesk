// Tactical RMM servers configured in TRMM Desktop (several servers supported).
// Stored in <app support dir>/trmm/servers.json; tokens and saved passwords
// protected by SecureStore.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'secure_store.dart';

class TrmmServer {
  final String id;
  String name;
  /// api url, e.g. https://api.example.com
  String apiUrl;
  /// dashboard url (to open things only available in the web panel)
  String webUrl;
  String username;
  String? token;
  /// login password, only when the user chose "Save password" (protected
  /// like the token)
  String? password;

  TrmmServer({
    required this.id,
    required this.name,
    required this.apiUrl,
    this.webUrl = '',
    this.username = '',
    this.token,
    this.password,
  });

  bool get loggedIn => token != null && token!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api_url': apiUrl,
        'web_url': webUrl,
        'username': username,
        if (token != null) 'token': base64Encode(SecureStore.protect(token!)),
        if (password != null) 'password': base64Encode(SecureStore.protect(password!)),
      };

  factory TrmmServer.fromJson(Map<String, dynamic> j) => TrmmServer(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        apiUrl: j['api_url'] as String? ?? '',
        webUrl: j['web_url'] as String? ?? '',
        username: j['username'] as String? ?? '',
        token: j['token'] == null
            ? null
            : SecureStore.unprotect(Uint8List.fromList(base64Decode(j['token'] as String))),
        password: j['password'] == null
            ? null
            : SecureStore.unprotect(Uint8List.fromList(base64Decode(j['password'] as String))),
      );
}

class ServerStore {
  final List<TrmmServer> servers = [];
  String? activeId;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}trmm${Platform.pathSeparator}servers.json');
    await f.parent.create(recursive: true);
    return f;
  }

  TrmmServer? get active {
    for (final s in servers) {
      if (s.id == activeId) return s;
    }
    return servers.isEmpty ? null : servers.first;
  }

  Future<void> load() async {
    final f = await _file();
    servers.clear();
    if (!await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      activeId = j['active'] as String?;
      for (final s in (j['servers'] as List? ?? [])) {
        servers.add(TrmmServer.fromJson(Map<String, dynamic>.from(s)));
      }
    } catch (_) {
      // corrupted file: start empty
    }
  }

  Future<void> save() async {
    final f = await _file();
    final data = jsonEncode({
      'active': activeId,
      'servers': servers.map((s) => s.toJson()).toList(),
    });
    if (Platform.isWindows) {
      await f.writeAsString(data); // tokens are DPAPI protected
      return;
    }
    // linux: 0700 folder, 0600 file created before the content is written
    await Process.run('chmod', ['700', f.parent.path]);
    if (!await f.exists()) await f.create();
    await Process.run('chmod', ['600', f.path]);
    await f.writeAsString(data);
  }

  TrmmServer add({required String name, required String apiUrl, String webUrl = ''}) {
    final s = TrmmServer(id: const Uuid().v4(), name: name, apiUrl: apiUrl, webUrl: webUrl);
    servers.add(s);
    activeId ??= s.id;
    return s;
  }

  void remove(String id) {
    servers.removeWhere((s) => s.id == id);
    if (activeId == id) activeId = servers.isEmpty ? null : servers.first.id;
  }
}
