// Context menu of an agent (right click on the table or the "Actions" button).

import 'package:flutter/material.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_remote.dart';
import '../trmm_layout.dart';
import '../trmm_session.dart';
import 'trmm_dashboard_page.dart';
import 'trmm_remote_background_page.dart';
import 'trmm_edit_agent_dialog.dart';
import 'trmm_file_browser.dart';
import 'trmm_recordings_page.dart';
import 'trmm_run_script_dialog.dart';

Future<void> showAgentMenu(BuildContext context, TrmmRow row, Offset position,
    {required VoidCallback onChanged}) async {
  final s = TrmmSession.to;
  final rect = RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy);
  PopupMenuItem<String> item(String v, IconData icon, String label) => PopupMenuItem(
        value: v,
        height: 36,
        child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)]),
      );

  final a = row.agent;
  final items = <PopupMenuEntry<String>>[
    if (s.canUseRemoteAccess) ...[
      item('control', Icons.desktop_windows, tr('Take Control')),
      item('files', Icons.folder_copy_outlined, tr('File Transfer')),
    ],
    if (a != null) ...[
      item('mesh', Icons.open_in_new, tr('Take Control (MeshCentral)')),
      item('trmm_files', Icons.drive_file_move_outline, tr('File Transfer (Tactical RMM)')),
      item('background', Icons.terminal, tr('Remote Background')),
      const PopupMenuDivider(),
      item('cmd', Icons.keyboard_command_key, tr('Send Command')),
      item('script', Icons.play_arrow_outlined, tr('Run Script')),
      item('edit', Icons.edit_outlined, tr('Edit {0}', [a['hostname'] ?? ''])),
      item('ping', Icons.network_ping, tr('Ping')),
      item('wmi', Icons.sync, tr('Refresh WMI')),
      if (a['maintenance_mode'] == true)
        item('maint_off', Icons.construction, tr('Disable Maintenance Mode'))
      else
        item('maint_on', Icons.construction, tr('Enable Maintenance Mode')),
      item('wol', Icons.power, tr('Wake On LAN')),
      item('reboot', Icons.restart_alt, tr('Reboot')),
      item('shutdown', Icons.power_settings_new, tr('Shutdown')),
      item('recover_mesh', Icons.healing, tr('Recover connection (MeshCentral)')),
      item('recover_agent', Icons.healing, tr('Recover connection (Tactical agent)')),
      item('uninstall', Icons.delete_outline, tr('Remove agent')),
      if (s.canViewRecordings) item('recordings', Icons.video_library_outlined, tr('Session Recordings')),
      if (s.canUseRemoteAccess) ...[
        const PopupMenuDivider(),
        item('ra_install', Icons.download_for_offline_outlined, tr('Repair remote access')),
        item('ra_password', Icons.password, tr('Change remote access password')),
      ],
    ],
    if (a == null && s.canUseRemoteAccess) ...[
      const PopupMenuDivider(),
      item('device_delete', Icons.delete_outline, tr('Remove from the list')),
    ],
  ];
  if (items.isEmpty) return;
  final v = await showMenu<String>(
      context: context,
      position: rect,
      items: items,
      constraints: const BoxConstraints(minWidth: 340, maxWidth: 460));
  if (v == null || !context.mounted) return;
  await _run(context, row, v, onChanged);
}

Future<void> _run(BuildContext context, TrmmRow row, String action, VoidCallback onChanged) async {
  final api = TrmmSession.to.api;
  final id = row.agent?['agent_id'] as String?;
  Future<void> guard(Future<void> Function() f) async {
    try {
      await f();
    } on TrmmApiException catch (e) {
      if (context.mounted) trmmSnack(context, e.message, error: true);
    }
  }

  switch (action) {
    case 'control':
    case 'files':
      final ft = action == 'files';
      if (id != null) {
        await takeControlAgent(context, id, fileTransfer: ft);
      } else {
        await takeControlDevice(context, row.device!['id'] as int, fileTransfer: ft);
      }
    case 'mesh':
      await openMesh(context, id!, 'control');
    case 'recordings':
      await showDialog(
          context: context, builder: (_) => TrmmRecordingsDialog(agentId: id, hostname: row.hostname));
    case 'trmm_files':
      await openTrmmFileBrowser(context, row.agent!);
    case 'background':
      await showRemoteBackground(context, row.agent!);
    case 'cmd':
      await showDialog(context: context, builder: (_) => SendCommandDialog(row: row));
    case 'script':
      await showDialog(context: context, builder: (_) => RunScriptDialog(agent: row.agent!));
    case 'edit':
      final ok = await showDialog<bool>(context: context, builder: (_) => EditAgentDialog(agentId: id!));
      if (ok == true) onChanged();
    case 'description':
      final c = TextEditingController(text: row.description);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Edit description')),
          content: SizedBox(width: 400, child: TextField(controller: c, autofocus: true)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save'))),
          ],
        ),
      );
      if (ok == true) {
        await guard(() async {
          await api.editAgent(id!, {'description': c.text.trim()});
          onChanged();
        });
      }
    case 'recover_mesh':
    case 'recover_agent':
      await guard(() async {
        final r = await api.recover(id!, action == 'recover_mesh' ? 'mesh' : 'tacagent');
        if (context.mounted) trmmSnack(context, '$r');
      });
    case 'uninstall':
      if (!await trmmConfirm(context,
          tr('Remove the agent from {0}? It will be uninstalled from the computer.', [row.hostname]))) {
        return;
      }
      await guard(() async {
        final r = await api.uninstall(id!);
        if (context.mounted) trmmSnack(context, '$r');
        onChanged();
      });
    case 'device_delete':
      if (!await trmmConfirm(context, '${tr('Remove from the list')}: ${row.hostname}?')) return;
      await guard(() async {
        await api.client.delete('/remoteaccess/devices/${row.device!['id']}/');
        onChanged();
      });
    case 'ping':
      await guard(() async {
        final r = await api.ping(id!);
        if (context.mounted) trmmSnack(context, '${r['name']}: ${r['status']}');
      });
    case 'wmi':
      await guard(() async {
        await api.refreshWmi(id!);
        if (context.mounted) trmmSnack(context, tr('Done'));
      });
    case 'maint_on':
    case 'maint_off':
      await guard(() async {
        await api.setMaintenance(id!, action == 'maint_on');
        onChanged();
      });
    case 'wol':
      await guard(() async {
        final r = await api.wakeOnLan(id!);
        if (context.mounted) trmmSnack(context, '$r');
      });
    case 'reboot':
    case 'shutdown':
      final label = action == 'reboot' ? tr('Reboot') : tr('Shutdown');
      if (!await trmmConfirm(context, '$label ${row.hostname}?', title: label)) return;
      await guard(() async {
        final r = action == 'reboot' ? await api.reboot(id!) : await api.shutdown(id!);
        if (context.mounted) trmmSnack(context, '$r');
      });
    case 'ra_install':
      await guard(() async {
        await api.provisionRemoteAccess(id!);
        if (!context.mounted) return;
        if (await waitProvision(context, id) && context.mounted) {
          trmmSnack(context, tr('Remote access installed'));
        }
        onChanged();
      });
    case 'ra_password':
      if (!await trmmConfirm(context, '${tr('Change remote access password')}: ${row.hostname}?')) {
        return;
      }
      await guard(() async {
        await api.changeRemotePassword(id!);
        if (!context.mounted) return;
        if (await waitProvision(context, id) && context.mounted) {
          trmmSnack(context, tr('Password changed'));
        }
      });
  }
}

class SendCommandDialog extends StatefulWidget {
  final TrmmRow row;
  const SendCommandDialog({super.key, required this.row});

  @override
  State<SendCommandDialog> createState() => _SendCommandDialogState();
}

class _SendCommandDialogState extends State<SendCommandDialog> {
  final _cmd = TextEditingController();
  late String _shell;
  int _timeout = 30;
  bool _asUser = false;
  bool _busy = false;
  String _output = '';

  bool get _windows => widget.row.agent?['plat'] == 'windows';

  @override
  void initState() {
    super.initState();
    _shell = _windows ? 'cmd' : '/bin/bash';
  }

  @override
  void dispose() {
    _cmd.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_cmd.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _output = '';
    });
    try {
      final r = await TrmmSession.to.api.sendCommand(widget.row.agent!['agent_id'] as String,
          cmd: _cmd.text, shell: _shell, timeout: _timeout, runAsUser: _asUser);
      _output = '$r';
    } on TrmmApiException catch (e) {
      _output = e.message;
      if (e.forbidden && mounted) showTrmmForbidden(context, e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final shells = _windows ? ['cmd', 'powershell'] : ['/bin/bash', '/bin/sh'];
    return AlertDialog(
      title: Text('${trmmAgentTitle(widget.row.agent!)} (${tr('Send Command')})'),
      insetPadding: const EdgeInsets.all(16),
      content: SizedBox(
        width: trmmDialogSize(context, 720, 420).width,
        height: trmmDialogSize(context, 720, 560).height - 140,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            TrmmRadioGroup<String>(
              options: [for (final sh in shells) (sh, sh)],
              value: _shell,
              onChanged: (sh) => setState(() => _shell = sh),
            ),
            const Spacer(),
            SizedBox(
              width: 90,
              child: TextFormField(
                initialValue: '$_timeout',
                decoration: const InputDecoration(labelText: 'Timeout (s)', isDense: true),
                keyboardType: TextInputType.number,
                onChanged: (v) => _timeout = int.tryParse(v) ?? 30,
              ),
            ),
            if (_windows) ...[
              Checkbox(value: _asUser, onChanged: (v) => setState(() => _asUser = v ?? false)),
              Text(tr('Run as user')),
            ],
          ]),
          const SizedBox(height: 14),
          TextField(
            controller: _cmd,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black,
              child: SingleChildScrollView(
                child: SelectableText(_output,
                    style: const TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 12)),
              ),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
        FilledButton(
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr('Send Command')),
        ),
      ],
    );
  }
}
