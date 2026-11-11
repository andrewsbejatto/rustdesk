// Bottom panel of the dashboard: agent tabs (same order as the web panel) and
// the Summary tab laid out like the web panel's.

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_layout.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';
import 'trmm_agent_actions.dart';
import 'trmm_agent_tabs.dart';
import 'trmm_dashboard_page.dart';
import 'trmm_remote_background_page.dart';

class TrmmAgentSummary extends StatelessWidget {
  final TrmmRow row;
  final VoidCallback onChanged;
  const TrmmAgentSummary({super.key, required this.row, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!row.isAgent) return _DeviceSummary(row: row, onChanged: onChanged);
    final agentId = row.agent!['agent_id'] as String;
    final windows = row.agent!['plat'] == 'windows';
    final tabs = <(IconData, String, Widget)>[
      (Icons.info, tr('Summary'), _AgentSummary(row: row, onChanged: onChanged)),
      (Icons.checklist, tr('Checks'), ChecksTab(agentId: agentId)),
      (Icons.format_list_bulleted, tr('Tasks'), TasksTab(agentId: agentId)),
      if (windows) (Icons.system_update_alt, tr('Patches'), PatchesTab(agentId: agentId)),
      if (windows) (Icons.window, tr('Software'), SoftwareTab(agent: row.agent!)),
      (Icons.history, tr('History'), HistoryTab(agentId: agentId)),
      (Icons.sticky_note_2_outlined, tr('Notes'), NotesTab(agentId: agentId)),
      (Icons.view_week_outlined, tr('Assets'), AssetsTab(agentId: agentId)),
      (Icons.bug_report_outlined, tr('Debug'), DebugTab(agentId: agentId)),
      (Icons.manage_search, tr('Audit'), AuditTab(agentId: agentId)),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final t in tabs)
              Tab(
                height: 36,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(t.$1, size: 18),
                  const SizedBox(width: 6),
                  Text(t.$2),
                ]),
              ),
          ],
        ),
        const Divider(height: 1),
        Expanded(child: TabBarView(children: [for (final t in tabs) t.$3])),
      ]),
    );
  }
}

// ---------------------------------------------------------------- summary
class _AgentSummary extends StatefulWidget {
  final TrmmRow row;
  final VoidCallback onChanged;
  const _AgentSummary({required this.row, required this.onChanged});

  @override
  State<_AgentSummary> createState() => _AgentSummaryState();
}

class _AgentSummaryState extends State<_AgentSummary> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _a;
  Map<String, dynamic>? _remote;
  String? _error;

  String get _agentId => widget.row.agent!['agent_id'] as String;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await TrmmSession.to.api.agent(_agentId);
      Map<String, dynamic>? ra;
      if (TrmmSession.to.canUseRemoteAccess) {
        try {
          ra = await TrmmSession.to.api.remoteAccessOfAgent(_agentId);
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _a = a;
          _remote = ra;
          _error = null;
        });
      }
    } on TrmmApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Color _statusColor(String? s) => switch (s) {
        'online' => Colors.green,
        'overdue' => Colors.red,
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final r = widget.row;
    final a = _a ?? r.agent!;
    final session = TrmmSession.to;

    final header = LayoutBuilder(builder: (context, c) {
      // icon-only buttons when the panel is narrow
      final compact = c.maxWidth < 1000;
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(children: [
          IconButton(
              tooltip: tr('Refresh'),
              onPressed: () {
                setState(() => _a = null);
                _load();
              },
              icon: const Icon(Icons.refresh)),
          Icon(Icons.signal_cellular_alt, color: _statusColor(a['status'] as String?), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '${a['hostname'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
                if (a['maintenance_mode'] == true)
                  TextSpan(text: '  (${tr('Maintenance')})', style: const TextStyle(color: Colors.orange)),
                TextSpan(text: ' • ${a['operating_system'] ?? ''} • ${tr('Agent')} v${a['version'] ?? ''}'),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (session.canUseRemoteAccess) ...[
            trmmButton(
                compact: compact,
                onPressed: () => takeControlAgent(context, _agentId),
                icon: Icons.laptop,
                label: tr('Take Control')),
            trmmButton(
                compact: compact,
                onPressed: () => takeControlAgent(context, _agentId, fileTransfer: true),
                icon: Icons.folder_copy_outlined,
                label: tr('File Transfer')),
          ] else
            trmmButton(
                compact: compact,
                onPressed: () => openMesh(context, _agentId, 'control'),
                icon: Icons.laptop,
                label: tr('Take Control')),
          trmmButton(
              compact: compact,
              onPressed: () => showRemoteBackground(context, r.agent!),
              icon: Icons.terminal,
              label: tr('Remote Background')),
          Builder(
            builder: (bctx) => trmmButton(
              compact: compact,
              onPressed: () {
                final box = bctx.findRenderObject() as RenderBox;
                showAgentMenu(context, r, box.localToGlobal(Offset(0, box.size.height)), onChanged: () {
                  widget.onChanged();
                  _load();
                });
              },
              icon: Icons.more_vert,
              label: tr('Actions'),
            ),
          ),
        ]),
      );
    });

    Widget body;
    if (_error != null) {
      body = trmmErrorView(context, _error!);
    } else if (_a == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: LayoutBuilder(builder: (ctx, c) {
          final cols = [_hardware(a), _checks(a), _disks(a)];
          if (c.maxWidth < 760) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: cols);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 5, child: cols[0]),
            const SizedBox(width: 24),
            Expanded(flex: 4, child: cols[1]),
            const SizedBox(width: 24),
            Expanded(flex: 4, child: cols[2]),
          ]);
        }),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const Divider(height: 1),
      Expanded(child: body),
    ]);
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _line(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 40, child: Icon(icon, size: 22)),
          const SizedBox(width: 12),
          Expanded(child: SelectableText(text)),
        ]),
      );

  String _serial(Map<String, dynamic> a) {
    final w = a['wmi_detail'];
    if (w is! Map) return '';
    if (a['plat'] == 'windows') {
      try {
        return '${(w['bios'] as List)[0][0]['SerialNumber'] ?? ''}';
      } catch (_) {
        return '';
      }
    }
    return '${w['serialnumber'] ?? ''}';
  }

  Widget _hardware(Map<String, dynamic> a) {
    final cpu = (a['cpu_model'] as List?) ?? [];
    final cpuText = cpu.length > 1 ? '${cpu.length}x ${cpu.first}' : (cpu.isEmpty ? '' : '${cpu.first}');
    final serial = _serial(a);
    final ra = _remote;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(tr('Hardware details')),
      if ('${a['make_model'] ?? ''}'.isNotEmpty) _line(Icons.desktop_windows_outlined, '${a['make_model']}'),
      if (cpuText.isNotEmpty) _line(Icons.memory, cpuText),
      if (a['total_ram'] != null) _line(Icons.view_comfy_alt_outlined, '${a['total_ram']} GB RAM'),
      for (final d in (a['physical_disks'] as List? ?? [])) _line(Icons.storage, '$d'),
      if ('${a['graphics'] ?? ''}'.isNotEmpty) _line(Icons.tv, '${a['graphics']}'),
      if (serial.isNotEmpty) _line(Icons.qr_code_2, serial),
      _line(Icons.public, tr('Public IP: {0}', [a['public_ip'] ?? ''])),
      _line(Icons.lan_outlined, tr('Local IP: {0}', [a['local_ips'] ?? ''])),
      if (ra != null) _line(Icons.screen_share_outlined, '${tr('Remote access')}: ${_remoteText(ra)}'),
    ]);
  }

  Widget _checks(Map<String, dynamic> a) {
    final c = (a['checks'] as Map?) ?? {};
    final total = (c['total'] as num?) ?? 0;
    Widget chip(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: Chip(avatar: Icon(icon, color: color, size: 20), label: Text(text)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(tr('Checks status')),
      if (total == 0)
        Text(tr('No checks'))
      else
        Wrap(children: [
          if ((c['passing'] ?? 0) > 0)
            chip(Icons.check_circle, Colors.green, tr('{0} passing', [c['passing']])),
          if ((c['failing'] ?? 0) > 0) chip(Icons.cancel, Colors.red, tr('{0} failing', [c['failing']])),
          if ((c['warning'] ?? 0) > 0) chip(Icons.warning, Colors.orange, tr('{0} warning', [c['warning']])),
          if ((c['info'] ?? 0) > 0) chip(Icons.info, Colors.blue, tr('{0} info', [c['info']])),
        ]),
    ]);
  }

  Widget _disks(Map<String, dynamic> a) {
    final raw = a['disks'];
    final disks = raw is Map ? raw.values.toList() : (raw is List ? raw : []);
    Color color(num p) => p < 80 ? Colors.green : (p < 95 ? Colors.orange : Colors.red);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _title(tr('Disks')),
      for (final d in disks)
        if (d is Map)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d['device'] ?? ''} (${d['fstype'] ?? ''})'),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (((d['percent'] as num?) ?? 0) / 100).clamp(0, 1).toDouble(),
                  minHeight: 16,
                  color: color((d['percent'] as num?) ?? 0),
                  backgroundColor: Colors.grey.withOpacity(0.4),
                ),
              ),
              const SizedBox(height: 4),
              Text(tr('{0} free of {1}', [d['free'] ?? '', d['total'] ?? ''])),
            ]),
          ),
    ]);
  }

  String _remoteText(Map<String, dynamic> ra) {
    switch (ra['status']) {
      case 'ok':
        return '${tr('Installed')} — ID ${ra['remote_id'] ?? ''}';
      case 'installing':
        return tr('Installing');
      case 'error':
        return '${tr('Error')}: ${ra['last_error'] ?? ''}';
      default:
        return tr('Not installed');
    }
  }
}

// ---------------------------------------------------------------- remote-access-only computer
class _DeviceSummary extends StatelessWidget {
  final TrmmRow row;
  final VoidCallback onChanged;
  const _DeviceSummary({required this.row, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final d = row.device!;
    final id = d['id'] as int;
    Widget line(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 160, child: Text(k, style: TextStyle(color: Theme.of(context).hintColor))),
            Expanded(child: SelectableText(v)),
          ]),
        );
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        const Icon(Icons.desktop_windows_outlined, color: Colors.blue),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${row.hostname} • ${tr('Remote access only')}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        TextButton.icon(
          onPressed: () => takeControlDevice(context, id),
          icon: const Icon(Icons.laptop, size: 20),
          label: Text(tr('Take Control')),
        ),
        TextButton.icon(
          onPressed: () => takeControlDevice(context, id, fileTransfer: true),
          icon: const Icon(Icons.folder_copy_outlined, size: 20),
          label: Text(tr('File Transfer')),
        ),
        Builder(
          builder: (bctx) => TextButton.icon(
            onPressed: () {
              final box = bctx.findRenderObject() as RenderBox;
              showAgentMenu(context, row, box.localToGlobal(Offset(0, box.size.height)),
                  onChanged: onChanged);
            },
            icon: const Icon(Icons.arrow_drop_down),
            label: Text(tr('Actions')),
          ),
        ),
      ]),
      const Divider(),
      line(tr('Client'), row.client),
      line(tr('Site'), row.site),
      line(tr('Operating System'), row.os),
      line(tr('Remote access'), '${d['remote_id'] ?? ''}  (${d['status']})'),
      if ('${d['last_error'] ?? ''}'.isNotEmpty) line(tr('Error'), '${d['last_error']}'),
    ]);
  }
}
