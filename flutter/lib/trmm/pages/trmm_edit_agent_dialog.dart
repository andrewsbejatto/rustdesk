// Edit agent: same sections, fields and payload as the web panel
// (EditAgent.vue + PatchPolicyForm.vue): General, Custom fields, Patches,
// Automation policies.

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_layout.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';
import 'trmm_clients_dialogs.dart';

class EditAgentDialog extends StatefulWidget {
  final String agentId;
  const EditAgentDialog({super.key, required this.agentId});

  @override
  State<EditAgentDialog> createState() => _EditAgentDialogState();
}

class _EditAgentDialogState extends State<EditAgentDialog> {
  Map<String, dynamic>? _agent;
  List<(int, String)> _sites = [];
  /// client name + its sites, for the tree-like site selector (as in the web)
  List<(String, List<(int, String)>)> _tree = [];
  final _cf = TrmmCustomFields();
  String? _timezone;
  String? _originalTz;
  List<String> _timezones = [];
  Map<String, dynamic>? _patch; // agent.winupdatepolicy[0]
  int _section = 0;
  bool _busy = false;
  String? _error;

  final _description = TextEditingController();
  final _shellCustom = TextEditingController();
  final _checkInterval = TextEditingController();
  final _offline = TextEditingController();
  final _overdue = TextEditingController();
  final _reprocessTimes = TextEditingController();

  String get _plat => '${_agent?['plat'] ?? 'windows'}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = TrmmSession.to.api;
      final a = await api.agent(widget.agentId);
      final clients = await api.clients();
      await _cf.load('agent', a['custom_fields'] as List?);
      _tree = [
        for (final c in clients)
          ('${c['name']}', [for (final s in (c['sites'] as List? ?? [])) (s['id'] as int, '${s['name']}')])
      ];
      _sites = [for (final c in _tree) ...c.$2];
      _timezones = [for (final t in (a['all_timezones'] as List? ?? [])) '$t'];
      // time_zone null = inherits the global setting (web: only sent when changed)
      _timezone = (a['time_zone'] ?? a['timezone']) as String?;
      _originalTz = _timezone;
      final wp = a['winupdatepolicy'] as List?;
      _patch = (wp != null && wp.isNotEmpty) ? Map<String, dynamic>.from(wp.first) : null;
      if (_patch != null) {
        _patch!['run_time_days'] = List<int>.from(_patch!['run_time_days'] ?? []);
        _reprocessTimes.text = '${_patch!['reprocess_failed_times'] ?? 5}';
      }
      _description.text = '${a['description'] ?? ''}';
      _shellCustom.text = '${a['default_shell_custom'] ?? ''}';
      _checkInterval.text = '${a['check_interval'] ?? 120}';
      _offline.text = '${a['offline_time'] ?? 4}';
      _overdue.text = '${a['overdue_time'] ?? 30}';
      if ((a['default_shell'] ?? '') == '') a['default_shell'] = 'use_global';
      _agent = a;
    } on TrmmApiException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_description, _shellCustom, _checkInterval, _offline, _overdue, _reprocessTimes]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validate() {
    final ci = int.tryParse(_checkInterval.text);
    if (ci == null || ci < 15 || ci > 86400) return tr('Run checks every: 15 to 86400 seconds');
    final off = int.tryParse(_offline.text);
    if (off == null || off < 2) return tr('Offline after: at least 2 minutes');
    final ov = int.tryParse(_overdue.text);
    if (ov == null || ov < 3) return tr('Overdue after: at least 3 minutes');
    if (_agent!['default_shell'] == 'custom' && _shellCustom.text.trim().isEmpty) {
      return tr('Custom shell path must be provided.');
    }
    return _cf.missingRequired();
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      trmmSnack(context, err, error: true);
      return;
    }
    final a = _agent!;
    final payload = <String, dynamic>{
      'site': a['site'],
      'monitoring_type': a['monitoring_type'],
      'description': _description.text,
      'default_shell': a['default_shell'],
      'default_shell_custom': _shellCustom.text.trim(),
      'check_interval': int.parse(_checkInterval.text),
      'offline_time': int.parse(_offline.text),
      'overdue_time': int.parse(_overdue.text),
      'overdue_email_alert': a['overdue_email_alert'] == true,
      'overdue_text_alert': a['overdue_text_alert'] == true,
      'overdue_dashboard_alert': a['overdue_dashboard_alert'] == true,
      if (_timezone != _originalTz) 'time_zone': _timezone,
      if (_patch != null)
        'winupdatepolicy': [
          {..._patch!, 'reprocess_failed_times': int.tryParse(_reprocessTimes.text) ?? 5}
        ],
      'custom_fields': _cf.payload(),
    };
    setState(() => _busy = true);
    try {
      await TrmmSession.to.api.client.put('/agents/${widget.agentId}/', payload);
      if (mounted) {
        Navigator.pop(context, true);
        trmmSnack(context, tr('The agent was updated successfully'));
      }
    } on TrmmApiException catch (e) {
      if (mounted) {
        trmmSnack(context, e.message, error: true);
        setState(() => _busy = false);
      }
    }
  }

  // ---------------------------------------------------------------- layout
  @override
  Widget build(BuildContext context) {
    final size = trmmDialogSize(context, 900, 820);
    final sections = [
      tr('General'),
      tr('Custom fields'),
      if (_plat == 'windows') tr('Patches'),
      tr('Automation policies'),
    ];
    if (_section >= sections.length) _section = 0;
    final narrow = size.width < 640;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: _agent == null
            ? (_error != null
                ? trmmErrorView(context, _error!, colored: false)
                : const Center(child: CircularProgressIndicator()))
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: narrow ? 150 : 210,
                  child: ListView(children: [
                    for (var i = 0; i < sections.length; i++)
                      ListTile(
                        dense: true,
                        selected: _section == i,
                        title: Text(sections[i].toUpperCase(),
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                        onTap: () => setState(() => _section = i),
                      ),
                  ]),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ListTile(
                      title: Text(tr('Edit {0}', [_agent!['hostname'] ?? '']),
                          style: Theme.of(context).textTheme.titleLarge),
                      trailing:
                          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                        child: switch (sections[_section]) {
                          final s when s == tr('General') => _general(),
                          final s when s == tr('Custom fields') => _customFields(),
                          final s when s == tr('Patches') => _patches(),
                          _ => _policies(),
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        FilledButton(onPressed: _busy ? null : _save, child: Text(tr('Save').toUpperCase())),
                      ]),
                    ),
                  ]),
                ),
              ]),
      ),
    );
  }

  Widget _row(String label, Widget field, {double fieldWidth = 360}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth < 520) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(label),
              const SizedBox(height: 6),
              field,
            ]);
          }
          return Row(children: [
            Expanded(child: Text(label)),
            SizedBox(width: fieldWidth, child: field),
          ]);
        }),
      );

  /// clients as grey headers (not selectable) with their sites indented below
  Widget _siteSelector(Map<String, dynamic> a) {
    final hint = Theme.of(context).hintColor;
    final items = <DropdownMenuItem<int>>[];
    final labels = <Widget>[];
    var header = 0;
    for (final (client, sites) in _tree) {
      // negative values: client headers, never selected
      items.add(DropdownMenuItem(
        value: --header,
        enabled: false,
        child: Text(client, style: TextStyle(color: hint, fontSize: 13)),
      ));
      labels.add(Text(client));
      for (final (id, name) in sites) {
        items.add(DropdownMenuItem(
          value: id,
          child: Padding(padding: const EdgeInsets.only(left: 20), child: Text(name)),
        ));
        labels.add(Text('$client / $name', overflow: TextOverflow.ellipsis));
      }
    }
    return DropdownButtonFormField<int>(
      value: _sites.any((s) => s.$1 == a['site']) ? a['site'] as int : null,
      isExpanded: true,
      menuMaxHeight: 420,
      items: items,
      selectedItemBuilder: (_) => labels,
      onChanged: (v) {
        if (v != null && v > 0) setState(() => a['site'] = v);
      },
    );
  }

  // ---------------------------------------------------------------- general
  Widget _general() {
    final a = _agent!;
    final shells = switch (_plat) {
      'windows' => [
          ('use_global', tr('Inherit from Global Settings')),
          ('cmd', 'CMD'),
          ('powershell', 'PowerShell'),
          ('custom', tr('Custom')),
        ],
      _ => [('use_global', tr('Inherit from Global Settings')), ('bash', 'Bash'), ('custom', tr('Custom'))],
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _row(
        '${tr('Site')}:',
        _siteSelector(a),
      ),
      _row(
        '${tr('Type')}:',
        DropdownButtonFormField<String>(
          value: a['monitoring_type'] as String?,
          items: [
            DropdownMenuItem(value: 'workstation', child: Text(tr('Workstation'))),
            DropdownMenuItem(value: 'server', child: Text(tr('Server'))),
          ],
          onChanged: (v) => setState(() => a['monitoring_type'] = v),
        ),
      ),
      _row('${tr('Description')}:', TextField(controller: _description)),
      _row(
        '${tr('Timezone')}:',
        DropdownButtonFormField<String>(
          value: _timezones.contains(_timezone) ? _timezone : null,
          isExpanded: true,
          menuMaxHeight: 400,
          items: [for (final t in _timezones) DropdownMenuItem(value: t, child: Text(t))],
          onChanged: (v) => setState(() => _timezone = v),
        ),
      ),
      _row(
        tr('Default terminal'),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TrmmRadioGroup<String>(
            options: [for (final (v, label) in shells) (v, label)],
            value: a['default_shell'] as String?,
            onChanged: (v) => setState(() => a['default_shell'] = v),
          ),
          if (a['default_shell'] == 'custom') ...[
            const SizedBox(height: 8),
            TextField(
              controller: _shellCustom,
              decoration: InputDecoration(
                labelText: tr('Custom shell path'),
                hintText: _plat == 'windows' ? r'C:\Program Files\PowerShell\7\pwsh.exe' : '/usr/bin/fish',
              ),
            ),
          ],
        ]),
      ),
      _row(
        tr('Run checks every:'),
        TextField(
            controller: _checkInterval,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Seconds'))),
        fieldWidth: 120,
      ),
      _row(
        tr('Mark an agent as offline if it has not checked-in after:'),
        TextField(
            controller: _offline,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Minutes'))),
        fieldWidth: 120,
      ),
      _row(
        tr('Mark an agent as overdue if it has not checked-in after:'),
        TextField(
            controller: _overdue,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Minutes'))),
        fieldWidth: 120,
      ),
      Wrap(spacing: 8, children: [
        for (final (k, label) in [
          ('overdue_email_alert', tr('Email alert')),
          ('overdue_text_alert', tr('SMS alert')),
          ('overdue_dashboard_alert', tr('Dashboard alert')),
        ])
          FilterChip(
            label: Text(label),
            selected: a[k] == true,
            onSelected: (v) => setState(() => a[k] = v),
          ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------- custom fields
  Widget _customFields() {
    if (_cf.defs.isEmpty) return Text(tr('No custom fields found'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _cf.widgets(setState));
  }

  // ---------------------------------------------------------------- patches
  Widget _patches() {
    final p = _patch;
    if (p == null) return Text(tr('Nothing to show'));
    final severities = [
      ('manual', tr('Manual')),
      ('approve', tr('Approve')),
      ('ignore', tr('Ignore')),
      ('inherit', tr('Inherit')),
    ];
    Widget sel(String key, List<(String, String)> options) => DropdownButtonFormField<String>(
          value: options.any((o) => o.$1 == p[key]) ? p[key] as String : null,
          isExpanded: true,
          items: [for (final o in options) DropdownMenuItem(value: o.$1, child: Text(o.$2))],
          onChanged: (v) => setState(() => p[key] = v),
        );
    final days = p['run_time_days'] as List<int>;
    final weekDays = [
      tr('Monday'),
      tr('Tuesday'),
      tr('Wednesday'),
      tr('Thursday'),
      tr('Friday'),
      tr('Saturday'),
      tr('Sunday'),
    ];
    final hours = [for (var h = 0; h < 24; h++) (h, '${h.toString().padLeft(2, '0')}:00')];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Severity'), style: const TextStyle(fontWeight: FontWeight.bold)),
      _row(tr('Critical'), sel('critical', severities), fieldWidth: 220),
      _row(tr('Important'), sel('important', severities), fieldWidth: 220),
      _row(tr('Moderate'), sel('moderate', severities), fieldWidth: 220),
      _row(tr('Low'), sel('low', severities), fieldWidth: 220),
      _row(tr('Other'), sel('other', severities), fieldWidth: 220),
      const Divider(),
      Text(tr('Installation schedule'), style: const TextStyle(fontWeight: FontWeight.bold)),
      _row(
        tr('Frequency'),
        sel('run_time_frequency', [
          ('daily', tr('Daily/Weekly')),
          ('monthly', tr('Monthly')),
          ('inherit', tr('Inherit')),
        ]),
        fieldWidth: 220,
      ),
      if (p['run_time_frequency'] == 'monthly')
        _row(
          tr('Day of the month'),
          DropdownButtonFormField<int>(
            value: int.tryParse('${p['run_time_day']}'),
            items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
            onChanged: (v) => setState(() => p['run_time_day'] = v),
          ),
          fieldWidth: 220,
        ),
      if (p['run_time_frequency'] != 'inherit')
        _row(
          tr('At hour'),
          DropdownButtonFormField<int>(
            value: int.tryParse('${p['run_time_hour']}'),
            items: [for (final h in hours) DropdownMenuItem(value: h.$1, child: Text(h.$2))],
            onChanged: (v) => setState(() => p['run_time_hour'] = v),
          ),
          fieldWidth: 220,
        ),
      if (p['run_time_frequency'] == 'daily')
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (var i = 0; i < 7; i++)
            FilterChip(
              label: Text(weekDays[i]),
              selected: days.contains(i),
              onSelected: (on) => setState(() => on ? days.add(i) : days.remove(i)),
            ),
        ]),
      const Divider(),
      _row(
        tr('Reboot after installation'),
        sel('reboot_after_install', [
          ('never', tr('Never')),
          ('required', tr('When required')),
          ('always', tr('Always')),
          ('inherit', tr('Inherit')),
        ]),
        fieldWidth: 220,
      ),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: p['reprocess_failed_inherit'] == true,
        onChanged: (v) => setState(() => p['reprocess_failed_inherit'] = v ?? false),
        title: Text(tr('Inherit failed patch options')),
      ),
      if (p['reprocess_failed_inherit'] != true)
        Row(children: [
          Expanded(
            child: CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: p['reprocess_failed'] == true,
              onChanged: (v) => setState(() => p['reprocess_failed'] = v ?? false),
              title: Text(tr('Reprocess failed patches')),
            ),
          ),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _reprocessTimes,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Times')),
            ),
          ),
        ]),
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: p['email_if_fail'] == true,
        onChanged: (v) => setState(() => p['email_if_fail'] = v ?? false),
        title: Text(tr('Send an email when patch installation fails')),
      ),
    ]);
  }

  // ---------------------------------------------------------------- policies (read only)
  Widget _policies() {
    final a = _agent!;
    final applied = (a['applied_policies'] as Map?) ?? {};
    final template = a['alert_template'] as Map?;
    final eff = (a['effective_patch_policy'] as Map?) ?? {};
    String sev(dynamic v) => switch ('$v') {
          'manual' => tr('Manual'),
          'approve' => tr('Approve'),
          'ignore' => tr('Ignore'),
          _ => tr('Do nothing'),
        };
    Widget line(String k, String v, {bool off = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 220, child: Text(k, style: TextStyle(color: Theme.of(context).hintColor))),
            Expanded(child: Text(v, style: off ? const TextStyle(color: Colors.orange) : null)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Policies'), style: const TextStyle(fontWeight: FontWeight.bold)),
      for (final e in applied.entries)
        line(
          tr('policy_${e.key}'),
          e.value == null
              ? tr('None')
              : '${e.value['name']}${e.value['active'] == false ? ' (${tr('disabled')})' : ''}',
          off: e.value != null && e.value['active'] == false,
        ),
      const Divider(),
      Text(tr('Alert template'), style: const TextStyle(fontWeight: FontWeight.bold)),
      line(
        tr('Alert template'),
        template == null
            ? tr('None')
            : '${template['name']}${template['is_active'] == false ? ' (${tr('disabled')})' : ''}',
      ),
      const Divider(),
      Text(tr('Effective patch policy'), style: const TextStyle(fontWeight: FontWeight.bold)),
      line(tr('Critical'), sev(eff['critical'])),
      line(tr('Important'), sev(eff['important'])),
      line(tr('Moderate'), sev(eff['moderate'])),
      line(tr('Low'), sev(eff['low'])),
      line(tr('Other'), sev(eff['other'])),
      line(tr('Frequency'), '${eff['run_time_frequency'] ?? ''}  ${eff['run_time_hour'] ?? ''}:00'),
      line(tr('Reboot after installation'), '${eff['reboot_after_install'] ?? ''}'),
    ]);
  }
}
