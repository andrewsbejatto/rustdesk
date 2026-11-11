// "Install agent" with remote access: downloads the combined installer
// (POST /remoteaccess/installer/). It runs the Tactical RMM installer and,
// whatever the result, installs the TRMM Desktop host and registers it, so
// the computer is reachable even when the agent / MeshCentral fails.


import 'package:flutter/material.dart';

import '../trmm_i18n.dart';
import '../trmm_session.dart';
import '../trmm_layout.dart';
import 'trmm_quick_support_page.dart' show trmmDownload;

class InstallAgentDialog extends StatefulWidget {
  final List<Map<String, dynamic>> clients;
  final int? clientId;
  final int? siteId;
  const InstallAgentDialog({super.key, required this.clients, this.clientId, this.siteId});

  @override
  State<InstallAgentDialog> createState() => _InstallAgentDialogState();
}

class _InstallAgentDialogState extends State<InstallAgentDialog> {
  int? _client;
  int? _site;
  String _plat = 'windows';
  String _type = 'workstation';
  String _arch = 'amd64';
  int _expires = 24;
  bool _power = false;
  bool _rdp = false;
  bool _ping = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _client = widget.clientId ?? (widget.clients.isEmpty ? null : widget.clients.first['id'] as int);
    _site = widget.siteId ?? _firstSite();
  }

  List<dynamic> get _sites =>
      (widget.clients.firstWhere((c) => c['id'] == _client, orElse: () => {})['sites'] as List?) ?? [];

  int? _firstSite() => _sites.isEmpty ? null : _sites.first['id'] as int;

  Future<void> _download() async {
    if (_site == null) return;
    setState(() => _busy = true);
    final saved = await trmmDownload(
        context, '/remoteaccess/installer/', _plat == 'linux' ? 'trmm-install-remoteaccess.sh' : 'trmm-install-remoteaccess.ps1',
        method: 'POST',
        body: {
          'site': _site,
          'plat': _plat,
          'api': TrmmSession.to.server?.apiUrl,
          'agenttype': _type,
          'goarch': _arch,
          'expires': _expires,
          // servers never sleep (the server enforces it too)
          'power': _type == 'server' || _power ? 1 : 0,
          'rdp': _rdp ? 1 : 0,
          'ping': _ping ? 1 : 0,
        });
    if (saved != null && mounted) {
      Navigator.pop(context);
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Install agent + remote access')),
      content: SizedBox(
        width: 480,
        child:
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('combined_installer_help'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            value: _client,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Client')),
            items: [
              for (final c in widget.clients)
                DropdownMenuItem(value: c['id'] as int, child: Text('${c['name']}'))
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
              for (final s in _sites) DropdownMenuItem(value: s['id'] as int, child: Text('${s['name']}'))
            ],
            onChanged: (v) => setState(() => _site = v),
          ),
          const SizedBox(height: 16),
          TrmmRadioGroup<String>(
            options: const [('windows', 'Windows'), ('linux', 'Linux')],
            value: _plat,
            onChanged: (v) => setState(() {
              _plat = v;
              if (_arch == '386' && _plat == 'linux' || _arch == 'arm64' && _plat == 'windows') {
                _arch = 'amd64';
              }
            }),
          ),
          const SizedBox(height: 12),
          // same as the web panel: "Disable sleep/hibernate" only for workstations
          TrmmRadioGroup<String>(
            options: [('server', tr('Server')), ('workstation', tr('Workstation'))],
            value: _type,
            onChanged: (v) => setState(() {
              _type = v;
              // server: sleep/hibernate always disabled, the option is hidden
              if (v != 'workstation') _power = false;
            }),
          ),
          const SizedBox(height: 12),
          Text(tr('Architecture'), style: Theme.of(context).textTheme.bodySmall),
          TrmmRadioGroup<String>(
            options: [
              ('amd64', '64 bit'),
              if (_plat == 'windows') ('386', '32 bit'),
              if (_plat == 'linux') ('arm64', 'ARM 64'),
            ],
            value: _arch,
            onChanged: (v) => setState(() => _arch = v),
          ),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 110,
              child: TextFormField(
                initialValue: '$_expires',
                decoration: InputDecoration(labelText: tr('Expires (hours)')),
                keyboardType: TextInputType.number,
                onChanged: (v) => _expires = int.tryParse(v) ?? 24,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          if (_plat == 'windows')
            CheckboxListTile(
                dense: true,
                value: _rdp,
                onChanged: (v) => setState(() => _rdp = v ?? false),
                title: Text(tr('Enable RDP'))),
          if (_plat == 'windows')
            CheckboxListTile(
                dense: true,
                value: _ping,
                onChanged: (v) => setState(() => _ping = v ?? false),
                title: Text(tr('Enable ping'))),
          if (_plat == 'windows' && _type == 'workstation')
            CheckboxListTile(
                dense: true,
                value: _power,
                onChanged: (v) => setState(() => _power = v ?? false),
                title: Text(tr('Disable sleep/hibernate'))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton.icon(
          onPressed: _busy || _site == null ? null : _download,
          icon: const Icon(Icons.download),
          label: Text(
              _plat == 'linux' ? tr('Download installer (bash)') : tr('Download installer (PowerShell)')),
        ),
      ],
    );
  }
}
