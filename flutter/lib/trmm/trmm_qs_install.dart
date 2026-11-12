// TRMM Desktop quick support: session in Tactical RMM + "Install permanent
// access" button.
//
// As soon as the quick support opens it registers a "rustdesk" session (id +
// temporary password, refreshed by the heartbeat): the technician sees it in
// the TRMM Desktop app and connects with a double click.
//
// The TRMM server appends {trmm_api, trmm_token} to the quick support
// executable (remoteaccess/scripts.py embedded_config); the portable packer
// passes the block in TRMM_EMBEDDED_CONFIG. Flow (quicksupport app):
//   1. open a "rustdesk" quick support session and request the install
//   2. a technician approves it in Tactical RMM, choosing the client/site
//   3. download the installer of this session (once) and run it as
//      administrator: Tactical RMM agent + MeshCentral + TRMM Desktop host

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';

import 'trmm_i18n.dart';
import 'trmm_native.dart';

class _QsConfig {
  final String api;
  final String token;
  _QsConfig(this.api, this.token);

  static _QsConfig? _cached;
  static bool _loaded = false;

  static _QsConfig? load() {
    if (_loaded) return _cached;
    _loaded = true;
    try {
      // set by the Rust core only when the config embedded in the executable
      // has a valid signature of a trusted TRMM server (src/common.rs)
      final api = bind.mainGetBuildinOption(key: 'trmm-api');
      final token = bind.mainGetBuildinOption(key: 'trmm-qs-token');
      if (!api.startsWith('https://') || token.isEmpty) return null;
      _cached = _QsConfig(api.replaceAll(RegExp(r'/+$'), ''), token);
    } catch (_) {}
    return _cached;
  }
}

/// PowerShell -EncodedCommand expects UTF-16LE
List<int> _utf16le(String s) => [for (final c in s.codeUnits) ...[c & 0xff, c >> 8]];

/// Quick support session in Tactical RMM (one per process, independent of
/// the widgets, which can be rebuilt).
class TrmmQsSession {
  TrmmQsSession._();
  static final TrmmQsSession instance = TrmmQsSession._();

  final _cfg = _QsConfig.load();
  String? _sessionId;
  String? _secret;
  Timer? _timer;
  bool _started = false;
  bool _closed = false;
  bool _installing = false;

  /// '' | requested | approved | sent | done | failed | denied | installing
  final state = ValueNotifier<String>('');
  final message = ValueNotifier<String>('');

  /// the TRMM server records this session (recordings app)
  final recording = ValueNotifier<bool>(false);

  /// "this session is recorded" notice for the customer: disabled for now
  /// (user request 2026-11-12); set to true to show it again
  static const showRecordingNotice = false;

  bool get ready => _sessionId != null;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-QuickSupport-Token': _cfg!.token,
        if (_secret != null) 'X-QuickSupport-Session': _secret!,
      };

  Future<Map<String, dynamic>> _post(String path, [Map<String, dynamic>? body]) async {
    final r = await http
        .post(Uri.parse('${_cfg!.api}$path'), headers: _headers, body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 60));
    final data = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode >= 400) {
      throw Exception(data is Map && data['error'] != null ? data['error'] : 'HTTP ${r.statusCode}');
    }
    return data is Map<String, dynamic> ? data : {};
  }

  String get _remoteId => gFFI.serverModel.serverId.text.replaceAll(' ', '');
  String get _password => gFFI.serverModel.serverPasswd.text.trim();
  bool get _hasIdentity =>
      RegExp(r'^\d{6,}$').hasMatch(_remoteId) && _password.isNotEmpty && !_password.contains(' ');

  /// called once by the quick support home page
  void start() {
    if (_started || _cfg == null) return;
    _started = true;
    trmmQsBeforeQuit = close;
    // a token of a previous run is never reused
    _setRecording('', '');
    _schedule(const Duration(seconds: 3));
  }

  /// the quick support is closing: end the session in Tactical RMM now, so it
  /// leaves the technicians' list at once instead of after the heartbeat
  /// timeout
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _setRecording('', '');
    final id = _sessionId;
    if (id == null || _cfg == null) return;
    _sessionId = null;
    try {
      await http
          .post(Uri.parse('${_cfg!.api}/quicksupport/client/sessions/$id/close/'),
              headers: _headers, body: '{}')
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_closed) return;
    _timer = Timer(d, _tick);
  }

  Future<void> _tick() async {
    if (_closed) return;
    var next = const Duration(seconds: 15);
    try {
      if (_sessionId == null) {
        // wait until the engine has an id and a temporary password
        if (!_hasIdentity) {
          _schedule(const Duration(seconds: 2));
          return;
        }
        final r = await _post('/quicksupport/client/sessions/', {
          'kind': 'rustdesk',
          'remote_id': _remoteId,
          'password': _password,
          'hostname': Platform.localHostname,
          'username': '${Platform.environment['USERDOMAIN'] ?? ''}\\${Platform.environment['USERNAME'] ?? ''}',
          'os': Platform.operatingSystemVersion,
          'version': 'trmm-desktop',
        });
        _sessionId = r['session_id'] as String;
        _secret = r['session_secret'] as String;
        await _setupRecording();
      } else {
        final r = await _post('/quicksupport/client/sessions/$_sessionId/heartbeat/', {
          if (_hasIdentity) 'remote_id': _remoteId,
          if (_hasIdentity) 'password': _password,
        });
        await _onInstallStatus((r['install_status'] as String?) ?? '');
      }
    } catch (_) {
      next = const Duration(seconds: 10);
    }
    // check the approval more often while waiting for it
    if (state.value == 'requested') next = const Duration(seconds: 5);
    _schedule(next);
  }

  /// session recording: the engine records every incoming connection and
  /// streams it to the TRMM server (src/hbbs_http/record_upload.rs) when
  /// trmm-record-url/token are set. 404 = recording off.
  Future<void> _setupRecording() async {
    try {
      final r = await http
          .post(Uri.parse('${_cfg!.api}/recordings/qs/$_sessionId/token/'),
              headers: _headers, body: '{}')
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return;
      final data = jsonDecode(r.body);
      final url = data is Map ? (data['url'] as String? ?? '') : '';
      final token = data is Map ? (data['token'] as String? ?? '') : '';
      if (!url.startsWith('https://') || !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(token)) {
        return;
      }
      await _setRecording(url, token);
    } catch (_) {}
  }

  Future<void> _setRecording(String url, String token) async {
    try {
      await bind.mainSetOption(key: 'trmm-record-url', value: url);
      await bind.mainSetOption(key: 'trmm-record-token', value: token);
      recording.value = url.isNotEmpty;
    } catch (_) {}
  }

  Future<void> requestInstall() async {
    message.value = '';
    try {
      if (_sessionId == null) {
        await _tick();
        if (_sessionId == null) throw Exception(tr('Connecting...'));
      }
      await _post('/quicksupport/client/sessions/$_sessionId/install/request/');
      state.value = 'requested';
      message.value = tr("Request sent. Waiting for the technician's approval...");
      _schedule(const Duration(seconds: 5));
    } catch (e) {
      message.value = tr('Unable to install permanent access: {0}', ['$e']);
    }
  }

  BuildContext? _context;

  Future<void> _onInstallStatus(String s) async {
    if (_installing || s == state.value) return;
    if (s == 'approved') {
      await _install();
      return;
    }
    if (s == 'denied' && state.value == 'requested') {
      message.value = tr('The technician did not approve the installation.');
    }
    if (s == 'done') message.value = tr('Permanent access installed.');
    state.value = s;
  }

  Future<void> _install() async {
    final ctx = _context;
    if (ctx == null || !ctx.mounted) return;
    _installing = true;
    // the quick support window is small: make room for the question
    Size? oldSize;
    try {
      oldSize = await windowManager.getSize();
      if (oldSize.height < 520) await windowManager.setSize(Size(oldSize.width < 360 ? 360 : oldSize.width, 520));
    } catch (_) {}
    if (!ctx.mounted) return;
    final ok = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.all(12),
        contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        content: Text(tr('qs_install_confirm'), style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: Text(tr('No'))),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: Text(tr('Yes'))),
        ],
      ),
    );
    if (oldSize != null) {
      try {
        await windowManager.setSize(oldSize);
      } catch (_) {}
    }
    if (ok != true) {
      _installing = false;
      state.value = '';
      message.value = tr('Installation cancelled.');
      return;
    }
    state.value = 'installing';
    message.value = tr('Installing permanent access...');

    var success = false;
    var result = '';
    Directory? dir;
    try {
      final r = await http
          .get(Uri.parse('${_cfg!.api}/quicksupport/client/sessions/$_sessionId/installer/?arch=amd64'),
              headers: _headers)
          .timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      dir = await Directory.systemTemp.createTemp('trmm-install-');
      final file = File('${dir.path}${Platform.pathSeparator}trmm-install.ps1');
      // utf-8 with BOM so Windows PowerShell 5 reads accents correctly
      await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(r.body)]);
      // elevated (UAC) and wait for the exit code
      final hash = sha256.convert(utf8.encode(r.body)).toString();
      // runs elevated: reads the file, checks the hash, runs it from memory
      final elevated = "\$t = [IO.File]::ReadAllText('${file.path.replaceAll("'", "''")}', [Text.Encoding]::UTF8); "
          "\$h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash("
          "[Text.Encoding]::UTF8.GetBytes(\$t))).Replace('-', '').ToLower(); "
          "if (\$h -ne '$hash') { exit 97 }; & ([ScriptBlock]::Create(\$t)); exit \$LASTEXITCODE";
      final encoded = base64.encode(_utf16le(elevated));
      final cmd = "\$p = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru "
          "-ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded'; exit \$p.ExitCode";
      final p = await Process.run('powershell.exe', ['-NoProfile', '-Command', cmd]);
      success = p.exitCode == 0;
      result = success ? 'exit code 0' : 'exit code ${p.exitCode} ${p.stderr}'.trim();
    } catch (e) {
      result = '$e';
    } finally {
      try {
        await dir?.delete(recursive: true);
      } catch (_) {}
    }
    try {
      await _post('/quicksupport/client/sessions/$_sessionId/install/result/',
          {'ok': success, 'message': result.length > 1900 ? result.substring(0, 1900) : result});
    } catch (_) {}
    _installing = false;
    state.value = success ? 'done' : 'failed';
    message.value =
        success ? tr('Permanent access installed.') : tr('Unable to install permanent access: {0}', [result]);
  }
}

class TrmmQsInstallButton extends StatefulWidget {
  const TrmmQsInstallButton({super.key});

  static bool get available => Platform.isWindows && _QsConfig.load() != null;

  @override
  State<TrmmQsInstallButton> createState() => _TrmmQsInstallButtonState();
}

class _TrmmQsInstallButtonState extends State<TrmmQsInstallButton> {
  final _session = TrmmQsSession.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _session.start();
  }

  @override
  Widget build(BuildContext context) {
    _session._context = context;
    return ValueListenableBuilder<String>(
      valueListenable: _session.state,
      builder: (context, state, _) {
        final canClick = !_busy && (state == '' || state == 'denied' || state == 'failed');
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ValueListenableBuilder<bool>(
              valueListenable: _session.recording,
              builder: (context, on, _) => !on || !TrmmQsSession.showRecordingNotice
                  ? const SizedBox.shrink()
                  : Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.12),
                        border: Border.all(color: Colors.red.shade400),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(children: [
                        Icon(Icons.fiber_manual_record, color: Colors.red.shade600, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(tr('qs_recording_notice'),
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ]),
                    ),
            ),
            OutlinedButton.icon(
              onPressed: canClick
                  ? () async {
                      setState(() => _busy = true);
                      await _session.requestInstall();
                      if (mounted) setState(() => _busy = false);
                    }
                  : null,
              icon: const Icon(Icons.install_desktop, size: 18),
              label: Text(tr('Install permanent access')),
            ),
            ValueListenableBuilder<String>(
              valueListenable: _session.message,
              builder: (context, msg, _) => msg.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(msg, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                    ),
            ),
          ]),
        );
      },
    );
  }
}
