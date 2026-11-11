// File transfer of Tactical RMM 1.6 (the new native file browser of the web
// panel): browse the agent's folders, download (files or a zip of folders),
// upload (button or drag and drop), new folder, rename, delete, extract zip.
// Agents older than 2.12 or servers set to the legacy browser open the
// MeshCentral file transfer, as the web panel does.

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/trmm_client.dart';
import '../api/trmm_files.dart';
import '../trmm_i18n.dart';
import '../trmm_notice.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';

/// opens the file transfer of [agent] (new browser, or MeshCentral)
Future<void> openTrmmFileBrowser(BuildContext context, Map<String, dynamic> agent) async {
  final id = agent['agent_id'] as String;
  final client = TrmmSession.to.api.client;
  Map<String, dynamic> d;
  try {
    d = await TrmmFiles(client, id, '${agent['plat'] ?? 'windows'}').defaults();
  } on TrmmApiException catch (e) {
    if (!context.mounted) return;
    if (e.forbidden) {
      await showTrmmForbidden(context, e.message);
    } else {
      trmmSnack(context, e.message, error: true);
    }
    return;
  }
  if (!context.mounted) return;
  if (d['file_browser_mode'] != 'new' || d['supports_new_file_browser'] != true) {
    if (d['file_browser_mode'] == 'new') trmmSnack(context, tr('agent_old_file_browser'));
    await openMesh(context, id, 'file');
    return;
  }
  final fs = TrmmFiles(client, id, '${d['plat'] ?? agent['plat'] ?? 'windows'}');
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => TrmmFileBrowserDialog(agent: agent, fs: fs),
  );
}

String _date(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

String fbBytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

/// natural, case insensitive order ("file2" before "file10")
int _natural(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).toList();
  final y = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final p = x[i].group(0)!, q = y[i].group(0)!;
    final np = int.tryParse(p), nq = int.tryParse(q);
    final c = (np != null && nq != null) ? np.compareTo(nq) : p.compareTo(q);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}

class TrmmFileBrowserDialog extends StatefulWidget {
  final Map<String, dynamic> agent;
  final TrmmFiles fs;
  const TrmmFileBrowserDialog({super.key, required this.agent, required this.fs});

  @override
  State<TrmmFileBrowserDialog> createState() => _TrmmFileBrowserDialogState();
}

class _TrmmFileBrowserDialogState extends State<TrmmFileBrowserDialog> {
  TrmmFiles get fs => widget.fs;
  late final TrmmFileTransfers _engine = TrmmFileTransfers(fs);
  final _pathCtl = TextEditingController();
  final _filterCtl = TextEditingController();
  final _focus = FocusNode();

  String _path = '';
  List<FbItem> _items = [];
  bool _loading = false;
  String? _error;
  final _selected = <String>{};
  int? _anchor;
  String _sortBy = 'name';
  bool _asc = true;
  bool _dragging = false;

  final _transfers = <FbTransfer>[];
  final _jobs = <FbTransfer, Future<void> Function()>{};
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    for (final t in _transfers) {
      t.cancel();
    }
    _pathCtl.dispose();
    _filterCtl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ listing
  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (real, items) = await fs.list(path);
      if (!mounted) return;
      setState(() {
        if (real != _path) {
          _selected.clear();
          _anchor = null;
          _filterCtl.clear();
        }
        _path = real;
        _pathCtl.text = real;
        _items = items;
        _selected.retainAll(items.map((e) => e.path));
      });
    } on TrmmApiException catch (e) {
      if (!mounted) return;
      if (e.forbidden) {
        await showTrmmForbidden(context, e.message);
      }
      setState(() {
        _error = fbErrorText(e);
        _pathCtl.text = _path;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (mounted) _focus.requestFocus();
  }

  List<FbItem> get _view {
    final q = _filterCtl.text.trim().toLowerCase();
    final list = [
      for (final i in _items)
        if (q.isEmpty || i.name.toLowerCase().contains(q)) i
    ];
    int cmp(FbItem a, FbItem b) {
      final c = switch (_sortBy) {
        'modified' => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
        'size' => a.folder ? 0 : a.size.compareTo(b.size),
        'type' => _typeLabel(a).compareTo(_typeLabel(b)),
        _ => 0,
      };
      return c != 0 ? c : _natural(a.name, b.name);
    }

    list.sort((a, b) {
      if (a.folder != b.folder) return a.folder ? -1 : 1; // folders first, always
      final c = cmp(a, b);
      return _asc ? c : -c;
    });
    return list;
  }

  String _typeLabel(FbItem i) => i.folder ? tr('Folder') : (i.extension.isEmpty ? tr('File') : i.extension.toUpperCase());

  List<FbItem> get _selItems => [for (final i in _items) if (_selected.contains(i.path)) i];

  void _open(FbItem i) {
    if (i.folder) {
      _load(i.path);
    } else {
      _download([i]);
    }
  }

  void _up() {
    final p = fs.parent(_path);
    if (p != null) _load(p);
  }

  void _tap(List<FbItem> view, int index) {
    final kb = HardwareKeyboard.instance;
    final path = view[index].path;
    setState(() {
      if (kb.isShiftPressed && _anchor != null && _anchor! < view.length) {
        final a = _anchor!, b = index;
        if (!kb.isControlPressed) _selected.clear();
        for (var k = a < b ? a : b; k <= (a < b ? b : a); k++) {
          _selected.add(view[k].path);
        }
      } else if (kb.isControlPressed) {
        if (!_selected.remove(path)) _selected.add(path);
        _anchor = index;
      } else {
        _selected
          ..clear()
          ..add(path);
        _anchor = index;
      }
    });
    if (mounted) _focus.requestFocus();
  }

  // ---------------------------------------------------------- transfers
  void _enqueue(FbTransfer t, Future<void> Function() job) {
    setState(() {
      _transfers.add(t);
      _jobs[t] = job;
    });
    _pump();
  }

  /// one transfer at a time (the server allows 3 per computer)
  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = _transfers.where((t) => t.state.value == 'queued').firstOrNull;
        if (next == null) break;
        final job = _jobs.remove(next);
        if (job != null) await job();
        if (mounted) setState(() {});
      }
    } finally {
      _running = false;
    }
  }

  bool get _busy => _transfers.any((t) => !t.finished);

  Future<void> _download(List<FbItem> items) async {
    if (items.isEmpty) return;
    final archive = items.length != 1 || items.first.folder;
    if (!archive && items.first.size == 0) {
      trmmSnack(context, tr('Empty files cannot be transferred'), error: true);
      return;
    }
    var name = archive
        ? '${items.length == 1 ? items.first.name : (fs.leaf(_path).replaceAll(':', '').isEmpty ? 'download' : fs.leaf(_path).replaceAll(':', ''))}.zip'
        : items.first.name;
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var dest = await FilePicker.platform.saveFile(dialogTitle: tr('Save as'), fileName: name);
    if (dest == null || !mounted) return;
    if (archive && !dest.toLowerCase().endsWith('.zip')) dest = '$dest.zip';
    final t = FbTransfer(FbKind.download, name, dest);
    _enqueue(t, () => _engine.download(t, items));
  }

  Future<void> _pickUpload() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, dialogTitle: tr('Upload'));
    if (r == null) return;
    await _upload([for (final f in r.files) if (f.path != null) f.path!]);
  }

  Future<void> _upload(List<String> local) async {
    final files = <File>[];
    var folders = 0;
    for (final p in local) {
      if (FileSystemEntity.isDirectorySync(p)) {
        folders++;
      } else {
        files.add(File(p));
      }
    }
    if (folders > 0 && mounted) {
      trmmSnack(context, tr('Folders cannot be uploaded: compress them into a .zip first.'), error: true);
    }
    if (files.isEmpty) return;
    final dir = _path;
    String base(File f) => f.path.split(Platform.pathSeparator).last;
    Set<String> exist;
    try {
      exist = await fs.existing(dir, [for (final f in files) base(f)]);
    } on TrmmApiException catch (e) {
      if (mounted) trmmSnack(context, fbErrorText(e), error: true);
      return;
    }
    var replace = true;
    if (exist.isNotEmpty) {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('Upload')),
          content: Text('${tr('{0} file(s) already exist in this folder.', [exist.length])}\n\n'
              '${exist.take(10).join('\n')}${exist.length > 10 ? '\n...' : ''}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel'))),
            OutlinedButton(onPressed: () => Navigator.pop(c, 'skip'), child: Text(tr('Skip'))),
            FilledButton(onPressed: () => Navigator.pop(c, 'replace'), child: Text(tr('Replace'))),
          ],
        ),
      );
      if (choice == null) return;
      replace = choice == 'replace';
    }
    for (final f in files) {
      final name = base(f);
      if (!replace && exist.contains(name)) continue;
      final t = FbTransfer(FbKind.upload, name, dir);
      _enqueue(t, () async {
        await _engine.upload(t, f, replace: replace);
        if (t.state.value == 'done' && mounted && fs.normalize(_path) == fs.normalize(dir)) _load(_path);
      });
    }
  }

  Future<void> _extract(FbItem zip) async {
    final ctl = TextEditingController(text: fs.join(_path, zip.name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '')));
    var replace = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('${tr('Extract')}: ${zip.name}'),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: ctl, decoration: InputDecoration(labelText: tr('Extract to'))),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: replace,
                onChanged: (v) => set(() => replace = v ?? false),
                title: Text(tr('Replace existing files')),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Extract'))),
          ],
        ),
      ),
    );
    final dest = ctl.text.trim();
    ctl.dispose();
    if (ok != true || dest.isEmpty || !mounted) return;
    final t = FbTransfer(FbKind.extract, zip.name, dest);
    final here = _path;
    _enqueue(t, () async {
      await _engine.extract(t, zip.path, replace: replace);
      if (t.state.value == 'done' && mounted && _path == here) _load(_path);
    });
  }

  // ------------------------------------------------------- folder actions
  Future<String?> _askName(String title, String initial) async {
    final ctl = TextEditingController(text: initial);
    ctl.selection = TextSelection(
        baseOffset: 0, extentOffset: initial.contains('.') ? initial.lastIndexOf('.') : initial.length);
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Name')),
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(tr('OK'))),
        ],
      ),
    );
    ctl.dispose();
    final v = r?.trim() ?? '';
    return v.isEmpty || v == initial ? null : v;
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } on TrmmApiException catch (e) {
      if (!mounted) return;
      if (e.forbidden) {
        await showTrmmForbidden(context, e.message);
      } else {
        trmmSnack(context, fbErrorText(e), error: true);
      }
    }
    if (mounted) await _load(_path);
  }

  Future<void> _newFolder() async {
    final name = await _askName(tr('New folder'), '');
    if (name != null) await _run(() => fs.mkdir(_path, name));
  }

  Future<void> _rename(FbItem i) async {
    final name = await _askName(tr('Rename'), i.name);
    if (name != null) await _run(() => fs.rename(i.path, name));
  }

  Future<void> _delete(List<FbItem> items) async {
    if (items.isEmpty) return;
    final what = items.length == 1 ? items.first.name : tr('{0} items', [items.length]);
    if (!await trmmConfirm(context, tr('Delete {0}?', [what]), title: tr('Delete'))) return;
    await _run(() async {
      final failed = await fs.delete([for (final i in items) i.path]);
      if (failed.isNotEmpty && mounted) {
        await showDialog(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr('Some items could not be deleted:')),
            content: SingleChildScrollView(
              child: SelectableText([for (final e in failed.entries) '${e.key}: ${e.value}'].join('\n')),
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(tr('Close')))],
          ),
        );
      }
    });
  }

  Future<void> _menu(FbItem? item, Offset pos) async {
    if (item != null && !_selected.contains(item.path)) {
      setState(() {
        _selected
          ..clear()
          ..add(item.path);
      });
    }
    final sel = _selItems;
    PopupMenuItem<String> it(String v, IconData icon, String label, {bool enabled = true}) => PopupMenuItem(
          value: v,
          height: 36,
          enabled: enabled,
          child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)]),
        );
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        if (sel.length == 1 && sel.first.folder) it('open', Icons.folder_open, tr('Open')),
        if (sel.isNotEmpty) it('download', Icons.download, tr('Download')),
        if (sel.length == 1 && sel.first.extension == 'zip') it('extract', Icons.unarchive_outlined, tr('Extract')),
        if (sel.length == 1) it('rename', Icons.drive_file_rename_outline, tr('Rename')),
        if (sel.isNotEmpty) it('delete', Icons.delete_outline, tr('Delete')),
        if (sel.isNotEmpty) const PopupMenuDivider(),
        it('upload', Icons.upload, tr('Upload')),
        it('mkdir', Icons.create_new_folder_outlined, tr('New folder')),
        it('refresh', Icons.refresh, tr('Refresh')),
      ],
    );
    switch (v) {
      case 'open':
        _open(sel.first);
      case 'download':
        await _download(sel);
      case 'extract':
        await _extract(sel.first);
      case 'rename':
        await _rename(sel.first);
      case 'delete':
        await _delete(sel);
      case 'upload':
        await _pickUpload();
      case 'mkdir':
        await _newFolder();
      case 'refresh':
        await _load(_path);
    }
  }

  Future<void> _close() async {
    if (_busy) {
      if (!await trmmConfirm(context, tr('Cancel the transfers in progress?'), title: tr('File Transfer'))) return;
      for (final t in _transfers) {
        t.cancel();
      }
    }
    if (mounted) Navigator.pop(context);
  }

  // ----------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final sel = _selItems;
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: Text('${trmmAgentTitle(widget.agent)} (${tr('File Transfer')})'),
            trailing: IconButton(onPressed: _close, icon: const Icon(Icons.close)),
          ),
          _pathBar(),
          _toolbar(sel),
          const Divider(height: 1),
          // keyboard shortcuts only on the file list (not in the text fields)
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.f5): () => _load(_path),
                const SingleActivator(LogicalKeyboardKey.backspace): _up,
                const SingleActivator(LogicalKeyboardKey.delete): () => _delete(_selItems),
                const SingleActivator(LogicalKeyboardKey.f2): () {
                  if (_selItems.length == 1) _rename(_selItems.first);
                },
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (_selItems.length == 1) _open(_selItems.first);
                },
                const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                    setState(() => _selected.addAll(_view.map((e) => e.path))),
              },
              child: Focus(focusNode: _focus, autofocus: true, child: _dropArea(theme)),
            ),
          ),
          if (_transfers.isNotEmpty) _transfersPanel(theme),
        ]),
      ),
    );
  }

  Widget _pathBar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Row(children: [
          IconButton(
            tooltip: tr('Up'),
            onPressed: fs.parent(_path) == null || _loading ? null : _up,
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: tr('Default folder'),
            onPressed: _loading ? null : () => _load(''),
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            tooltip: tr('Refresh'),
            onPressed: _loading ? null : () => _load(_path),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _pathCtl,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: tr('Path'),
                hintText: fs.windows ? r'C:\' : '/',
              ),
              onSubmitted: (v) => _load(v.trim().isEmpty ? '' : fs.normalize(v)),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 200,
            child: TextField(
              controller: _filterCtl,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: tr('Filter'),
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ]),
      );

  Widget _toolbar(List<FbItem> sel) {
    Widget b(IconData icon, String label, VoidCallback? on) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: TextButton.icon(onPressed: on, icon: Icon(icon, size: 18), label: Text(label)),
        );
    final one = sel.length == 1 ? sel.first : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(children: [
        b(Icons.upload, tr('Upload'), _path.isEmpty ? null : _pickUpload),
        b(Icons.download, tr('Download'), sel.isEmpty ? null : () => _download(sel)),
        b(Icons.create_new_folder_outlined, tr('New folder'), _path.isEmpty ? null : _newFolder),
        b(Icons.drive_file_rename_outline, tr('Rename'), one == null ? null : () => _rename(one)),
        b(Icons.delete_outline, tr('Delete'), sel.isEmpty ? null : () => _delete(sel)),
        b(Icons.unarchive_outlined, tr('Extract'), one?.extension == 'zip' ? () => _extract(one!) : null),
        const Spacer(),
        if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(
          sel.isEmpty ? tr('{0} items', [_items.length]) : '${sel.length} / ${_items.length}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ]),
    );
  }

  Widget _dropArea(ThemeData theme) => DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          if (_path.isNotEmpty) _upload([for (final f in d.files) f.path]);
        },
        child: Stack(children: [
          Positioned.fill(child: _table(theme)),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: theme.colorScheme.primary.withOpacity(0.08),
                  alignment: Alignment.center,
                  child: Text(tr('Drop files here to upload'), style: theme.textTheme.titleMedium),
                ),
              ),
            ),
        ]),
      );

  Widget _header(String key, String label, {double? width, TextAlign align = TextAlign.left}) {
    final active = _sortBy == key;
    final w = InkWell(
      onTap: () => setState(() {
        if (active) {
          _asc = !_asc;
        } else {
          _sortBy = key;
          _asc = true;
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Row(
          mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
            if (active) Icon(_asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
    return width == null ? Expanded(child: w) : SizedBox(width: width, child: w);
  }

  IconData _icon(FbItem i) {
    if (i.folder) return Icons.folder;
    return switch (i.extension) {
      'zip' || '7z' || 'rar' || 'gz' || 'tar' => Icons.folder_zip_outlined,
      'exe' || 'msi' || 'bat' || 'cmd' || 'ps1' || 'sh' => Icons.terminal,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'bmp' || 'webp' => Icons.image_outlined,
      'txt' || 'log' || 'ini' || 'cfg' || 'conf' || 'json' || 'xml' || 'csv' => Icons.description_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Widget _table(ThemeData theme) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          trmmErrorView(context, _error!),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _load(_path),
            icon: const Icon(Icons.refresh),
            label: Text(tr('Refresh')),
          ),
        ]),
      );
    }
    final view = _view;
    final small = theme.textTheme.bodySmall;
    return Column(children: [
      if (_error != null)
        Container(
          width: double.infinity,
          color: theme.colorScheme.error.withOpacity(0.1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          const SizedBox(width: 30),
          _header('name', tr('Name')),
          _header('modified', tr('Modified'), width: 150),
          _header('size', tr('Size'), width: 100, align: TextAlign.right),
          _header('type', tr('Type'), width: 90),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: GestureDetector(
          onSecondaryTapDown: (d) => _menu(null, d.globalPosition),
          child: view.isEmpty
              ? Center(child: Text(_loading ? '' : tr('Empty folder'), style: small))
              : ListView.builder(
                  itemCount: view.length,
                  itemExtent: 30,
                  itemBuilder: (_, k) {
                    final i = view[k];
                    final selected = _selected.contains(i.path);
                    final dim = i.hidden || i.system;
                    return GestureDetector(
                      onSecondaryTapDown: (d) => _menu(i, d.globalPosition),
                      child: InkWell(
                        onTap: () => _tap(view, k),
                        onDoubleTap: () => _open(i),
                        child: Container(
                          color: selected ? theme.colorScheme.primary.withOpacity(0.15) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Opacity(
                            opacity: dim ? 0.6 : 1,
                            child: Row(children: [
                              SizedBox(
                                width: 30,
                                child: Icon(_icon(i), size: 18, color: i.folder ? Colors.amber.shade700 : null),
                              ),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Text(i.name, overflow: TextOverflow.ellipsis),
                                ),
                              ),
                              SizedBox(
                                width: 150,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Text(i.modified == null ? '' : _date(i.modified!), style: small),
                                ),
                              ),
                              SizedBox(
                                width: 100,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Text(i.folder ? '' : fbBytes(i.size), textAlign: TextAlign.right, style: small),
                                ),
                              ),
                              SizedBox(
                                width: 90,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Text(_typeLabel(i), overflow: TextOverflow.ellipsis, style: small),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    ]);
  }

  Widget _transfersPanel(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
          child: Row(children: [
            Text(tr('Transfers'), style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton(
              onPressed: _transfers.any((t) => t.finished)
                  ? () => setState(() => _transfers.removeWhere((t) => t.finished))
                  : null,
              child: Text(tr('Clear finished')),
            ),
          ]),
        ),
        Flexible(
          child: ListView(shrinkWrap: true, children: [for (final t in _transfers.reversed) _transferRow(t, theme)]),
        ),
      ]),
    );
  }

  Widget _transferRow(FbTransfer t, ThemeData theme) {
    return AnimatedBuilder(
      animation: Listenable.merge([t.state, t.progress]),
      builder: (_, __) {
        final (done, total) = t.progress.value;
        final s = t.state.value;
        final pct = total > 0 ? done / total : null;
        final status = switch (s) {
          'queued' => tr('Waiting'),
          'preparing' => t.message.isNotEmpty ? tr(t.message) : tr('Preparing...'),
          'running' => t.kind == FbKind.extract
              ? '$done / $total'
              : '${fbBytes(done)} / ${fbBytes(total)}${pct == null ? '' : '  (${(pct * 100).toStringAsFixed(0)}%)'}',
          'done' => t.message.isEmpty ? tr('Done') : '${tr('Done')} (${t.message})',
          'cancelled' => tr('Cancelled'),
          _ => '${tr('Error')}: ${tr(t.message)}',
        };
        final icon = switch (t.kind) {
          FbKind.download => Icons.download,
          FbKind.upload => Icons.upload,
          FbKind.extract => Icons.unarchive_outlined,
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(children: [
            Icon(icon, size: 18, color: s == 'error' ? theme.colorScheme.error : null),
            const SizedBox(width: 8),
            SizedBox(
              width: 260,
              child: Tooltip(
                message: t.target,
                child: Text(t.name, overflow: TextOverflow.ellipsis),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (!t.finished) LinearProgressIndicator(value: s == 'running' ? pct : null),
                Text(status,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: s == 'error' ? theme.colorScheme.error : null)),
              ]),
            ),
            if (!t.finished)
              IconButton(tooltip: tr('Cancel'), onPressed: t.cancel, icon: const Icon(Icons.close, size: 18))
            else if (t.kind == FbKind.download && s == 'done' && Platform.isWindows)
              IconButton(
                tooltip: tr('Show in folder'),
                onPressed: () => Process.run('explorer.exe', ['/select,', t.target]),
                icon: const Icon(Icons.folder_open, size: 18),
              )
            else
              const SizedBox(width: 40),
          ]),
        );
      },
    );
  }
}
