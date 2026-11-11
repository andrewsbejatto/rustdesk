// Clients and sites: add / edit / delete (same api and fields as the web
// panel: clients/views.py, ClientsForm.vue, SitesForm.vue, DeleteClient.vue).

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';

// ---------------------------------------------------------------- custom fields
/// values keyed by field name, like the web form
class TrmmCustomFields {
  List<Map<String, dynamic>> defs = [];
  final Map<String, dynamic> values = {};

  Future<void> load(String model, List<dynamic>? current) async {
    final r = await TrmmSession.to.api.client.get('/core/customfields/', query: {'model': model});
    defs = [
      for (final f in (r as List))
        if (f['hide_in_ui'] != true) Map<String, dynamic>.from(f)
    ];
    for (final f in defs) {
      final v = current?.firstWhere((x) => x['field'] == f['id'], orElse: () => null);
      switch (f['type']) {
        case 'multiple':
          values[f['name']] = v != null ? List<String>.from(v['value'] ?? []) : <String>[];
        case 'checkbox':
          values[f['name']] = v != null ? v['value'] == true : false;
        default:
          values[f['name']] = v != null ? '${v['value'] ?? ''}' : '';
      }
    }
  }

  /// web utils/format.ts formatCustomFields
  List<Map<String, dynamic>> payload() => [
        for (final f in defs)
          switch (f['type']) {
            'multiple' => {'multiple_value': values[f['name']], 'field': f['id']},
            'checkbox' => {'bool_value': values[f['name']], 'field': f['id']},
            _ => {'string_value': values[f['name']], 'field': f['id']},
          }
      ];

  String? missingRequired() {
    for (final f in defs) {
      if (f['required'] != true) continue;
      final v = values[f['name']];
      if (v == null || (v is String && v.trim().isEmpty) || (v is List && v.isEmpty)) {
        return tr('{0} is required', [f['name']]);
      }
    }
    return null;
  }

  List<Widget> widgets(void Function(VoidCallback) setState) => [
        for (final f in defs) ...[
          const SizedBox(height: 14),
          _field(f, setState),
        ]
      ];

  Widget _field(Map<String, dynamic> f, void Function(VoidCallback) setState) {
    final name = '${f['name']}';
    final label = f['required'] == true ? '$name *' : name;
    final options = [for (final o in (f['options'] as List? ?? [])) '$o'];
    switch (f['type']) {
      case 'checkbox':
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: values[name] == true,
          onChanged: (v) => setState(() => values[name] = v ?? false),
          title: Text(name),
        );
      case 'single':
        final current = values[name] as String;
        return DropdownButtonFormField<String>(
          value: options.contains(current) ? current : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [for (final o in options) DropdownMenuItem(value: o, child: Text(o))],
          onChanged: (v) => setState(() => values[name] = v ?? ''),
        );
      case 'multiple':
        final selected = values[name] as List<String>;
        return InputDecorator(
          decoration: InputDecoration(labelText: label),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final o in options)
              FilterChip(
                label: Text(o),
                selected: selected.contains(o),
                onSelected: (on) => setState(() => on ? selected.add(o) : selected.remove(o)),
              ),
          ]),
        );
      default: // text, number, datetime
        return TextFormField(
          initialValue: '${values[name] ?? ''}',
          keyboardType: f['type'] == 'number' ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(
            labelText: label,
            hintText: f['type'] == 'datetime' ? 'YYYY-MM-DD HH:MM' : null,
          ),
          onChanged: (v) => values[name] = v,
        );
    }
  }
}

// ---------------------------------------------------------------- client form
/// add (client == null) or edit a client
class ClientFormDialog extends StatefulWidget {
  final Map<String, dynamic>? client;
  const ClientFormDialog({super.key, this.client});

  @override
  State<ClientFormDialog> createState() => _ClientFormDialogState();
}

class _ClientFormDialogState extends State<ClientFormDialog> {
  late final _name = TextEditingController(text: '${widget.client?['name'] ?? ''}');
  final _site = TextEditingController();
  final _cf = TrmmCustomFields();
  bool _loading = true;
  bool _busy = false;

  bool get _edit => widget.client != null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      List<dynamic>? current;
      if (_edit) {
        final c = await TrmmSession.to.api.client.get('/clients/${widget.client!['id']}/');
        current = (c as Map)['custom_fields'] as List?;
      }
      await _cf.load('client', current);
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || (!_edit && _site.text.trim().isEmpty)) {
      trmmSnack(context, tr('Required'), error: true);
      return;
    }
    final missing = _cf.missingRequired();
    if (missing != null) {
      trmmSnack(context, missing, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final api = TrmmSession.to.api.client;
      final dynamic r;
      if (_edit) {
        r = await api.put('/clients/${widget.client!['id']}/', {
          'client': {'name': _name.text.trim()},
          'custom_fields': _cf.payload(),
        });
      } else {
        r = await api.post('/clients/', {
          'client': {'name': _name.text.trim()},
          'site': {'name': _site.text.trim()},
          'custom_fields': _cf.payload(),
        });
      }
      if (mounted) {
        Navigator.pop(context, true);
        trmmSnack(context, '$r');
      }
    } on TrmmApiException catch (e) {
      if (mounted) {
        trmmSnack(context, e.message, error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_edit ? tr('Edit client') : tr('Add client')),
        content: SizedBox(
          width: 440,
          child: _loading
              ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
              : SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                            controller: _name,
                            autofocus: true,
                            decoration: InputDecoration(labelText: tr('Name'))),
                        if (!_edit) ...[
                          const SizedBox(height: 14),
                          TextField(
                              controller: _site,
                              decoration: InputDecoration(labelText: tr('Default first site'))),
                        ],
                        ..._cf.widgets(setState),
                      ]),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: _busy || _loading ? null : _save, child: Text(tr('Save'))),
        ],
      );
}

// ---------------------------------------------------------------- site form
/// add (site == null) or edit a site
class SiteFormDialog extends StatefulWidget {
  final List<Map<String, dynamic>> clients;
  final Map<String, dynamic>? site;
  final int? clientId;
  const SiteFormDialog({super.key, required this.clients, this.site, this.clientId});

  @override
  State<SiteFormDialog> createState() => _SiteFormDialogState();
}

class _SiteFormDialogState extends State<SiteFormDialog> {
  late final _name = TextEditingController(text: '${widget.site?['name'] ?? ''}');
  late int? _client = (widget.site?['client'] as int?) ??
      widget.clientId ??
      (widget.clients.isEmpty ? null : widget.clients.first['id'] as int);
  final _cf = TrmmCustomFields();
  bool _loading = true;
  bool _busy = false;

  bool get _edit => widget.site != null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      List<dynamic>? current;
      if (_edit) {
        final s = await TrmmSession.to.api.client.get('/clients/sites/${widget.site!['id']}/');
        current = (s as Map)['custom_fields'] as List?;
      }
      await _cf.load('site', current);
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _client == null) {
      trmmSnack(context, tr('Required'), error: true);
      return;
    }
    final missing = _cf.missingRequired();
    if (missing != null) {
      trmmSnack(context, missing, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final api = TrmmSession.to.api.client;
      final body = {
        'site': {'client': _client, 'name': _name.text.trim()},
        'custom_fields': _cf.payload(),
      };
      final r = _edit
          ? await api.put('/clients/sites/${widget.site!['id']}/', body)
          : await api.post('/clients/sites/', body);
      if (mounted) {
        Navigator.pop(context, true);
        trmmSnack(context, '$r');
      }
    } on TrmmApiException catch (e) {
      if (mounted) {
        trmmSnack(context, e.message, error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_edit ? tr('Edit site') : tr('Add site')),
        content: SizedBox(
          width: 440,
          child: _loading
              ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
              : SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<int>(
                          value: _client,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: tr('Client')),
                          items: [
                            for (final c in widget.clients)
                              DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}'))
                          ],
                          onChanged: (v) => setState(() => _client = v),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                            controller: _name,
                            autofocus: true,
                            decoration: InputDecoration(labelText: tr('Name'))),
                        ..._cf.widgets(setState),
                      ]),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: _busy || _loading ? null : _save, child: Text(tr('Save'))),
        ],
      );
}

// ---------------------------------------------------------------- delete
/// Deletes a client (site == null) or a site. When it has agents, they must be
/// moved to another site first (same as the web panel).
class DeleteClientSiteDialog extends StatefulWidget {
  final List<Map<String, dynamic>> clients;
  final Map<String, dynamic> client;
  final Map<String, dynamic>? site;
  const DeleteClientSiteDialog({super.key, required this.clients, required this.client, this.site});

  @override
  State<DeleteClientSiteDialog> createState() => _DeleteClientSiteDialogState();
}

class _DeleteClientSiteDialogState extends State<DeleteClientSiteDialog> {
  int? _moveTo;
  bool _busy = false;

  bool get _isSite => widget.site != null;
  String get _name => '${(_isSite ? widget.site : widget.client)!['name']}';
  int get _agents => ((_isSite ? widget.site : widget.client)!['agent_count'] as num?)?.toInt() ?? 0;

  /// destination sites: any site outside what is being deleted
  List<(int, String)> get _targets => [
        for (final c in widget.clients)
          for (final s in (c['sites'] as List? ?? []))
            if (_isSite ? s['id'] != widget.site!['id'] : c['id'] != widget.client['id'])
              (s['id'] as int, '${c['name']} / ${s['name']}')
      ];

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      final path = _isSite ? '/clients/sites/${widget.site!['id']}/' : '/clients/${widget.client['id']}/';
      final r = await TrmmSession.to.api.client
          .delete(path, query: {if (_agents > 0 && _moveTo != null) 'move_to_site': _moveTo});
      if (mounted) {
        Navigator.pop(context, true);
        trmmSnack(context, '$r');
      }
    } on TrmmApiException catch (e) {
      if (mounted) {
        trmmSnack(context, e.message, error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets;
    return AlertDialog(
      title: Text(_isSite ? tr('Delete site') : tr('Delete client')),
      content: SizedBox(
        width: 440,
        child:
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Delete {0}?', [_name])),
          if (_agents > 0) ...[
            const SizedBox(height: 12),
            Text(tr('{0} agent(s) will be moved to:', [_agents])),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: _moveTo,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Site')),
              items: [for (final t in targets) DropdownMenuItem(value: t.$1, child: Text(t.$2))],
              onChanged: (v) => setState(() => _moveTo = v),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          onPressed: _busy || (_agents > 0 && _moveTo == null) ? null : _delete,
          child: Text(tr('Delete')),
        ),
      ],
    );
  }
}
