// Remote Background (same tabs as the web panel): processes, services, event
// log; terminal through MeshCentral and files through the Tactical RMM file
// browser (trmm_file_browser.dart).

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';
import '../trmm_layout.dart';
import 'trmm_file_browser.dart';

Future<void> showRemoteBackground(BuildContext context, Map<String, dynamic> agent) =>
    showDialog(context: context, builder: (_) => TrmmRemoteBackgroundDialog(agent: agent));

class TrmmRemoteBackgroundDialog extends StatelessWidget {
  final Map<String, dynamic> agent;
  const TrmmRemoteBackgroundDialog({super.key, required this.agent});

  String get agentId => agent['agent_id'] as String;
  bool get windows => agent['plat'] == 'windows';

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, Widget)>[
      (tr('Processes'), _ProcessesTab(agentId: agentId)),
      if (windows) (tr('Services'), _ServicesTab(agentId: agentId)),
      if (windows) (tr('Event Log'), _EventLogTab(agentId: agentId)),
    ];
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: DefaultTabController(
        length: tabs.length,
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.terminal),
            title: Text('${trmmAgentTitle(agent)} (${tr('Remote Background')})'),
            trailing: Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => openMesh(context, agentId, 'terminal'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(tr('Terminal')),
              ),
              OutlinedButton.icon(
                onPressed: () => openTrmmFileBrowser(context, agent),
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(tr('File Transfer')),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
          ),
          TabBar(tabs: [for (final t in tabs) Tab(text: t.$1)]),
          Expanded(child: TabBarView(children: [for (final t in tabs) t.$2])),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- helpers
String _bytes(num? b) {
  if (b == null) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

class _Table extends StatelessWidget {
  final List<(String, int)> columns;
  final List<List<String>> rows;
  final void Function(int index, Offset position)? onSecondary;
  final int? sortColumn;
  final bool ascending;
  final void Function(int column)? onSort;

  const _Table(
      {required this.columns,
      required this.rows,
      this.onSecondary,
      this.sortColumn,
      this.ascending = true,
      this.onSort});

  @override
  Widget build(BuildContext context) {
    final header = TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).hintColor);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          for (var i = 0; i < columns.length; i++)
            Expanded(
              flex: columns[i].$2,
              child: InkWell(
                onTap: onSort == null ? null : () => onSort!(i),
                child: Row(children: [
                  Flexible(child: Text(columns[i].$1, style: header, overflow: TextOverflow.ellipsis)),
                  if (sortColumn == i)
                    Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                ]),
              ),
            ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          itemCount: rows.length,
          itemExtent: 28,
          itemBuilder: (ctx, r) => GestureDetector(
            onSecondaryTapDown:
                onSecondary == null ? null : (d) => onSecondary!(r, d.globalPosition),
            child: InkWell(
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  for (var i = 0; i < columns.length; i++)
                    Expanded(
                        flex: columns[i].$2,
                        child: Text(rows[r][i], overflow: TextOverflow.ellipsis, maxLines: 1)),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

mixin _Loader<T extends StatefulWidget> on State<T> {
  bool loading = false;
  String? error;
  String filter = '';

  Future<void> run(Future<void> Function() f) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await f();
    } on TrmmApiException catch (e) {
      error = e.message;
    }
    if (mounted) setState(() => loading = false);
  }

  Widget toolbar(List<Widget> extra, VoidCallback refresh) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          SizedBox(
            width: 240,
            child: TextField(
              decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: tr('Search'),
                  border: const OutlineInputBorder()),
              onChanged: (v) => setState(() => filter = v.trim().toLowerCase()),
            ),
          ),
          const SizedBox(width: 8),
          ...extra,
          const Spacer(),
          if (loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          IconButton(onPressed: loading ? null : refresh, icon: const Icon(Icons.refresh)),
        ]),
      );

  Widget body(Widget child) => error != null
      ? trmmErrorView(context, error!)
      : child;
}

Future<String?> _menu(BuildContext context, Offset p, List<(String, String)> items) =>
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, p.dx, p.dy),
      items: [for (final i in items) PopupMenuItem(value: i.$1, height: 34, child: Text(i.$2))],
    );

// ---------------------------------------------------------------- processes
class _ProcessesTab extends StatefulWidget {
  final String agentId;
  const _ProcessesTab({required this.agentId});

  @override
  State<_ProcessesTab> createState() => _ProcessesTabState();
}

class _ProcessesTabState extends State<_ProcessesTab> with _Loader {
  List<Map<String, dynamic>> _procs = [];
  int _sort = 1;
  bool _asc = false;
  Timer? _timer;
  bool _auto = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() => run(() async {
        final r = await TrmmSession.to.api.processes(widget.agentId);
        _procs = [for (final p in r) Map<String, dynamic>.from(p)];
      });

  num _key(Map<String, dynamic> p) => switch (_sort) {
        1 => double.tryParse('${p['cpu_percent']}') ?? 0,
        2 => (p['membytes'] as num?) ?? 0,
        4 => (p['pid'] as num?) ?? 0,
        _ => 0,
      };

  @override
  Widget build(BuildContext context) {
    final list = _procs
        .where((p) => filter.isEmpty || '${p['name']} ${p['username']} ${p['pid']}'.toLowerCase().contains(filter))
        .toList()
      ..sort((a, b) {
        final c = _sort == 0 || _sort == 3
            ? '${a[_sort == 0 ? 'name' : 'username']}'.compareTo('${b[_sort == 0 ? 'name' : 'username']}')
            : _key(a).compareTo(_key(b));
        return _asc ? c : -c;
      });
    return Column(children: [
      toolbar([
        FilterChip(
          label: Text(tr('Auto refresh')),
          selected: _auto,
          onSelected: (v) {
            setState(() => _auto = v);
            _timer?.cancel();
            if (v) _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
          },
        ),
      ], _load),
      Expanded(
        child: body(_Table(
          columns: [(tr('Name'), 4), ('CPU', 1), (tr('Memory'), 2), (tr('User'), 3), ('PID', 1)],
          rows: [
            for (final p in list)
              ['${p['name']}', '${p['cpu_percent']}%', _bytes(p['membytes'] as num?), '${p['username'] ?? ''}', '${p['pid']}']
          ],
          sortColumn: _sort,
          ascending: _asc,
          onSort: (c) => setState(() {
            _asc = _sort == c ? !_asc : c == 0 || c == 3;
            _sort = c;
          }),
          onSecondary: (i, pos) async {
            final p = list[i];
            final v = await _menu(context, pos, [('kill', tr('End process'))]);
            if (v != 'kill' || !context.mounted) return;
            if (!await trmmConfirm(context, '${tr('End process')} ${p['name']} (${p['pid']})?')) return;
            try {
              final r = await TrmmSession.to.api.killProcess(widget.agentId, (p['pid'] as num).toInt());
              if (context.mounted) trmmSnack(context, '$r');
              _load();
            } on TrmmApiException catch (e) {
              if (context.mounted) trmmSnack(context, e.message, error: true);
            }
          },
        )),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- services
class _ServicesTab extends StatefulWidget {
  final String agentId;
  const _ServicesTab({required this.agentId});

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<_ServicesTab> with _Loader {
  List<Map<String, dynamic>> _svcs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => run(() async {
        final r = await TrmmSession.to.api.services(widget.agentId);
        _svcs = [for (final s in r) Map<String, dynamic>.from(s)]
          ..sort((a, b) => '${a['display_name']}'.toLowerCase().compareTo('${b['display_name']}'.toLowerCase()));
      });

  Future<void> _act(Map<String, dynamic> s, String v) async {
    final api = TrmmSession.to.api;
    try {
      final dynamic r;
      if (v.startsWith('type:')) {
        r = await api.serviceStartType(widget.agentId, s['name'] as String, v.substring(5));
      } else {
        r = await api.serviceAction(widget.agentId, s['name'] as String, v);
      }
      if (mounted) trmmSnack(context, '$r');
      _load();
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _svcs
        .where((s) =>
            filter.isEmpty || '${s['display_name']} ${s['name']} ${s['status']}'.toLowerCase().contains(filter))
        .toList();
    return Column(children: [
      toolbar([], _load),
      Expanded(
        child: body(_Table(
          columns: [
            (tr('Display name'), 4),
            (tr('Name'), 3),
            (tr('Startup'), 2),
            (tr('Status'), 1),
            (tr('User'), 2),
          ],
          rows: [
            for (final s in list)
              ['${s['display_name']}', '${s['name']}', '${s['start_type']}', '${s['status']}', '${s['username'] ?? ''}']
          ],
          onSecondary: (i, pos) async {
            final s = list[i];
            final v = await _menu(context, pos, [
              ('start', tr('Start')),
              ('stop', tr('Stop')),
              ('restart', tr('Restart')),
              ('type:auto', '${tr('Startup')}: ${tr('Automatic')}'),
              ('type:autodelay', '${tr('Startup')}: ${tr('Automatic (delayed)')}'),
              ('type:manual', '${tr('Startup')}: ${tr('Manual')}'),
              ('type:disabled', '${tr('Startup')}: ${tr('Disabled')}'),
            ]);
            if (v != null) await _act(s, v);
          },
        )),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- event log
class _EventLogTab extends StatefulWidget {
  final String agentId;
  const _EventLogTab({required this.agentId});

  @override
  State<_EventLogTab> createState() => _EventLogTabState();
}

class _EventLogTabState extends State<_EventLogTab> with _Loader {
  List<Map<String, dynamic>> _events = [];
  String _type = 'Application';
  int _days = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => run(() async {
        final r = await TrmmSession.to.api.eventLog(widget.agentId, _type, _days);
        _events = [for (final e in r) Map<String, dynamic>.from(e)];
      });

  @override
  Widget build(BuildContext context) {
    final list = _events
        .where((e) => filter.isEmpty ||
            '${e['eventType']} ${e['source']} ${e['eventID']} ${e['message']}'.toLowerCase().contains(filter))
        .toList();
    return Column(children: [
      toolbar([
        TrmmRadioGroup<String>(
          options: const [('Application', 'Application'), ('System', 'System'), ('Security', 'Security')],
          value: _type,
          onChanged: (v) {
            setState(() => _type = v);
            _load();
          },
        ),
        const SizedBox(width: 8),
        DropdownButton<int>(
          value: _days,
          items: [for (final d in [1, 2, 7, 30]) DropdownMenuItem(value: d, child: Text('$d d'))],
          onChanged: (d) {
            _days = d ?? 1;
            _load();
          },
        ),
      ], _load),
      Expanded(
        child: body(_Table(
          columns: [
            (tr('Type'), 1),
            (tr('Source'), 2),
            ('ID', 1),
            (tr('Time'), 2),
            (tr('Message'), 6),
          ],
          rows: [
            for (final e in list)
              ['${e['eventType']}', '${e['source']}', '${e['eventID']}', '${e['time']}', '${e['message']}'.replaceAll('\n', ' ')]
          ],
          onSecondary: (i, pos) => showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: Text('${list[i]['source']} — ${list[i]['eventID']}'),
              content: SizedBox(width: 600, child: SingleChildScrollView(child: SelectableText('${list[i]['message']}'))),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
            ),
          ),
        )),
      ),
    ]);
  }
}
