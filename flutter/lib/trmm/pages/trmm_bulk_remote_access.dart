// Install / update the TRMM Desktop host on all the computers of the whole
// server, a client or a site (POST /remoteaccess/bulk/provision/). The server
// installs a few computers at a time, so this only queues them.

import 'package:flutter/material.dart';

import '../trmm_i18n.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';

/// [client]/[site] null = all clients
Future<void> showBulkRemoteAccessDialog(BuildContext context,
    {Map<String, dynamic>? client, Map<String, dynamic>? site}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _BulkRemoteAccessDialog(client: client, site: site),
  );
}

class _BulkRemoteAccessDialog extends StatefulWidget {
  final Map<String, dynamic>? client;
  final Map<String, dynamic>? site;
  const _BulkRemoteAccessDialog({this.client, this.site});

  @override
  State<_BulkRemoteAccessDialog> createState() => _BulkRemoteAccessDialogState();
}

class _BulkRemoteAccessDialogState extends State<_BulkRemoteAccessDialog> {
  bool _reinstall = true;
  bool _busy = false;
  Map<String, dynamic>? _result;

  String get _target {
    if (widget.site != null) {
      return tr('Site {0} ({1})', [widget.site!['name'], widget.client?['name'] ?? '']);
    }
    if (widget.client != null) return tr('Client {0}', [widget.client!['name']]);
    return tr('All Clients');
  }

  Map<String, dynamic> get _body => {
        if (widget.site != null)
          'site': widget.site!['id']
        else if (widget.client != null)
          'client': widget.client!['id']
        else
          'all': true,
        'reinstall': _reinstall,
      };

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final r = await TrmmSession.to.api.bulkProvision(_body);
      if (!mounted) return;
      setState(() => _result = Map<String, dynamic>.from(r as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      trmmSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return AlertDialog(
      title: Text(tr('Install / update remote access')),
      content: SizedBox(
        width: 480,
        child: r == null ? _form(theme) : _summary(theme, r),
      ),
      actions: r != null
          ? [FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))]
          : [
              TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context), child: Text(tr('Cancel'))),
              FilledButton(
                onPressed: _busy ? null : _start,
                child: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(tr('Start')),
              ),
            ],
    );
  }

  Widget _form(ThemeData theme) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Computers: {0}', [_target]), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(tr('bulk_ra_help')),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _reinstall,
            onChanged: _busy ? null : (v) => setState(() => _reinstall = v ?? false),
            title: Text(tr('Also update the computers that already have remote access')),
            subtitle: Text(tr('bulk_ra_reinstall_help')),
          ),
        ],
      );

  Widget _summary(ThemeData theme, Map<String, dynamic> r) {
    final started = (r['started'] as num?)?.toInt() ?? 0;
    final offline = (r['offline'] as num?)?.toInt() ?? 0;
    final queued = (r['queued'] as num?)?.toInt() ?? 0;
    final parallel = (r['parallel'] as num?)?.toInt() ?? 3;
    // ~2 minutes per computer, [parallel] at a time
    final minutes = ((started / parallel).ceil() * 2).clamp(0, 100000);
    Widget line(IconData icon, String text, [Color? color]) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ]),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line(Icons.playlist_add_check, tr('{0} computer(s) queued, {1} at a time', [started, parallel]),
            Colors.green),
        if (started > 0) line(Icons.schedule, tr('Estimated time: about {0} minutes', [minutes])),
        if (offline > 0)
          line(Icons.power_off, tr('{0} offline computer(s) skipped: run again when they are on', [offline]),
              Colors.orange),
        if (queued > 0) line(Icons.hourglass_top, tr('{0} computer(s) were already in the queue', [queued])),
        const SizedBox(height: 8),
        Text(tr('bulk_ra_follow'), style: theme.textTheme.bodySmall),
      ],
    );
  }
}
