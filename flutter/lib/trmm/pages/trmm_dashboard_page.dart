// Main TRMM screen: client/site tree | agents table | selected agent summary.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_native.dart';
import '../trmm_tray.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';
import '../trmm_version.dart';
import 'trmm_agent_actions.dart';
import 'trmm_agent_panel.dart';
import '../trmm_layout.dart';
import 'trmm_alerts_page.dart';
import 'trmm_clients_dialogs.dart';
import 'trmm_install_agent_dialog.dart';
import 'trmm_quick_support_page.dart';
import 'trmm_recordings_page.dart';

/// one row of the table: a TRMM agent or a computer that only has remote access
class TrmmRow {
  final Map<String, dynamic>? agent;
  final Map<String, dynamic>? device;
  TrmmRow.agent(this.agent) : device = null;
  TrmmRow.device(this.device) : agent = null;

  bool get isAgent => agent != null;
  String get key => isAgent ? 'a:${agent!['agent_id']}' : 'd:${device!['id']}';
  String get hostname => ((agent ?? device)!['hostname'] ?? '') as String;
  String get client => ((agent ?? device)!['client_name'] ?? '') as String;
  String get site => ((agent ?? device)!['site_name'] ?? '') as String;
  String get description => (agent?['description'] ?? '') as String;
  String get user => (agent?['logged_username'] ?? '') as String;
  String get os => (agent?['operating_system'] ?? device?['os'] ?? '') as String;
  String get status => isAgent ? (agent!['status'] ?? '') as String : 'remote';
  String get lastSeen => (agent?['last_seen'] ?? device?['updated'] ?? '') as String;

  bool matches(String q) {
    if (q.isEmpty) return true;
    final s = q.toLowerCase();
    if (s.startsWith('is:')) {
      final f = s.substring(3);
      if (f == 'online' || f == 'offline' || f == 'overdue') return status == f;
      if (f == 'maintenance') return agent?['maintenance_mode'] == true;
      if (f == 'reboot') return agent?['needs_reboot'] == true;
      if (f == 'remote') return !isAgent;
      return true;
    }
    return [hostname, client, site, description, user, os].any((v) => v.toLowerCase().contains(s));
  }
}

class TrmmDashboardPage extends StatefulWidget {
  const TrmmDashboardPage({super.key});

  @override
  State<TrmmDashboardPage> createState() => _TrmmDashboardPageState();
}

class _TrmmDashboardPageState extends State<TrmmDashboardPage> {
  final session = TrmmSession.to;
  List<Map<String, dynamic>> _clients = [];
  List<TrmmRow> _rows = [];
  int? _clientId;
  int? _siteId;
  String _type = 'mixed';
  String _search = '';
  TrmmRow? _selected;
  bool _loading = false;
  String? _error;
  final _expanded = <int>{};
  bool _autostart = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    bind.mainGetVersion().then((v) {
      if (mounted) setState(() => _appVersion = v);
    });
    _type = (session.dashInfo['default_agent_tbl_tab'] as String?) ?? 'mixed';
    if (!['server', 'workstation', 'mixed'].contains(_type)) _type = 'mixed';
    _refresh();
    isStartWithSystem().then((v) {
      if (mounted) setState(() => _autostart = v);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = session.api;
      final clients = await api.clients();
      final agents = await api.agents(
          clientId: _clientId, siteId: _siteId, monitoringType: _type == 'mixed' ? null : _type);
      List<dynamic> devices = [];
      if (session.canUseRemoteAccess) {
        try {
          devices = await api.client.get('/remoteaccess/devices/', query: {
            if (_siteId != null) 'site': _siteId else if (_clientId != null) 'client': _clientId,
            'without_agent': 'true',
          }) as List;
        } on TrmmApiException catch (_) {}
      }
      _clients = [for (final c in clients) Map<String, dynamic>.from(c)];
      _rows = [
        for (final a in agents) TrmmRow.agent(Map<String, dynamic>.from(a)),
        for (final d in devices) TrmmRow.device(Map<String, dynamic>.from(d)),
      ]..sort((a, b) => a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase()));
      if (_selected != null) {
        _selected = _rows.firstWhereOrNull((r) => r.key == _selected!.key);
      }
    } on TrmmApiException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _selectNode({int? client, int? site}) {
    _clientId = client;
    _siteId = site;
    _refresh();
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        _toolbar(),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          // drag the dividers to resize (double click restores)
          child: TrmmSplit(
            axis: Axis.horizontal,
            storageKey: 'trmm-split-tree',
            initial: 0.18,
            minFirst: 150,
            minSecond: 400,
            first: _tree(),
            second: TrmmSplit(
              axis: Axis.vertical,
              storageKey: 'trmm-split-summary',
              initial: 0.55,
              minFirst: 120,
              minSecond: 160,
              first: _table(),
              second: _summary(),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _toolbar() => LayoutBuilder(builder: (context, c) => _toolbarFor(c.maxWidth));

  Widget _toolbarFor(double width) {
    final server = session.server;
    // small screens (1024x768...): icon-only buttons, shorter controls
    final compact = width < 1350;
    final tiny = width < 1100;
    Widget seg(String label, IconData icon) =>
        tiny ? Tooltip(message: label, child: Icon(icon, size: 18)) : Text(label);
    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          const Icon(Icons.dns_outlined, size: 18),
          const SizedBox(width: 6),
          if (!tiny)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: compact ? 120 : 220),
              child: Text(server?.name ?? '',
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          SizedBox(width: tiny ? 4 : 16),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'server', label: seg(tr('Servers tab'), Icons.dns)),
              ButtonSegment(value: 'workstation', label: seg(tr('Workstations'), Icons.computer)),
              ButtonSegment(value: 'mixed', label: seg(tr('Mixed'), Icons.all_inclusive)),
            ],
            selected: {_type},
            showSelectedIcon: false,
            style: trmmSegmentedStyle(context),
            onSelectionChanged: (s) {
              _type = s.first;
              _refresh();
            },
          ),
          const SizedBox(width: 8),
          // fixed width: a Flexible would keep unused space at the end of the bar
          SizedBox(
              width: tiny ? 170 : 260,
              child: SizedBox(
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: compact ? tr('Search') : '${tr('Search')} (is:online, is:remote...)',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _search = v.trim()),
                ),
              )),
          IconButton(tooltip: tr('Refresh'), onPressed: _refresh, icon: const Icon(Icons.refresh)),
          const Spacer(),
          if (session.canUseRemoteAccess)
            trmmButton(
              compact: compact,
              onPressed: () => showDialog(
                  context: context,
                  builder: (_) =>
                      InstallAgentDialog(clients: _clients, clientId: _clientId, siteId: _siteId)),
              icon: Icons.install_desktop,
              label: tr('Install agent'),
            ),
          if (session.canUseQuickSupport || session.canUseRemoteAccess)
            trmmButton(
              compact: compact,
              onPressed: () => showDialog(context: context, builder: (_) => const TrmmQuickSupportDialog()),
              icon: Icons.support_agent,
              label: tr('Quick Support'),
            ),
          if (session.canViewRecordings)
            IconButton(
              tooltip: tr('Session Recordings'),
              onPressed: () => showDialog(context: context, builder: (_) => const TrmmRecordingsDialog()),
              icon: const Icon(Icons.video_library_outlined),
            ),
          Obx(() => IconButton(
                tooltip: tr('Alerts'),
                onPressed: () => showDialog(context: context, builder: (_) => const TrmmAlertsDialog()),
                icon: Badge(
                  isLabelVisible: session.alertsCount.value > 0,
                  label: Text('${session.alertsCount.value}'),
                  child: const Icon(Icons.notifications_outlined),
                ),
              )),
          if ((server?.webUrl ?? '').isNotEmpty)
            IconButton(
              tooltip: tr('Open web dashboard'),
              onPressed: () => launchUrl(Uri.parse(server!.webUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_browser),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) async {
              if (v == 'logout') await session.logout();
              if (v.startsWith('srv:')) await session.selectServer(v.substring(4));
              if (v.startsWith('close:')) {
                await setTrmmCloseAction(v.substring(6));
                if (mounted) setState(() {});
              }
              if (v == 'autostart') {
                await setStartWithSystem(!_autostart);
                _autostart = await isStartWithSystem();
                if (mounted) setState(() {});
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(server?.username ?? '')),
              const PopupMenuDivider(),
              for (final s in session.store.servers)
                if (s.id != server?.id)
                  PopupMenuItem(value: 'srv:${s.id}', child: Text('${tr('Server')}: ${s.name}')),
              CheckedPopupMenuItem(
                  value: 'autostart', checked: _autostart, child: Text(tr('Start with the system'))),
              const PopupMenuDivider(),
              PopupMenuItem(enabled: false, height: 28, child: Text(tr('When closing the window:'))),
              for (final (v, label) in [
                ('', tr('Ask')),
                ('tray', tr('Minimize to tray')),
                ('quit', tr('Quit'))
              ])
                CheckedPopupMenuItem(value: 'close:$v', checked: trmmCloseAction == v, child: Text(label)),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'logout', child: Text(tr('Logout'))),
              const PopupMenuDivider(),
              PopupMenuItem(
                enabled: false,
                height: 40,
                child: DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodySmall,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Tactical RMM: v${session.dashInfo['trmm_version'] ?? '?'}'),
                    Text('RustDesk: v${_appVersion.isEmpty ? '?' : _appVersion}'),
                    const Text('TRMM Desktop: v$trmmDesktopVersion'),
                  ]),
                ),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _tree() {
    final theme = Theme.of(context);
    Widget node(String label, bool selected, VoidCallback onTap,
            {double indent = 0, Widget? leading, Widget? trailing, void Function(Offset position)? onMenu}) =>
        GestureDetector(
          onSecondaryTapDown: onMenu == null ? null : (d) => onMenu(d.globalPosition),
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.only(left: 8 + indent, right: 4),
            selected: selected,
            selectedTileColor: theme.colorScheme.primary.withOpacity(0.12),
            leading: leading,
            minLeadingWidth: 0,
            title: Text(label, overflow: TextOverflow.ellipsis),
            trailing: trailing,
            onTap: onTap,
          ),
        );

    return ListView(children: [
      node(tr('All Clients'), _clientId == null && _siteId == null, () => _selectNode(),
          leading: const Icon(Icons.apartment, size: 18),
          trailing: IconButton(
            tooltip: tr('Add client'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => _clientDialog(),
          ),
          onMenu: (p) => _treeMenu(p, null, null)),
      for (final c in _clients) ...[
        node(
          c['name'] as String,
          _clientId == c['id'] && _siteId == null,
          () => _selectNode(client: c['id'] as int),
          leading: InkWell(
            onTap: () => setState(() =>
                _expanded.contains(c['id']) ? _expanded.remove(c['id']) : _expanded.add(c['id'] as int)),
            child: Icon(_expanded.contains(c['id']) ? Icons.expand_more : Icons.chevron_right, size: 18),
          ),
          trailing: c['failing_checks']?['error'] == true
              ? const Icon(Icons.error, color: Colors.red, size: 14)
              : null,
          onMenu: (p) => _treeMenu(p, c, null),
        ),
        if (_expanded.contains(c['id']))
          for (final s in (c['sites'] as List? ?? []))
            node(
              s['name'] as String,
              _siteId == s['id'],
              () => _selectNode(client: c['id'] as int, site: s['id'] as int),
              indent: 24,
              leading: const Icon(Icons.location_on_outlined, size: 16),
              trailing: s['maintenance_mode'] == true ? const Icon(Icons.construction, size: 14) : null,
              onMenu: (p) => _treeMenu(p, c, Map<String, dynamic>.from(s)),
            ),
      ],
    ]);
  }

  // ---------------------------------------------------------------- clients / sites
  Future<void> _clientDialog([Map<String, dynamic>? client]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => ClientFormDialog(client: client));
    if (ok == true) _refresh();
  }

  Future<void> _siteDialog({Map<String, dynamic>? site, int? clientId}) async {
    final ok = await showDialog<bool>(
        context: context, builder: (_) => SiteFormDialog(clients: _clients, site: site, clientId: clientId));
    if (ok == true) _refresh();
  }

  Future<void> _deleteDialog(Map<String, dynamic> client, [Map<String, dynamic>? site]) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => DeleteClientSiteDialog(clients: _clients, client: client, site: site));
    if (ok == true) {
      if (site != null ? _siteId == site['id'] : _clientId == client['id']) {
        _clientId = null;
        _siteId = null;
      }
      _refresh();
    }
  }

  Future<void> _treeMenu(Offset p, Map<String, dynamic>? client, Map<String, dynamic>? site) async {
    PopupMenuItem<String> item(String v, IconData icon, String label) => PopupMenuItem(
          value: v,
          height: 36,
          child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)]),
        );
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(p.dx, p.dy, p.dx, p.dy),
      constraints: const BoxConstraints(minWidth: 220),
      items: [
        item('add_client', Icons.add_business_outlined, tr('Add client')),
        if (client != null) ...[
          item('add_site', Icons.add_location_alt_outlined, tr('Add site')),
          const PopupMenuDivider(),
          if (site == null) ...[
            item('edit_client', Icons.edit_outlined, tr('Edit client')),
            item('delete_client', Icons.delete_outline, tr('Delete client')),
          ] else ...[
            item('edit_site', Icons.edit_outlined, tr('Edit site')),
            item('delete_site', Icons.delete_outline, tr('Delete site')),
          ],
        ],
      ],
    );
    switch (v) {
      case 'add_client':
        await _clientDialog();
      case 'add_site':
        await _siteDialog(clientId: client!['id'] as int);
      case 'edit_client':
        await _clientDialog(client);
      case 'delete_client':
        await _deleteDialog(client!);
      case 'edit_site':
        await _siteDialog(site: site);
      case 'delete_site':
        await _deleteDialog(client!, site);
    }
  }

  Widget _statusIcon(TrmmRow r) {
    switch (r.status) {
      case 'online':
        return const Icon(Icons.circle, color: Colors.green, size: 12);
      case 'overdue':
        return const Icon(Icons.circle, color: Colors.red, size: 12);
      case 'remote':
        return Tooltip(
            message: tr('Remote access only'),
            child: const Icon(Icons.desktop_windows_outlined, color: Colors.blue, size: 14));
      default:
        return const Icon(Icons.circle, color: Colors.grey, size: 12);
    }
  }

  Widget _table() {
    if (_error != null) {
      return trmmErrorView(context, _error!);
    }
    final rows = _rows.where((r) => r.matches(_search)).toList();
    if (rows.isEmpty && !_loading) return Center(child: Text(tr('No agents')));

    final header = TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).hintColor);
    Widget cell(String t, int flex, {TextStyle? style}) =>
        Expanded(flex: flex, child: Text(t, overflow: TextOverflow.ellipsis, maxLines: 1, style: style));

    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          const SizedBox(width: 40),
          cell(tr('Client'), 2, style: header),
          cell(tr('Site'), 2, style: header),
          cell(tr('Hostname'), 3, style: header),
          cell(tr('Description'), 3, style: header),
          cell(tr('User'), 2, style: header),
          cell(tr('Last Response'), 2, style: header),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          itemCount: rows.length,
          itemExtent: 30,
          itemBuilder: (ctx, i) {
            final r = rows[i];
            final sel = _selected?.key == r.key;
            return Listener(
              onPointerDown: (e) {
                if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
                  setState(() => _selected = r);
                  showAgentMenu(context, r, e.position, onChanged: _refresh);
                }
              },
              child: InkWell(
                onTap: () => setState(() => _selected = r),
                onDoubleTap: () => _takeControl(r),
                child: Container(
                  color: sel ? Theme.of(context).colorScheme.primary.withOpacity(0.15) : null,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(children: [
                    SizedBox(width: 20, child: _statusIcon(r)),
                    SizedBox(
                        width: 20,
                        child: r.agent?['maintenance_mode'] == true
                            ? const Icon(Icons.construction, size: 14)
                            : r.agent?['needs_reboot'] == true
                                ? const Icon(Icons.restart_alt, size: 14, color: Colors.orange)
                                : null),
                    cell(r.client, 2),
                    cell(r.site, 2),
                    cell(r.hostname, 3,
                        style: r.isAgent ? null : const TextStyle(fontStyle: FontStyle.italic)),
                    cell(r.description, 3),
                    cell(r.user, 2,
                        style:
                            r.agent?['italic'] == true ? const TextStyle(fontStyle: FontStyle.italic) : null),
                    cell(_ago(r.lastSeen), 2),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }

  void _takeControl(TrmmRow r) {
    if (!session.canUseRemoteAccess) {
      if (r.isAgent) openMesh(context, r.agent!['agent_id'] as String, 'control');
      return;
    }
    if (r.isAgent) {
      takeControlAgent(context, r.agent!['agent_id'] as String);
    } else {
      takeControlDevice(context, r.device!['id'] as int);
    }
  }

  Widget _summary() {
    final r = _selected;
    if (r == null) return Center(child: Text(tr('Select an agent')));
    return TrmmAgentSummary(key: ValueKey(r.key), row: r, onChanged: _refresh);
  }
}

String _ago(String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inMinutes < 1) return '< 1 min';
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inDays < 1) return '${d.inHours} h';
  return '${d.inDays} d';
}
