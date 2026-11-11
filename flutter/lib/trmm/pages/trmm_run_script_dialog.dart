// Run Script on an agent (same options as the web panel: wait for the output
// or run in the background).

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_layout.dart';
import '../trmm_session.dart';
import '../trmm_remote.dart';

class RunScriptDialog extends StatefulWidget {
  final Map<String, dynamic> agent;
  const RunScriptDialog({super.key, required this.agent});

  @override
  State<RunScriptDialog> createState() => _RunScriptDialogState();
}

class _RunScriptDialogState extends State<RunScriptDialog> {
  List<Map<String, dynamic>> _scripts = [];
  Map<String, dynamic>? _script;
  String _filter = '';
  final _args = TextEditingController();
  final _env = TextEditingController();
  int _timeout = 90;
  bool _asUser = false;
  bool _wait = true;
  bool _busy = false;
  String? _output;
  String? _error;

  String get _plat => (widget.agent['plat'] as String?) ?? 'windows';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _args.dispose();
    _env.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final show = TrmmSession.to.dashInfo['show_community_scripts'] != false;
      final r = await TrmmSession.to.api.scripts(community: show);
      _scripts = [
        for (final s in r)
          if (s['hidden'] != true && _supports(s)) Map<String, dynamic>.from(s)
      ]..sort((a, b) {
          final fa = a['favorite'] == true ? 0 : 1, fb = b['favorite'] == true ? 0 : 1;
          if (fa != fb) return fa - fb;
          return '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase());
        });
    } on TrmmApiException catch (e) {
      _error = e.message;
    }
    if (mounted) setState(() {});
  }

  bool _supports(dynamic s) {
    final p = s['supported_platforms'] as List?;
    return p == null || p.isEmpty || p.contains(_plat);
  }

  void _select(Map<String, dynamic> s) {
    setState(() {
      _script = s;
      _args.text = ((s['args'] as List?) ?? []).join('\n');
      _env.text = ((s['env_vars'] as List?) ?? []).join('\n');
      _timeout = (s['default_timeout'] as num?)?.toInt() ?? 90;
      _asUser = s['run_as_user'] == true;
      _output = null;
    });
  }

  List<String> _lines(TextEditingController c) =>
      c.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  Future<void> _run() async {
    final s = _script;
    if (s == null) return;
    setState(() {
      _busy = true;
      _output = null;
    });
    try {
      final r = await TrmmSession.to.api.runScript(widget.agent['agent_id'] as String, {
        'script': s['id'],
        'output': _wait ? 'wait' : 'forget',
        'args': _lines(_args),
        'env_vars': _lines(_env),
        'timeout': _timeout,
        'run_as_user': _asUser,
      });
      _output = r is String ? r : '$r';
    } on TrmmApiException catch (e) {
      _output = e.message;
      if (e.forbidden && mounted) showTrmmForbidden(context, e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final list = _scripts
        .where((s) => _filter.isEmpty ||
            '${s['name']} ${s['category'] ?? ''} ${s['description'] ?? ''}'.toLowerCase().contains(_filter))
        .toList();
    return AlertDialog(
      title: Text('${trmmAgentTitle(widget.agent)} (${tr('Run Script')})'),
      insetPadding: const EdgeInsets.all(16),
      content: SizedBox(
        width: trmmDialogSize(context, 900, 520).width,
        height: trmmDialogSize(context, 900, 620).height - 160,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: trmmDialogSize(context, 900, 520).width < 760 ? 220 : 320,
            child: Column(children: [
              TextField(
                decoration: InputDecoration(
                    isDense: true, prefixIcon: const Icon(Icons.search, size: 18), hintText: tr('Search')),
                onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
              ),
              Expanded(
                child: _error != null
                    ? trmmErrorView(context, _error!, colored: false)
                    : ListView(children: [
                        for (final s in list)
                          ListTile(
                            dense: true,
                            selected: _script?['id'] == s['id'],
                            leading: Icon(s['favorite'] == true ? Icons.star : Icons.description_outlined,
                                size: 18, color: s['favorite'] == true ? Colors.amber : null),
                            title: Text('${s['name']}', overflow: TextOverflow.ellipsis),
                            subtitle: Text('${s['category'] ?? ''}  ${s['shell'] ?? ''}',
                                overflow: TextOverflow.ellipsis),
                            onTap: () => _select(s),
                          ),
                      ]),
              ),
            ]),
          ),
          const VerticalDivider(),
          Expanded(
            child: _script == null
                ? Center(child: Text(tr('Select a script')))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('${_script!['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _args,
                          minLines: 2,
                          maxLines: 3,
                          decoration: InputDecoration(labelText: tr('Arguments (one per line)'), isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _env,
                          minLines: 2,
                          maxLines: 3,
                          decoration: InputDecoration(
                              labelText: tr('Environment variables (VAR=value)'), isDense: true),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    // Wrap: the options go to a second line on small screens
                    Wrap(spacing: 4, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      SizedBox(
                        width: 100,
                        child: TextFormField(
                          key: ValueKey('t${_script!['id']}'),
                          initialValue: '$_timeout',
                          decoration: const InputDecoration(labelText: 'Timeout (s)', isDense: true),
                          onChanged: (v) => _timeout = int.tryParse(v) ?? 90,
                        ),
                      ),
                      if (_plat == 'windows')
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Checkbox(value: _asUser, onChanged: (v) => setState(() => _asUser = v ?? false)),
                          Text(tr('Run as user')),
                        ]),
                      const SizedBox(width: 12),
                      TrmmRadioGroup<bool>(
                        options: [(true, tr('Wait for output')), (false, tr('Run in background'))],
                        value: _wait,
                        onChanged: (v) => setState(() => _wait = v),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        color: Colors.black,
                        padding: const EdgeInsets.all(8),
                        child: _busy
                            ? const Center(child: CircularProgressIndicator())
                            : SingleChildScrollView(
                                child: SelectableText(_output ?? '',
                                    style: const TextStyle(
                                        fontFamily: 'monospace', color: Colors.white, fontSize: 12)),
                              ),
                      ),
                    ),
                  ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
        FilledButton(
            onPressed: _busy || _script == null ? null : _run, child: Text(tr('Run Script'))),
      ],
    );
  }
}
