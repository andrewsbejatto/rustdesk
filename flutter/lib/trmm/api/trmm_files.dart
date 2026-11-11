// Native file browser of Tactical RMM 1.6 (agents/<id>/files/...): listing,
// folder operations and chunked transfers, as the web panel does
// (TacticalRmm-web src/services/fileTransfer, agents/views.py).
//
// Protocol notes:
// - transfers go through the server (Redis relay): download = init, GET
//   chunk (204 = not ready yet), ACK, complete (agent sha256, checked here);
//   upload = init, PUT raw chunks with Content-Range, wait for the agent to
//   commit, complete with our sha256
// - download / upload / archive paths are NOT normalized by the server:
//   Windows paths always go with "\" and "C:\"
// - 408 = retry the same request; 429 = too many transfers at the same time
//   (3 per agent, 10 per user): wait and retry; a failed transfer is always
//   cancelled so it does not keep its slot for an hour
// - empty (0 byte) files cannot be transferred

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'trmm_client.dart';

const _chunkSize = 8 * 1024 * 1024;

class FbItem {
  final String name;
  final String path;
  final bool folder;
  final int size;
  final DateTime? modified;
  final bool hidden;
  final bool system;
  final bool readonly;

  FbItem.fromJson(Map<String, dynamic> j)
      : name = '${j['name'] ?? ''}',
        path = '${j['path'] ?? ''}',
        folder = j['type'] == 'folder',
        size = int.tryParse('${j['size'] ?? 0}') ?? 0,
        modified = DateTime.tryParse('${j['modified'] ?? ''}')?.toLocal(),
        hidden = j['hidden'] == true,
        system = j['system'] == true,
        readonly = j['readonly'] == true;

  String get extension {
    final i = name.lastIndexOf('.');
    return folder || i <= 0 ? '' : name.substring(i + 1).toLowerCase();
  }
}

/// error returned by the agent: "Files List failed: access denied" -> "access denied"
String fbErrorText(Object e) {
  final s = e is TrmmApiException ? e.message : '$e';
  final m = RegExp(r'^[^:]+\s+failed:\s*(.+)$', dotAll: true).firstMatch(s);
  return m?.group(1) ?? s;
}

class TrmmFiles {
  final TrmmClient client;
  final String agentId;
  final String plat;
  TrmmFiles(this.client, this.agentId, this.plat);

  bool get windows => plat == 'windows';
  String get sep => windows ? r'\' : '/';
  String get _base => '/agents/$agentId';

  /// same rules as the web (utils/filebrowser.ts normalizeAgentListPath)
  String normalize(String p) {
    var s = p.trim();
    if (windows) {
      s = s.replaceAll('/', r'\');
      final drive = RegExp(r'^([A-Za-z]):\\*$').firstMatch(s);
      if (drive != null) return '${drive.group(1)!.toUpperCase()}:\\';
      if (s.startsWith(r'\\')) {
        while (s.length > 2 && s.endsWith(r'\')) {
          s = s.substring(0, s.length - 1);
        }
      }
      return s;
    }
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s.isEmpty ? '/' : s;
  }

  /// parent folder, null at a root
  String? parent(String path) {
    final p = normalize(path);
    if (windows) {
      if (RegExp(r'^[A-Za-z]:\\$').hasMatch(p)) return null;
      final i = p.lastIndexOf(r'\');
      if (i < 0) return null;
      if (p.startsWith(r'\\') && p.substring(2).split(r'\').length <= 2) return null; // \\server\share
      final up = p.substring(0, i);
      return RegExp(r'^[A-Za-z]:$').hasMatch(up) ? '$up\\' : up;
    }
    if (p == '/') return null;
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  String join(String dir, String name) {
    final d = normalize(dir);
    return d.endsWith(sep) ? '$d$name' : '$d$sep$name';
  }

  String leaf(String path) {
    final p = normalize(path);
    final i = p.lastIndexOf(sep);
    return i < 0 ? p : p.substring(i + 1);
  }

  Future<Map<String, dynamic>> defaults() async =>
      Map<String, dynamic>.from(await client.get('$_base/file-browser-defaults/'));

  /// folder contents (all pages, at most 10000 items); path '' = the agent's
  /// default folder. Returns the real path and the items.
  Future<(String, List<FbItem>)> list(String path) async {
    final items = <FbItem>[];
    final seen = <String>{};
    var real = path.isEmpty ? '' : normalize(path);
    var page = 1;
    while (true) {
      final r = await client.send('GET', '$_base/files/',
          query: {'path': real, 'page': page, 'page_size': 500}, timeout: const Duration(seconds: 90));
      if (r['path'] is String && (r['path'] as String).isNotEmpty) real = r['path'] as String;
      for (final j in (r['items'] as List? ?? const [])) {
        final it = FbItem.fromJson(Map<String, dynamic>.from(j));
        if (it.path.isNotEmpty && seen.add(it.path)) items.add(it);
      }
      if (r['has_more'] != true || items.length >= 10000 || page >= 10000) break;
      page++;
    }
    return (real, items);
  }

  Future<void> mkdir(String parent, String name) =>
      client.post('$_base/files/folder/', {'path': normalize(parent), 'name': name});

  Future<void> rename(String path, String newName) =>
      client.post('$_base/files/rename/', {'path': path, 'new_name': newName});

  /// path -> error, for the items that could not be deleted
  Future<Map<String, String>> delete(List<String> paths) async {
    final failed = <String, String>{};
    for (var i = 0; i < paths.length; i += 100) {
      final part = paths.sublist(i, min(i + 100, paths.length));
      final r = await client.send('DELETE', '$_base/files/',
          body: {'paths': part}, timeout: const Duration(seconds: 90));
      for (final x in (r is Map ? (r['results'] as List? ?? const []) : const [])) {
        if (x['success'] != true) failed['${x['path']}'] = '${x['error'] ?? ''}';
      }
    }
    return failed;
  }

  /// names that already exist in [dir]
  Future<Set<String>> existing(String dir, List<String> names) async {
    if (names.isEmpty) return {};
    final out = <String>{};
    for (var i = 0; i < names.length; i += 500) {
      final r = await client.post(
          '$_base/files/exists/', {'path': normalize(dir), 'names': names.sublist(i, min(i + 500, names.length))});
      for (final n in (r['existing'] as List? ?? const [])) {
        out.add('$n');
      }
    }
    return out;
  }
}

// ------------------------------------------------------------- transfers

enum FbKind { download, upload, extract }

class FbCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// one transfer shown in the transfers panel
class FbTransfer {
  final FbKind kind;
  final String name;

  /// download: local file; upload: remote folder; extract: remote folder
  final String target;

  /// done, total (bytes; files for extract)
  final progress = ValueNotifier<(int, int)>((0, 0));

  /// queued | preparing | running | done | error | cancelled
  final state = ValueNotifier<String>('queued');
  String message = '';
  bool _cancel = false;

  FbTransfer(this.kind, this.name, this.target);

  bool get finished => const {'done', 'error', 'cancelled'}.contains(state.value);
  void cancel() {
    _cancel = true;
    if (state.value == 'queued') state.value = 'cancelled';
  }

  void _check() {
    if (_cancel) throw FbCancelled();
  }
}

class TrmmFileTransfers {
  final TrmmFiles fs;
  TrmmFileTransfers(this.fs);

  TrmmClient get _c => fs.client;
  String get _base => '/agents/${fs.agentId}/files';

  static bool _retryable(TrmmApiException e) =>
      e.status == 0 || e.status == 408 || e.status == 425 || e.status == 429 || e.status >= 500;

  /// retries timeouts / server busy; 429 (too many transfers) waits longer
  Future<T> _retry<T>(FbTransfer t, Future<T> Function() f, {Duration limit = const Duration(seconds: 60)}) async {
    final start = DateTime.now();
    var delay = const Duration(milliseconds: 500);
    var attempts = 0;
    while (true) {
      t._check();
      try {
        return await f();
      } on TrmmApiException catch (e) {
        attempts++;
        if (!_retryable(e)) rethrow;
        final busy = e.status == 429;
        final max = busy ? const Duration(minutes: 10) : limit;
        if (attempts >= 40 || (attempts >= 4 && DateTime.now().difference(start) > max)) rethrow;
        if (busy) {
          t.message = e.message;
          t.state.value = 'preparing';
        }
        await Future.delayed(delay);
        final cap = busy ? 30000 : 4000;
        delay = Duration(milliseconds: min(delay.inMilliseconds * 2, cap));
      }
    }
  }

  Future<void> _cancelSession(String op, String? sid, bool byUser) async {
    if (sid == null) return;
    try {
      await _c.send('POST', '$_base/$op/$sid/cancel/',
          body: op == 'extract' ? {} : {'reason': byUser ? 'user' : 'error'}, timeout: const Duration(seconds: 30));
    } catch (_) {}
  }

  /// downloads [paths] to the local file [t.target]: one file as is, folders
  /// or several items as a zip built by the agent
  Future<void> download(FbTransfer t, List<FbItem> items) async {
    String? sid;
    final part = File('${t.target}.part');
    RandomAccessFile? raf;
    try {
      t.state.value = 'preparing';
      final archive = items.length != 1 || items.first.folder;
      int total;
      if (archive) {
        final r = await _retry(
            t,
            () => _c.send('POST', '$_base/download/archive/init/',
                body: {
                  'paths': [for (final i in items) fs.normalize(i.path)],
                  'filename': t.name,
                  'chunk_size': _chunkSize,
                },
                timeout: const Duration(seconds: 60)));
        sid = r['session_id'] as String;
        // the agent builds the zip first
        final until = DateTime.now().add(const Duration(hours: 1));
        while (true) {
          t._check();
          final st = await _retry(
              t, () => _c.send('GET', '$_base/download/$sid/status/', timeout: const Duration(seconds: 30)));
          final s = '${st['status']}';
          if (s == 'agent_ready' || s == 'transferring') {
            total = (st['total_size'] as num).toInt();
            final w = st['warnings'];
            if (w is List && w.isNotEmpty) t.message = w.take(3).join('; ');
            break;
          }
          if (const {'failed', 'cancelled', 'expired'}.contains(s)) {
            throw TrmmApiException(400, '${st['error'] ?? s}');
          }
          if (DateTime.now().isAfter(until)) throw TrmmApiException(408, 'Timeout');
          await Future.delayed(const Duration(milliseconds: 1500));
        }
      } else {
        if (items.first.size == 0) throw TrmmApiException(400, 'Empty files cannot be transferred');
        final r = await _retry(
            t,
            () => _c.send('POST', '$_base/download/init/',
                body: {'source_path': fs.normalize(items.first.path), 'chunk_size': _chunkSize},
                timeout: const Duration(seconds: 60)));
        sid = r['session_id'] as String;
        total = (r['total_size'] as num).toInt();
      }

      t.state.value = 'running';
      t.progress.value = (0, total);
      raf = await part.open(mode: FileMode.write);
      final out = _DigestSink();
      final hash = sha256.startChunkedConversion(out);
      var off = 0;
      while (off < total) {
        // wait for the chunk: 204 while the agent has not sent it yet
        var delay = 50;
        var lastData = DateTime.now();
        late Uint8List body;
        late int end;
        while (true) {
          t._check();
          final (status, bytes, headers) = await _retry(
              t,
              () => _c.getBytes('$_base/download/$sid/chunk/',
                  query: {'committed_offset': off}, timeout: const Duration(seconds: 120)));
          if (status == 200) {
            final m = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+)').firstMatch(headers['content-range'] ?? '');
            final s = int.tryParse(m?.group(1) ?? '');
            final e = int.tryParse(m?.group(2) ?? '');
            final tot = int.tryParse(m?.group(3) ?? '');
            if (s == off && e != null && tot == total && bytes.length == e - s! + 1) {
              body = bytes;
              end = e;
              break;
            }
          }
          if (DateTime.now().difference(lastData).inSeconds > 150) {
            throw TrmmApiException(408, 'The agent stopped sending the file');
          }
          await Future.delayed(Duration(milliseconds: delay));
          delay = min(delay * 2, 2000);
          if (status == 200) lastData = DateTime.now();
        }
        await raf.writeFrom(body);
        hash.add(body);
        final next = end + 1;
        await _retry(
            t,
            () => _c.send('POST', '$_base/download/$sid/ack/',
                body: {'committed_offset': next}, timeout: const Duration(seconds: 30)));
        off = next;
        t.progress.value = (off, total);
      }
      await raf.close();
      raf = null;
      hash.close();
      final c = await _retry(
          t,
          () => _c.send('POST', '$_base/download/$sid/complete/', body: {}, timeout: const Duration(seconds: 120)),
          limit: const Duration(minutes: 10));
      final agentSha = '${c is Map ? c['sha256'] ?? '' : ''}'.toLowerCase();
      if (agentSha.isNotEmpty && agentSha != out.value.toString()) {
        throw TrmmApiException(400, 'SHA-256 mismatch: the file is corrupted');
      }
      final dest = File(t.target);
      if (await dest.exists()) await dest.delete();
      await part.rename(t.target);
      t.state.value = 'done';
    } catch (e) {
      await _fail(t, e, 'download', sid);
      try {
        await raf?.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  Future<void> _fail(FbTransfer t, Object e, String op, String? sid) async {
    final byUser = e is FbCancelled;
    await _cancelSession(op, sid, byUser);
    t.message = byUser ? '' : fbErrorText(e);
    t.state.value = byUser ? 'cancelled' : 'error';
  }

  /// uploads the local file [local] into the remote folder [t.target]
  Future<void> upload(FbTransfer t, File local, {bool replace = true}) async {
    String? sid;
    RandomAccessFile? raf;
    try {
      t.state.value = 'preparing';
      final size = await local.length();
      if (size == 0) throw TrmmApiException(400, 'Empty files cannot be transferred');
      final r = await _retry(
          t,
          () => _c.send('POST', '$_base/upload/init/',
              body: {
                'filename': t.name,
                'destination_path': fs.normalize(t.target),
                'total_size': size,
                'chunk_size': _chunkSize,
                'conflict_policy': replace ? 'replace' : 'skip',
              },
              timeout: const Duration(seconds: 60)));
      sid = r['session_id'] as String;
      final cs = (r['chunk_size'] as num?)?.toInt() ?? _chunkSize;
      var off = (r['committed_offset'] as num?)?.toInt() ?? 0;
      t.state.value = 'running';
      t.progress.value = (off, size);
      raf = await local.open();
      final out = _DigestSink();
      final hash = sha256.startChunkedConversion(out);
      Future<void> hashRange(int from, int to) async {
        await raf!.setPosition(from);
        var p = from;
        while (p < to) {
          final b = await raf.read(min(_chunkSize, to - p));
          if (b.isEmpty) break;
          hash.add(b);
          p += b.length;
        }
      }

      if (off > 0) await hashRange(0, off);

      Future<Map<String, dynamic>> ready() async => Map<String, dynamic>.from(await _retry<dynamic>(
          t, () => _c.send('GET', '$_base/upload/$sid/chunk/', timeout: const Duration(seconds: 15))));

      /// polls until [done] (the agent writes what the server received)
      Future<Map<String, dynamic>> waitAgent(bool Function(Map<String, dynamic>) done) async {
        var delay = 50;
        var last = -1;
        var lastMove = DateTime.now();
        while (true) {
          t._check();
          final rd = await ready();
          if (rd['status'] == 'failed') throw TrmmApiException(400, '${rd['error'] ?? 'failed'}');
          final c = (rd['committed_offset'] as num?)?.toInt() ?? 0;
          t.progress.value = (min(c, size), size);
          if (done(rd)) return rd;
          if (c != last) {
            last = c;
            lastMove = DateTime.now();
          } else if (DateTime.now().difference(lastMove).inSeconds > 150) {
            throw TrmmApiException(408, 'The agent stopped receiving the file');
          }
          await Future.delayed(Duration(milliseconds: delay));
          delay = min(delay * 2, 2000);
        }
      }

      var canPut = true;
      var errors = 0;
      while (off < size) {
        t._check();
        if (!canPut) {
          final rd = await waitAgent((rd) =>
              rd['can_put'] == true || ((rd['accepted_offset'] as num?)?.toInt() ?? 0) > off);
          final acc = (rd['accepted_offset'] as num?)?.toInt() ?? off;
          canPut = true;
          if (acc > off) {
            await hashRange(off, acc);
            off = acc;
            continue;
          }
        }
        final len = min(cs, size - off);
        await raf.setPosition(off);
        final buf = await raf.read(len);
        dynamic resp;
        try {
          resp = await _c.putBytes('$_base/upload/$sid/chunk/', buf,
              headers: {'Content-Range': 'bytes $off-${off + buf.length - 1}/$size'},
              timeout: const Duration(seconds: 300));
          errors = 0;
        } on TrmmApiException catch (e) {
          if (e.status == 408 && e.message.toLowerCase().contains('commit')) {
            canPut = false; // pipeline full: nothing was stored
            continue;
          }
          if (_retryable(e) && ++errors < 12) {
            await Future.delayed(Duration(milliseconds: min(500 << errors, 4000)));
            continue;
          }
          rethrow;
        }
        hash.add(buf);
        final acc = (resp['accepted_offset'] as num?)?.toInt() ?? off + buf.length;
        if (acc > off + buf.length) await hashRange(off + buf.length, acc);
        off = max(acc, off + buf.length);
        canPut = resp['can_put'] != false;
        // progress = what the agent already wrote on the disk
        final committed = (resp['committed_offset'] as num?)?.toInt() ?? 0;
        t.progress.value = (min(committed, size), size);
      }
      await waitAgent((rd) => ((rd['committed_offset'] as num?)?.toInt() ?? 0) >= size);
      t.progress.value = (size, size);
      hash.close();
      final sha = out.value.toString();
      await raf.close();
      raf = null;
      await _retry(
          t,
          () => _c.send('POST', '$_base/upload/$sid/complete/',
              body: {'sha256': sha}, timeout: const Duration(seconds: 120)),
          limit: const Duration(minutes: 10));
      t.state.value = 'done';
    } catch (e) {
      try {
        await raf?.close();
      } catch (_) {}
      await _fail(t, e, 'upload', sid);
    }
  }

  /// extracts the zip [zipPath] on the agent into the folder [t.target]
  Future<void> extract(FbTransfer t, String zipPath, {bool replace = false}) async {
    String? sid;
    try {
      t.state.value = 'preparing';
      final r = await _retry(
          t,
          () => _c.send('POST', '$_base/extract/',
              body: {
                'source_path': zipPath,
                'destination_path': t.target,
                'conflict_policy': replace ? 'replace' : 'skip',
              },
              timeout: const Duration(seconds: 60)));
      sid = r['session_id'] as String;
      t.state.value = 'running';
      while (true) {
        t._check();
        await Future.delayed(const Duration(seconds: 1));
        final st =
            await _retry(t, () => _c.send('GET', '$_base/extract/$sid/', timeout: const Duration(seconds: 30)));
        final done = (st['files_done'] as num?)?.toInt() ?? 0;
        final all = (st['files_total'] as num?)?.toInt() ?? 0;
        t.progress.value = (done, all);
        final s = '${st['status']}';
        if (s == 'completed') {
          final skipped = (st['files_skipped'] as num?)?.toInt() ?? 0;
          if (skipped > 0) t.message = 'skipped: $skipped';
          t.state.value = 'done';
          return;
        }
        if (const {'failed', 'cancelled', 'expired'}.contains(s)) {
          throw TrmmApiException(400, '${st['error'] ?? s}');
        }
      }
    } catch (e) {
      await _fail(t, e, 'extract', sid);
    }
  }
}
