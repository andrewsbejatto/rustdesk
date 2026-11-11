// Agent tabs of the bottom panel (same data as the web panel tabs):
// checks, automated tasks, Windows updates, software, history and notes.

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';

/// list tab with loading/error/refresh and an optional toolbar
abstract class _ListTab extends StatefulWidget {
  final String agentId;
  const _ListTab({super.key, required this.agentId});
}

abstract class _ListTabState<T extends _ListTab> extends State<T> {
  List<Map<String, dynamic>> items = [];
  bool loading = false;
  String? error;

  Future<List<dynamic>> fetch();
  List<Widget> actions() => [];
  Widget buildItem(Map<String, dynamic> item);
  String get empty => tr('Nothing to show');

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      items = [for (final i in await fetch()) Map<String, dynamic>.from(i)];
    } on TrmmApiException catch (e) {
      error = e.message;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> act(Future<dynamic> Function() f, {bool reload = true}) async {
    try {
      final r = await f();
      if (mounted && r is String && r.isNotEmpty) trmmSnack(context, r);
      if (reload) await load();
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          ...actions(),
          const Spacer(),
          if (loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          IconButton(onPressed: loading ? null : load, icon: const Icon(Icons.refresh, size: 18)),
        ]),
      ),
      Expanded(
        child: error != null
            ? trmmErrorView(context, error!)
            : items.isEmpty && !loading
                ? Center(child: Text(empty))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => buildItem(items[i]),
                  ),
      ),
    ]);
  }
}

Widget _statusIcon(String? status) {
  switch (status) {
    case 'passing':
      return const Icon(Icons.check_circle, color: Colors.green, size: 18);
    case 'failing':
      return const Icon(Icons.error, color: Colors.red, size: 18);
    case 'pending':
      return const Icon(Icons.schedule, color: Colors.grey, size: 18);
    default:
      return const Icon(Icons.help_outline, color: Colors.grey, size: 18);
  }
}

String _date(dynamic iso) {
  final t = DateTime.tryParse('${iso ?? ''}');
  if (t == null) return '${iso ?? ''}';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

void _showText(BuildContext context, String title, String text) => showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 700,
          child: SingleChildScrollView(
              child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Close')))],
      ),
    );

// ---------------------------------------------------------------- checks
class ChecksTab extends _ListTab {
  const ChecksTab({super.key, required super.agentId});
  @override
  State<ChecksTab> createState() => _ChecksTabState();
}

class _ChecksTabState extends _ListTabState<ChecksTab> {
  @override
  Future<List<dynamic>> fetch() async =>
      await TrmmSession.to.api.client.get('/agents/${widget.agentId}/checks/') as List;

  @override
  List<Widget> actions() => [
        TextButton.icon(
          onPressed: () => act(() => TrmmSession.to.api.client.post('/checks/${widget.agentId}/run/')),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(tr('Run checks now')),
        ),
      ];

  @override
  Widget buildItem(Map<String, dynamic> c) {
    final r = (c['check_result'] as Map?) ?? {};
    return ListTile(
      dense: true,
      leading: _statusIcon(r['status'] as String?),
      title: Text('${c['readable_desc'] ?? c['name'] ?? ''}'),
      subtitle: Text('${r['more_info'] ?? ''}'.split('\n').first, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(_date(r['last_run'])),
      onTap: () => _showText(context, '${c['readable_desc'] ?? ''}', '${r['more_info'] ?? ''}'),
    );
  }
}

// ---------------------------------------------------------------- tasks
class TasksTab extends _ListTab {
  const TasksTab({super.key, required super.agentId});
  @override
  State<TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends _ListTabState<TasksTab> {
  @override
  Future<List<dynamic>> fetch() async =>
      await TrmmSession.to.api.client.get('/agents/${widget.agentId}/tasks/') as List;

  @override
  Widget buildItem(Map<String, dynamic> t) {
    final r = (t['task_result'] as Map?) ?? {};
    return ListTile(
      dense: true,
      leading: _statusIcon(r['status'] as String?),
      title: Text('${t['name'] ?? ''}${t['enabled'] == false ? '  (${tr('Disabled')})' : ''}'),
      subtitle: Text('${t['schedule'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(_date(r['last_run'])),
        IconButton(
          tooltip: tr('Run task now'),
          icon: const Icon(Icons.play_arrow, size: 18),
          // policy tasks need the agent (same as the web panel)
          onPressed: () => act(() => TrmmSession.to.api.client
              .post('/tasks/${t['id']}/run/', t['policy'] != null ? {'agent_id': widget.agentId} : {})),
        ),
      ]),
      onTap: () => _showText(context, '${t['name']}',
          'retcode: ${r['retcode'] ?? ''}\n\nstdout:\n${r['stdout'] ?? ''}\n\nstderr:\n${r['stderr'] ?? ''}'),
    );
  }
}

// ---------------------------------------------------------------- windows updates
class PatchesTab extends _ListTab {
  const PatchesTab({super.key, required super.agentId});
  @override
  State<PatchesTab> createState() => _PatchesTabState();
}

class _PatchesTabState extends _ListTabState<PatchesTab> {
  bool _showInstalled = false;

  @override
  Future<List<dynamic>> fetch() async {
    final r = await TrmmSession.to.api.client.get('/winupdate/${widget.agentId}/') as List;
    return _showInstalled ? r : r.where((u) => u['installed'] != true).toList();
  }

  @override
  List<Widget> actions() => [
        TextButton.icon(
          onPressed: () => act(() => TrmmSession.to.api.client.post('/winupdate/${widget.agentId}/scan/')),
          icon: const Icon(Icons.search, size: 18),
          label: Text(tr('Scan for updates')),
        ),
        TextButton.icon(
          onPressed: () async {
            if (!await trmmConfirm(context, tr('Install the approved updates now?'))) return;
            await act(() => TrmmSession.to.api.client.post('/winupdate/${widget.agentId}/install/'));
          },
          icon: const Icon(Icons.system_update_alt, size: 18),
          label: Text(tr('Install approved updates')),
        ),
        FilterChip(
          label: Text(tr('Show installed')),
          selected: _showInstalled,
          onSelected: (v) {
            _showInstalled = v;
            load();
          },
        ),
      ];

  @override
  Widget buildItem(Map<String, dynamic> u) => ListTile(
        dense: true,
        leading: Icon(u['installed'] == true ? Icons.check_circle : Icons.system_update,
            size: 18, color: u['installed'] == true ? Colors.green : null),
        title: Text('${u['title'] ?? u['kb'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${u['severity'] ?? ''}  ${u['date_installed'] ?? ''}'),
        trailing: DropdownButton<String>(
          value: ['inherit', 'approve', 'ignore', 'nothing'].contains(u['action']) ? u['action'] as String : null,
          underline: const SizedBox(),
          items: [
            DropdownMenuItem(value: 'inherit', child: Text(tr('Inherit'))),
            DropdownMenuItem(value: 'approve', child: Text(tr('Approve'))),
            DropdownMenuItem(value: 'ignore', child: Text(tr('Ignore'))),
            DropdownMenuItem(value: 'nothing', child: Text(tr('Do nothing'))),
          ],
          onChanged: (v) {
            if (v != null) act(() => TrmmSession.to.api.client.put('/winupdate/${u['id']}/', {'action': v}));
          },
        ),
        onTap: () => _showText(context, '${u['kb'] ?? ''}', '${u['title'] ?? ''}\n\n${u['description'] ?? ''}'),
      );
}

// ---------------------------------------------------------------- software
class SoftwareTab extends _ListTab {
  final Map<String, dynamic> agent;
  SoftwareTab({super.key, required this.agent}) : super(agentId: agent['agent_id'] as String);
  @override
  State<SoftwareTab> createState() => _SoftwareTabState();
}

class _SoftwareTabState extends _ListTabState<SoftwareTab> {
  String _filter = '';
  List<Map<String, dynamic>> _all = [];

  @override
  Future<List<dynamic>> fetch() async {
    final r = await TrmmSession.to.api.client.get('/software/${widget.agentId}/');
    final list = r is Map ? (r['software'] as List? ?? []) : <dynamic>[];
    _all = [for (final s in list) Map<String, dynamic>.from(s)]
      ..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    return _filtered();
  }

  List<Map<String, dynamic>> _filtered() => _filter.isEmpty
      ? _all
      : _all.where((s) => '${s['name']} ${s['publisher']}'.toLowerCase().contains(_filter)).toList();

  @override
  List<Widget> actions() => [
        SizedBox(
          width: 220,
          child: TextField(
            decoration: InputDecoration(
                isDense: true, prefixIcon: const Icon(Icons.search, size: 18), hintText: tr('Search')),
            onChanged: (v) => setState(() {
              _filter = v.trim().toLowerCase();
              items = _filtered();
            }),
          ),
        ),
        TextButton.icon(
          onPressed: () => act(() => TrmmSession.to.api.client.put('/software/${widget.agentId}/')),
          icon: const Icon(Icons.sync, size: 18),
          label: Text(tr('Refresh list from agent')),
        ),
      ];

  @override
  Widget buildItem(Map<String, dynamic> s) => ListTile(
        dense: true,
        title: Text('${s['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${s['publisher'] ?? ''}  ${s['version'] ?? ''}  ${s['install_date'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: (s['uninstall'] ?? '').toString().isEmpty
            ? null
            : IconButton(
                tooltip: tr('Uninstall'),
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () async {
                  if (!await trmmConfirm(context, '${tr('Uninstall')} ${s['name']}?')) return;
                  await act(
                      () => TrmmSession.to.api.client.post('/software/${widget.agentId}/uninstall/', {
                            'name': s['name'],
                            'command': s['uninstall'],
                            'timeout': 1800,
                            'run_as_user': false,
                          }),
                      reload: false);
                },
              ),
      );
}

// ---------------------------------------------------------------- history
class HistoryTab extends _ListTab {
  const HistoryTab({super.key, required super.agentId});
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends _ListTabState<HistoryTab> {
  @override
  Future<List<dynamic>> fetch() async {
    final r = await TrmmSession.to.api.client.get('/agents/${widget.agentId}/history/');
    final list = r is Map ? (r['results'] as List? ?? []) : r as List;
    return list.reversed.take(300).toList();
  }

  @override
  Widget buildItem(Map<String, dynamic> h) {
    final what = h['type'] == 'script_run' ? (h['script_name'] ?? '') : (h['command'] ?? '');
    return ListTile(
      dense: true,
      leading: Icon(h['type'] == 'script_run' ? Icons.description_outlined : Icons.terminal, size: 18),
      title: Text('$what', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${h['username'] ?? ''}  ${h['status'] ?? ''}'),
      trailing: Text(_date(h['time'])),
      onTap: () {
        final res = h['script_results'];
        final out = res is Map
            ? 'retcode: ${res['retcode']}\n\nstdout:\n${res['stdout'] ?? ''}\n\nstderr:\n${res['stderr'] ?? ''}'
            : '${h['results'] ?? h['output'] ?? ''}';
        _showText(context, '$what', out);
      },
    );
  }
}

// ---------------------------------------------------------------- notes
class NotesTab extends _ListTab {
  const NotesTab({super.key, required super.agentId});
  @override
  State<NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends _ListTabState<NotesTab> {
  @override
  Future<List<dynamic>> fetch() async =>
      await TrmmSession.to.api.client.get('/agents/${widget.agentId}/notes/') as List;

  @override
  List<Widget> actions() => [
        TextButton.icon(
          onPressed: () async {
            final c = TextEditingController();
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('Add note')),
                content: SizedBox(width: 500, child: TextField(controller: c, autofocus: true, maxLines: 6)),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save'))),
                ],
              ),
            );
            if (ok == true && c.text.trim().isNotEmpty) {
              await act(() => TrmmSession.to.api.client
                  .post('/agents/notes/', {'agent_id': widget.agentId, 'note': c.text.trim()}));
            }
          },
          icon: const Icon(Icons.note_add_outlined, size: 18),
          label: Text(tr('Add note')),
        ),
      ];

  @override
  Widget buildItem(Map<String, dynamic> n) => ListTile(
        dense: true,
        title: Text('${n['note'] ?? ''}'),
        subtitle: Text('${n['username'] ?? ''}  ${_date(n['entry_time'])}'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: () async {
            if (!await trmmConfirm(context, tr('Delete this note?'))) return;
            await act(() => TrmmSession.to.api.client.delete('/agents/notes/${n['pk']}/'));
          },
        ),
      );
}

// ---------------------------------------------------------------- assets (wmi_detail)
class AssetsTab extends StatefulWidget {
  final String agentId;
  const AssetsTab({super.key, required this.agentId});
  @override
  State<AssetsTab> createState() => _AssetsTabState();
}

class _AssetsTabState extends State<AssetsTab> {
  Map<String, dynamic>? _wmi;
  String? _error;

  static const _sections = <(String, String)>[
    ('os', 'Operating System'),
    ('cpu', 'CPU'),
    ('mem', 'Memory'),
    ('usb', 'USB'),
    ('bios', 'Bios'),
    ('disk', 'Disks'),
    ('comp_sys', 'Computer System'),
    ('base_board', 'Motherboard'),
    ('comp_sys_prod', 'Computer System Product'),
    ('network_config', 'Network Config'),
    ('graphics', 'Graphics'),
    ('desktop_monitor', 'Monitors'),
    ('network_adapter', 'Network Adapters'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await TrmmSession.to.api.agent(widget.agentId);
      final w = a['wmi_detail'];
      if (mounted) setState(() => _wmi = w is Map ? Map<String, dynamic>.from(w) : {});
    } on TrmmApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// WMI data comes as [[{..}], [{..}]] or {..}; flatten to a list of maps
  List<Map> _objects(dynamic v) {
    final out = <Map>[];
    void walk(dynamic x) {
      if (x is Map) {
        out.add(x);
      } else if (x is List) {
        for (final i in x) {
          walk(i);
        }
      }
    }

    walk(v);
    return out;
  }

  Widget _section(dynamic data) {
    final objs = _objects(data);
    if (objs.isEmpty) {
      return Center(child: Text(data == null ? tr('Nothing to show') : '$data'));
    }
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final o in objs) ...[
        for (final e in o.entries)
          if (e.value != null && '${e.value}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 260,
                    child: Text('${e.key}', style: TextStyle(color: Theme.of(context).hintColor))),
                Expanded(child: SelectableText('${e.value}')),
              ]),
            ),
        const Divider(),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return trmmErrorView(context, _error!, colored: false);
    final w = _wmi;
    if (w == null) return const Center(child: CircularProgressIndicator());
    final sections = _sections.where((s) => w.containsKey(s.$1)).toList();
    // linux/mac agents: plain key/value data
    if (sections.isEmpty) return _section(w);
    return DefaultTabController(
      length: sections.length,
      child: Column(children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final s in sections) Tab(height: 32, text: tr(s.$2))],
        ),
        Expanded(child: TabBarView(children: [for (final s in sections) _section(w[s.$1])])),
      ]),
    );
  }
}

// ---------------------------------------------------------------- debug log
class DebugTab extends _ListTab {
  const DebugTab({super.key, required super.agentId});
  @override
  State<DebugTab> createState() => _DebugTabState();
}

class _DebugTabState extends _ListTabState<DebugTab> {
  String _level = 'all';

  @override
  Future<List<dynamic>> fetch() async => await TrmmSession.to.api.client.patch('/logs/debug/', {
        'agentFilter': widget.agentId,
        if (_level != 'all') 'logLevelFilter': _level,
      }) as List;

  @override
  List<Widget> actions() => [
        DropdownButton<String>(
          value: _level,
          underline: const SizedBox(),
          items: [
            DropdownMenuItem(value: 'all', child: Text(tr('All levels'))),
            for (final l in ['info', 'warning', 'error', 'critical'])
              DropdownMenuItem(value: l, child: Text(tr('Level: {0}', [l]))),
          ],
          onChanged: (v) {
            _level = v ?? 'all';
            load();
          },
        ),
      ];

  @override
  Widget buildItem(Map<String, dynamic> l) => ListTile(
        dense: true,
        leading: Icon(
          switch (l['log_level']) {
            'error' || 'critical' => Icons.error,
            'warning' => Icons.warning,
            _ => Icons.info_outline,
          },
          size: 18,
          color: switch (l['log_level']) {
            'error' || 'critical' => Colors.red,
            'warning' => Colors.orange,
            _ => null,
          },
        ),
        title: Text('${l['message'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${l['log_type'] ?? ''}'),
        trailing: Text(_date(l['entry_time'])),
        onTap: () => _showText(context, '${l['log_type'] ?? ''}', '${l['message'] ?? ''}'),
      );
}

// ---------------------------------------------------------------- audit log
class AuditTab extends _ListTab {
  const AuditTab({super.key, required super.agentId});
  @override
  State<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends _ListTabState<AuditTab> {
  @override
  Future<List<dynamic>> fetch() async {
    final r = await TrmmSession.to.api.client.patch('/logs/audit/', {
      'agentFilter': [widget.agentId],
      'pagination': {'sortBy': 'entry_time', 'descending': true, 'page': 1, 'rowsPerPage': 200},
    });
    return r is Map ? (r['audit_logs'] as List? ?? []) : [];
  }

  @override
  Widget buildItem(Map<String, dynamic> l) => ListTile(
        dense: true,
        leading: const Icon(Icons.manage_search, size: 18),
        title: Text('${l['message'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${l['username'] ?? ''}  •  ${l['action'] ?? ''}  •  ${l['object_type'] ?? ''}'),
        trailing: Text(_date(l['entry_time'])),
        onTap: () {
          final before = l['before_value'], after = l['after_value'];
          _showText(context, '${l['action'] ?? ''}',
              '${l['message'] ?? ''}${before != null ? '\n\nbefore:\n$before' : ''}${after != null ? '\n\nafter:\n$after' : ''}');
        },
      );
}
