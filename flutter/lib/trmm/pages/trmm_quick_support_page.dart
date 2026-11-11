// Quick Support with both options: MeshCentral (9 digit code) and
// TRMM Desktop QS (customer reads ID + temporary password).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:path_provider/path_provider.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_remote.dart';
import '../trmm_layout.dart';
import '../trmm_session.dart';
import '../trmm_webview.dart';

/// saves a download from the TRMM api in the user's Downloads folder, with a
/// progress window (the server may take a while to prepare the file and the
/// user must not think nothing happened). Returns the saved path.
Future<String?> trmmDownload(BuildContext context, String path, String fallbackName,
    {String method = 'GET', Object? body}) async {
  final progress = ValueNotifier<(int, int?)>((0, null));
  var cancelled = false;
  BuildContext? dialogCtx;
  String mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogCtx = ctx;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Row(children: [
            const Icon(Icons.download),
            const SizedBox(width: 8),
            Text(tr('Downloading file')),
          ]),
          content: SizedBox(
            width: 420,
            child: ValueListenableBuilder<(int, int?)>(
              valueListenable: progress,
              builder: (_, p, __) {
                final (got, total) = p;
                final known = total != null && total > 0;
                final text = got == 0
                    ? tr('Preparing the file on the server...')
                    : known
                        ? '${mb(got)} MB / ${mb(total)} MB  (${(got * 100 / total).floor()}%)'
                        : '${mb(got)} MB';
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(fallbackName, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: known && got > 0 ? got / total : null, minHeight: 8),
                  const SizedBox(height: 10),
                  Text(text),
                ]);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.pop(ctx);
              },
              child: Text(tr('Cancel')),
            ),
          ],
        ),
      );
    },
  );

  Future<void> closeDialog() async {
    // a very fast download may end before the dialog was built
    for (var i = 0; dialogCtx == null && i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    final c = dialogCtx;
    if (!cancelled && c != null && c.mounted) Navigator.pop(c);
  }

  try {
    final (bytes, name) = await TrmmSession.to.api.client.download(path,
        method: method,
        body: body,
        onProgress: (got, total) => progress.value = (got, total),
        cancelled: () => cancelled);
    if (cancelled) return null;
    final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    final safe = (name ?? fallbackName).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final f = File('${dir.path}${Platform.pathSeparator}$safe');
    await f.writeAsBytes(bytes);
    await closeDialog();
    if (context.mounted) trmmSnack(context, tr('Saved to {0}', [f.path]));
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', f.path]);
    }
    return f.path;
  } on TrmmApiException catch (e) {
    await closeDialog();
    if (!cancelled && context.mounted) trmmSnack(context, e.message, error: true);
  } catch (e) {
    await closeDialog();
    if (!cancelled && context.mounted) trmmSnack(context, '$e', error: true);
  }
  return null;
}

/// local option (per computer/user): which quick support tab comes first
const _kQsFirstTab = 'trmm-qs-first-tab';

class TrmmQuickSupportDialog extends StatefulWidget {
  const TrmmQuickSupportDialog({super.key});

  @override
  State<TrmmQuickSupportDialog> createState() => _TrmmQuickSupportDialogState();
}

class _TrmmQuickSupportDialogState extends State<TrmmQuickSupportDialog> {
  /// "mesh" or "desktop"
  late String _first = bind.mainGetLocalOption(key: _kQsFirstTab) == 'desktop' ? 'desktop' : 'mesh';

  Future<void> _setFirst(String v) async {
    await bind.mainSetLocalOption(key: _kQsFirstTab, value: v);
    if (mounted) setState(() => _first = v);
  }

  @override
  Widget build(BuildContext context) {
    final s = TrmmSession.to;
    final (String, Widget)? mesh = s.canUseQuickSupport ? ('MeshCentral', const _MeshQuickSupport()) : null;
    final (String, Widget)? desktop =
        s.canUseRemoteAccess ? ('TRMM Desktop', const _DesktopQuickSupport()) : null;
    final ordered = _first == 'desktop' ? [desktop, mesh] : [mesh, desktop];
    final tabs = <(String, Widget)>[for (final t in ordered) if (t != null) t];
    final size = trmmDialogSize(context, 820, 600);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: DefaultTabController(
          // rebuilt when the order changes
          key: ValueKey(_first),
          length: tabs.length,
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: Text(tr('Quick Support')),
              trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                if (mesh != null && desktop != null) ...[
                  Text(tr('First tab:'), style: Theme.of(context).textTheme.bodySmall),
                  TrmmRadioGroup<String>(
                    options: const [('mesh', 'MeshCentral'), ('desktop', 'TRMM Desktop')],
                    value: _first,
                    spacing: 4,
                    onChanged: _setFirst,
                  ),
                ],
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ]),
            ),
            TabBar(tabs: [for (final t in tabs) Tab(text: t.$1)]),
            Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
          ]),
        ),
      ),
    );
  }
}

class _MeshQuickSupport extends StatefulWidget {
  const _MeshQuickSupport();

  @override
  State<_MeshQuickSupport> createState() => _MeshQuickSupportState();
}

class _MeshQuickSupportState extends State<_MeshQuickSupport> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final r = await TrmmSession.to.api.quickSupportConnect(_code.text);
      final session = (r['session'] as Map?) ?? {};
      await openTrmmWebView(r['control'] as String,
          title: '${tr('Quick Support')} — ${session['hostname'] ?? _code.text}');
      _code.clear();
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _code,
              decoration: InputDecoration(labelText: tr('Code'), hintText: '123 456 789'),
              onSubmitted: (_) => _connect(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _busy ? null : _connect, child: Text(tr('Connect'))),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => trmmDownload(context, '/quicksupport/download/', 'SuporteRapido.exe'),
            icon: const Icon(Icons.download),
            label: Text(tr('Download executable')),
          ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: QuickSupportSessionList(
            kind: 'mesh',
            onTap: (s) {
              _code.text = '${s['code']}';
              _connect();
            },
          ),
        ),
      ]),
    );
  }
}

class _DesktopQuickSupport extends StatefulWidget {
  const _DesktopQuickSupport();

  @override
  State<_DesktopQuickSupport> createState() => _DesktopQuickSupportState();
}

class _DesktopQuickSupportState extends State<_DesktopQuickSupport> {
  final _id = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(tr('Waiting for customers: double click a computer to connect'),
                style: Theme.of(context).textTheme.bodySmall),
          ),
          OutlinedButton.icon(
            onPressed: () =>
                trmmDownload(context, '/remoteaccess/quicksupport/download/', 'TRMM-Suporte.exe'),
            icon: const Icon(Icons.download),
            label: Text(tr('Download executable')),
          ),
        ]),
        const SizedBox(height: 8),
        if (TrmmSession.to.canUseQuickSupport)
          const Expanded(child: QuickSupportSessionList(kind: 'rustdesk'))
        else
          const Spacer(),
        const Divider(),
        Row(children: [
          Expanded(
              child: TextField(controller: _id, decoration: InputDecoration(labelText: tr('Client ID')))),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _pass,
              obscureText: true,
              decoration: InputDecoration(labelText: tr('Password')),
              onSubmitted: (_) => _go(),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
              onPressed: _go, icon: const Icon(Icons.desktop_windows), label: Text(tr('Connect'))),
        ]),
      ]),
    );
  }

  void _go() {
    final id = _id.text.trim();
    if (id.isEmpty) return;
    Navigator.pop(context);
    connectById(context, id, _pass.text);
  }
}

/// Quick support sessions of one kind, with the "install permanent access"
/// requests (approve choosing the site, or deny). Refreshes every 5 seconds.
class QuickSupportSessionList extends StatefulWidget {
  final String kind;
  final void Function(Map<String, dynamic> session)? onTap;
  const QuickSupportSessionList({super.key, required this.kind, this.onTap});

  @override
  State<QuickSupportSessionList> createState() => _QuickSupportSessionListState();
}

class _QuickSupportSessionListState extends State<QuickSupportSessionList> {
  List<Map<String, dynamic>> _sessions = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await TrmmSession.to.api.quickSupportSessions();
      final now = DateTime.now();
      final list = [
        for (final s in r)
          if ((s['kind'] ?? 'mesh') == widget.kind && !_stale(s, now)) Map<String, dynamic>.from(s)
      ];
      if (mounted) setState(() => _sessions = list);
    } catch (_) {}
  }

  /// session id -> (last_seen received, local time it was first received)
  final _seenAt = <String, (String, DateTime)>{};

  /// TRMM Desktop quick supports send a heartbeat every 15 s (closing the
  /// quick support ends its session at once, trmm_qs_install.dart close). A
  /// card whose last_seen did not move for 40 s, measured on this computer's
  /// clock so a clock difference to the server does not matter, is a quick
  /// support that was killed. Older than 90 s by the server time: gone too.
  bool _stale(dynamic s, DateTime now) {
    if (widget.kind != 'rustdesk') return false;
    if (s['install_status'] == 'sent') return false;
    final raw = '${s['last_seen'] ?? ''}';
    final seen = DateTime.tryParse(raw);
    if (seen == null) return false;
    if (now.difference(seen.toLocal()).inSeconds > 90) return true;
    final id = '${s['id']}';
    final prev = _seenAt[id];
    if (prev == null || prev.$1 != raw) {
      _seenAt[id] = (raw, now);
      return false;
    }
    return now.difference(prev.$2).inSeconds > 40;
  }

  Future<void> _deny(Map<String, dynamic> s) async {
    try {
      await TrmmSession.to.api.client.post('/quicksupport/sessions/${s['id']}/install/', {'approve': false});
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
    _load();
  }

  /// TRMM Desktop quick support: open the remote session (double click)
  Future<void> _connectDesktop(Map<String, dynamic> s) async {
    try {
      final c = await TrmmSession.to.api.client.post('/quicksupport/sessions/${s['id']}/rdconnect/');
      if (!mounted) return;
      await openRemoteWithConfig(context, Map<String, dynamic>.from(c as Map));
      _load();
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
  }

  Future<void> _end(Map<String, dynamic> s) async {
    try {
      await TrmmSession.to.api.quickSupportEnd(s['id'] as String);
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
    _load();
  }

  Future<void> _approve(Map<String, dynamic> s) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _ApproveInstallDialog(session: s));
    if (ok == true) _load();
  }

  /// the technician can also start the install (the customer confirms it)
  bool _canInstall(Map<String, dynamic> s) =>
      !['approved', 'sent', 'done'].contains(s['install_status'] ?? '');

  Widget _card(Map<String, dynamic> s) {
    final theme = Theme.of(context);
    final requested = s['install_status'] == 'requested';
    final canConnect = TrmmSession.to.canUseRemoteAccess;
    final id = '${s['remote_id'] ?? ''}'.replaceAllMapped(RegExp(r'(\d{3})(?=\d)'), (m) => '${m[1]} ');
    final user = '${s['username'] ?? ''}'.split('\\').last;
    return Tooltip(
      message: [
        '${s['os'] ?? ''}',
        if (s['client_ip'] != null) 'IP ${s['client_ip']}',
        if (s['connected_by'] != null) '${tr('Connected')}: ${s['connected_by']}',
        if ((s['install_status'] ?? '') != '')
          tr('Install status: {0}', [_installText(s['install_status'] as String)]),
      ].where((e) => e.isNotEmpty).join('\n'),
      child: GestureDetector(
        onDoubleTap: canConnect ? () => _connectDesktop(s) : null,
        child: SizedBox(
          width: 240,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: const EdgeInsets.all(6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                height: 110,
                width: double.infinity,
                color: requested ? Colors.orange.shade800 : const Color(0xFF1A0E5C),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(requested ? Icons.install_desktop : Icons.window, size: 52, color: Colors.white),
                  const SizedBox(height: 8),
                  Text('$user@${s['hostname'] ?? ''}'.toLowerCase(),
                      style: const TextStyle(color: Colors.white70), overflow: TextOverflow.ellipsis),
                ]),
              ),
              Container(
                color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                padding: const EdgeInsets.only(left: 12),
                child: Row(children: [
                  Icon(Icons.circle, size: 9, color: s['status'] == 'connected' ? Colors.blue : Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) {
                      if (v == 'connect') _connectDesktop(s);
                      if (v == 'approve') _approve(s);
                      if (v == 'deny') _deny(s);
                      if (v == 'end') _end(s);
                    },
                    itemBuilder: (_) => [
                      if (canConnect) PopupMenuItem(value: 'connect', child: Text(tr('Connect'))),
                      if (requested) PopupMenuItem(value: 'approve', child: Text(tr('Approve install'))),
                      if (!requested && _canInstall(s))
                        PopupMenuItem(value: 'approve', child: Text(tr('Install permanent access'))),
                      if (requested) PopupMenuItem(value: 'deny', child: Text(tr('Deny'))),
                      PopupMenuItem(value: 'end', child: Text(tr('End session'))),
                    ],
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  String _installText(String st) => switch (st) {
        'requested' => tr('Install requested'),
        'approved' => tr('Approved'),
        'sent' => tr('Installing'),
        'done' => tr('Installed'),
        'failed' => tr('Error'),
        'denied' => tr('Deny'),
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(tr('Sessions'), style: Theme.of(context).textTheme.titleSmall),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 18)),
      ]),
      if (widget.kind == 'rustdesk')
        Expanded(
          child: _sessions.isEmpty
              ? Center(child: Text(tr('No sessions'), style: Theme.of(context).textTheme.bodySmall))
              : SingleChildScrollView(child: Wrap(children: [for (final s in _sessions) _card(s)])),
        )
      else
        Expanded(
          child: ListView(children: [
            for (final s in _sessions)
              GestureDetector(
                  onDoubleTap: widget.kind == 'rustdesk' && TrmmSession.to.canUseRemoteAccess
                      ? () => _connectDesktop(s)
                      : null,
                  child: ListTile(
                    dense: true,
                    leading: s['install_status'] == 'requested'
                        ? const Icon(Icons.install_desktop, color: Colors.orange)
                        : null,
                    title: Text(widget.kind == 'rustdesk'
                        ? '${s['hostname'] ?? ''}  —  ID ${s['remote_id'] ?? ''}'
                        : '${s['formatted_code'] ?? s['code']}  —  ${s['hostname'] ?? ''}'),
                    subtitle: Text([
                      '${s['username'] ?? ''}',
                      '${s['os'] ?? ''}',
                      if (s['connected_by'] != null) '${tr('Connected')}: ${s['connected_by']}',
                      if ((s['install_status'] ?? '') != '')
                        tr('Install status: {0}', [
                          '${_installText(s['install_status'] as String)}'
                              '${s['install_site_name'] != null ? ' (${s['install_site_name']})' : ''}'
                              '${(s['install_message'] ?? '') != '' ? ' — ${s['install_message']}' : ''}'
                        ]),
                    ].where((e) => e.trim().isNotEmpty).join('  •  ')),
                    trailing: Wrap(spacing: 4, children: [
                      if (s['install_status'] == 'requested') ...[
                        FilledButton(onPressed: () => _approve(s), child: Text(tr('Approve install'))),
                        TextButton(onPressed: () => _deny(s), child: Text(tr('Deny'))),
                      ],
                      if (s['install_status'] != 'requested' && _canInstall(s))
                        IconButton(
                          tooltip: tr('Install permanent access'),
                          icon: const Icon(Icons.install_desktop),
                          onPressed: () => _approve(s),
                        ),
                      if (widget.kind == 'rustdesk' && TrmmSession.to.canUseRemoteAccess)
                        IconButton(
                          tooltip: tr('Connect'),
                          icon: const Icon(Icons.desktop_windows),
                          onPressed: () => _connectDesktop(s),
                        ),
                      IconButton(
                        tooltip: tr('End session'),
                        icon: const Icon(Icons.stop_circle_outlined),
                        onPressed: () => _end(s),
                      ),
                    ]),
                    onTap: widget.onTap == null ? null : () => widget.onTap!(s),
                  )),
          ]),
        ),
    ]);
  }
}

class _ApproveInstallDialog extends StatefulWidget {
  final Map<String, dynamic> session;
  const _ApproveInstallDialog({required this.session});

  @override
  State<_ApproveInstallDialog> createState() => _ApproveInstallDialogState();
}

class _ApproveInstallDialogState extends State<_ApproveInstallDialog> {
  List<Map<String, dynamic>> _clients = [];
  int? _client;
  int? _site;
  String _type = 'workstation';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    TrmmSession.to.api.clients().then((r) {
      if (!mounted) return;
      setState(() {
        _clients = [for (final c in r) Map<String, dynamic>.from(c)];
        if (_clients.isNotEmpty) {
          _client = _clients.first['id'] as int;
          _site = _firstSite();
        }
      });
    }).catchError((_) {});
  }

  List<dynamic> get _sites =>
      (_clients.firstWhere((c) => c['id'] == _client, orElse: () => {})['sites'] as List?) ?? [];

  int? _firstSite() => _sites.isEmpty ? null : _sites.first['id'] as int;

  Future<void> _ok() async {
    setState(() => _busy = true);
    try {
      await TrmmSession.to.api.client.post('/quicksupport/sessions/${widget.session['id']}/install/', {
        'approve': true,
        'site': _site,
        'agenttype': _type,
      });
      if (mounted) Navigator.pop(context, true);
    } on TrmmApiException catch (e) {
      if (mounted) {
        trmmSnack(context, e.message, error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return AlertDialog(
      title: Text('${s['install_status'] == 'requested' ? tr('Approve install') : tr('Install permanent access')}'
          ' — ${s['hostname'] ?? ''}'),
      content: SizedBox(
        width: 420,
        child:
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s['kind'] == 'rustdesk'
              ? tr('Tactical RMM agent + MeshCentral + TRMM Desktop remote access')
              : tr('Tactical RMM agent + MeshCentral')),
          const SizedBox(height: 8),
          // computer name and user are reported by the customer's program;
          // the IP is what the server saw
          Text(
            '${tr('Reported by the customer')}: ${s['hostname'] ?? ''} • ${s['username'] ?? ''}\n'
            'IP: ${s['client_ip'] ?? '-'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            value: _client,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Client')),
            items: [
              for (final c in _clients) DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}'))
            ],
            onChanged: (v) => setState(() {
              _client = v;
              _site = _firstSite();
            }),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            key: ValueKey(_client),
            value: _site,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Site')),
            items: [
              for (final x in _sites) DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}'))
            ],
            onChanged: (v) => setState(() => _site = v),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _type,
            decoration: InputDecoration(labelText: tr('Agent type')),
            items: [
              DropdownMenuItem(value: 'workstation', child: Text(tr('Workstation'))),
              DropdownMenuItem(value: 'server', child: Text(tr('Server'))),
            ],
            onChanged: (v) => setState(() => _type = v ?? 'workstation'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
        FilledButton(onPressed: _busy || _site == null ? null : _ok, child: Text(tr('Approve install'))),
      ],
    );
  }
}
