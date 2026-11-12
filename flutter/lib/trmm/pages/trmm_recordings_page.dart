// Session recordings (Tactical RMM recordings app): list + play.
// Videos of TRMM Desktop (.webm) open in the browser with the temporary link
// of the bucket; MeshCentral recordings (.mcrec) open in the player page of the
// web dashboard (public/mcrec-player), which needs the dashboard URL of the
// server profile.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';

class TrmmRecordingsDialog extends StatefulWidget {
  final String? agentId;
  final String? hostname;
  const TrmmRecordingsDialog({super.key, this.agentId, this.hostname});

  @override
  State<TrmmRecordingsDialog> createState() => _TrmmRecordingsDialogState();
}

class _TrmmRecordingsDialogState extends State<TrmmRecordingsDialog> {
  static const _pageSize = 50;
  final _search = TextEditingController();
  String _source = '';
  int _page = 1;
  int _total = 0;
  bool _loading = false;
  int? _playing;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await TrmmSession.to.api.recordings(
        page: _page,
        pageSize: _pageSize,
        agentId: widget.agentId,
        source: _source,
        search: _search.text.trim(),
      );
      _rows = [for (final x in (r['results'] as List? ?? [])) Map<String, dynamic>.from(x as Map)];
      _total = (r['total'] as num?)?.toInt() ?? 0;
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(Map<String, dynamic> row) async {
    final id = (row['id'] as num).toInt();
    setState(() => _playing = id);
    try {
      final link = await TrmmSession.to.api.recordingPlayLink(id);
      final url = link['url'] as String? ?? '';
      Uri target;
      if (link['kind'] == 'video') {
        target = Uri.parse(url);
      } else {
        final web = (TrmmSession.to.server?.webUrl ?? '').replaceAll(RegExp(r'/+$'), '');
        if (web.isEmpty) {
          if (mounted) {
            trmmSnack(context, tr('Set the dashboard URL in the server profile to play MeshCentral recordings'),
                error: true);
          }
          return;
        }
        // the link goes in the fragment: never sent to the dashboard server
        final params = Uri(queryParameters: {'src': url, 'name': link['filename'] as String? ?? 'recording.mcrec'})
            .query;
        target = Uri.parse('$web/mcrec-player/index.html#$params');
      }
      await launchUrl(target, mode: LaunchMode.externalApplication);
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _playing = null);
    }
  }

  String _duration(num? seconds) {
    final s = (seconds ?? 0).toInt();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(s ~/ 3600)}:${two((s % 3600) ~/ 60)}:${two(s % 60)}';
  }

  String _size(num? bytes) {
    final b = (bytes ?? 0).toDouble();
    if (b >= 1024 * 1024 * 1024) return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024).ceil()} KB';
  }

  String _date(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  String _sourceLabel(String? v) => switch (v) {
        'mesh' => 'MeshCentral',
        'rustdesk' => 'TRMM Desktop',
        'qs_rustdesk' => tr('Quick Support'),
        _ => v ?? '',
      };

  (String, Color) _status(String? v) => switch (v) {
        'uploaded' => (tr('Stored'), Colors.green),
        'pending' => (tr('Waiting upload'), Colors.orange),
        'receiving' => (tr('Receiving'), Colors.blue),
        _ => (tr('Error'), Colors.red),
      };

  @override
  Widget build(BuildContext context) {
    final pages = (_total / _pageSize).ceil().clamp(1, 1 << 30);
    final title = widget.hostname == null
        ? tr('Session Recordings')
        : '${tr('Session Recordings')} - ${widget.hostname}';
    return Dialog(
      child: SizedBox(
        width: 1100,
        height: 640,
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: Text(title),
            trailing: IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: tr('Search hostname or technician'),
                  ),
                  onSubmitted: (_) {
                    _page = 1;
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 16),
              DropdownButton<String>(
                value: _source,
                items: [
                  DropdownMenuItem(value: '', child: Text(tr('All sources'))),
                  for (final v in ['mesh', 'rustdesk', 'qs_rustdesk'])
                    DropdownMenuItem(value: v, child: Text(_sourceLabel(v))),
                ],
                onChanged: (v) {
                  _source = v ?? '';
                  _page = 1;
                  _load();
                },
              ),
              const Spacer(),
              IconButton(tooltip: tr('Refresh'), onPressed: _load, icon: const Icon(Icons.refresh)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text(tr('No recordings')))
                    : SingleChildScrollView(
                        child: SizedBox(
                          width: double.infinity,
                          child: DataTable(
                            headingRowHeight: 36,
                            dataRowMinHeight: 32,
                            dataRowMaxHeight: 40,
                            columnSpacing: 18,
                            columns: [
                              DataColumn(label: Text(tr('Started'))),
                              DataColumn(label: Text(tr('Duration'))),
                              DataColumn(label: Text(tr('Hostname'))),
                              DataColumn(label: Text(tr('Client / Site'))),
                              DataColumn(label: Text(tr('Technician'))),
                              DataColumn(label: Text(tr('Source'))),
                              DataColumn(label: Text(tr('Size')), numeric: true),
                              DataColumn(label: Text(tr('Status'))),
                              const DataColumn(label: SizedBox.shrink()),
                            ],
                            rows: [
                              for (final r in _rows)
                                DataRow(cells: [
                                  DataCell(Text(_date(r['started'] as String?))),
                                  DataCell(Text(_duration(r['duration'] as num?))),
                                  DataCell(Text('${r['hostname'] ?? ''}')),
                                  DataCell(Text(r['client_name'] == null
                                      ? '-'
                                      : '${r['client_name']} / ${r['site_name'] ?? '-'}')),
                                  DataCell(Text('${r['technician_name'] ?? ''}')),
                                  DataCell(Text(_sourceLabel(r['source'] as String?))),
                                  DataCell(Text(_size(r['size'] as num?))),
                                  DataCell(Builder(builder: (_) {
                                    final (label, color) = _status(r['status'] as String?);
                                    final err = '${r['last_error'] ?? ''}';
                                    final chip = Text(label, style: TextStyle(color: color));
                                    return err.isEmpty ? chip : Tooltip(message: err, child: chip);
                                  })),
                                  DataCell(_playing == (r['id'] as num).toInt()
                                      ? const SizedBox(
                                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                      : IconButton(
                                          tooltip: tr('Play'),
                                          icon: const Icon(Icons.play_circle_outline),
                                          onPressed: r['status'] == 'uploaded' ? () => _play(r) : null,
                                        )),
                                ]),
                            ],
                          ),
                        ),
                      ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: [
              Text('  ${tr('{0} recording(s)', [_total])}'),
              const Spacer(),
              IconButton(
                onPressed: _page > 1
                    ? () {
                        _page--;
                        _load();
                      }
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('$_page / $pages'),
              IconButton(
                onPressed: _page < pages
                    ? () {
                        _page++;
                        _load();
                      }
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
