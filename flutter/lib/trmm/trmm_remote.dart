// "Take Control" with the embedded RustDesk engine.
// The TRMM server gives {remote_id, password, id_server, relay_server, key};
// the rendezvous server of that TRMM is applied before connecting, so the app
// works with several TRMM servers, each one with its own hbbs/hbbr.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'api/trmm_client.dart';
import 'trmm_i18n.dart';
import 'trmm_notice.dart';
import 'trmm_session.dart';
import 'trmm_webview.dart';

/// Points the embedded RustDesk engine to the RustDesk server of the active
/// TRMM (called after login and before each connection).
Future<void> applyTrmmRemoteServer() async {
  try {
    final c = await TrmmSession.to.api.client.get('/remoteaccess/server/');
    if (c is Map && (c['id_server'] ?? '').toString().isNotEmpty) {
      await _applyServer(Map<String, dynamic>.from(c));
    }
  } catch (_) {
    // no remote access permission or old server: nothing to apply
  }
}

Future<void> _applyServer(Map<String, dynamic> c) async {
  Future<void> set(String key, String? value) async {
    final v = (value ?? '').trim();
    if (v.isEmpty) return;
    if (bind.mainGetOptionSync(key: key) != v) {
      await bind.mainSetOption(key: key, value: v);
    }
  }

  await set('custom-rendezvous-server', c['id_server'] as String?);
  await set('relay-server', c['relay_server'] as String?);
  await set('key', c['key'] as String?);
}

/// opens a session from a {remote_id, password, id_server, relay_server, key} answer
Future<void> openRemoteWithConfig(BuildContext context, Map<String, dynamic> c) => _open(context, c);

Future<void> _open(BuildContext context, Map<String, dynamic> c, {bool fileTransfer = false}) async {
  await _applyServer(c);
  // title of the remote window/tab: "Client - Site - hostname" (RustDesk shows
  // the peer alias; it adds @hostname only when the alias lacks it)
  final title = [
    if (c['quick_support'] == true) tr('Quick Support'),
    '${c['client'] ?? ''}',
    '${c['site'] ?? ''}',
    '${c['hostname'] ?? ''}',
  ].where((e) => e.trim().isNotEmpty).join(' - ');
  if (title.isNotEmpty) {
    try {
      await bind.mainSetPeerAlias(id: c['remote_id'] as String, alias: title);
    } catch (_) {}
  }
  if (!context.mounted) return;
  await connect(context, c['remote_id'] as String,
      password: c['password'] as String?, isFileTransfer: fileTransfer);
}

/// "Client - Site - hostname" of an agent (table row or agent detail), the
/// name used in the titles of every window of a computer
String trmmAgentTitle(Map<String, dynamic> a) => [
      a['client_name'] ?? a['client'],
      a['site_name'],
      a['hostname'],
    ].map((e) => '${e ?? ''}'.trim()).where((e) => e.isNotEmpty).join(' - ');

void trmmSnack(BuildContext context, String msg, {bool error = false}) {
  // no permission: big notice in the middle of the screen
  if (error && isTrmmForbidden(msg)) {
    showTrmmForbidden(context, msg);
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  if (!error) {
    messenger.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
    return;
  }
  // errors: selectable text + "Copy" button, and time to read / copy them
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: SelectableText(msg, style: const TextStyle(color: Colors.white)),
    backgroundColor: Colors.red.shade700,
    duration: const Duration(seconds: 15),
    showCloseIcon: true,
    closeIconColor: Colors.white,
    action: SnackBarAction(
      label: tr('Copy'),
      textColor: Colors.white,
      onPressed: () => trmmCopyText(msg),
    ),
  ));
}

/// copies [text] to the clipboard (error messages)
Future<void> trmmCopyText(String text) => Clipboard.setData(ClipboardData(text: text));

Future<bool> trmmConfirm(BuildContext context, String text, {String? title}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: title == null ? null : Text(title),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('No'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Yes'))),
      ],
    ),
  );
  return r == true;
}

/// Take Control of a TRMM agent. Offers to install the host when missing.
Future<void> takeControlAgent(BuildContext context, String agentId,
    {bool fileTransfer = false}) async {
  final api = TrmmSession.to.api;
  try {
    final state = await api.remoteAccessOfAgent(agentId);
    if (state['status'] != 'ok') {
      if (!context.mounted) return;
      final installing = state['status'] == 'installing';
      if (!installing) {
        final ok = await trmmConfirm(context,
            tr('Remote access is not installed on this computer. Install it now?'),
            title: tr('Remote access'));
        if (!ok || !context.mounted) return;
        await api.provisionRemoteAccess(agentId);
      }
      if (!context.mounted) return;
      final done = await waitProvision(context, agentId);
      if (!done || !context.mounted) return;
    }
    final c = await api.connectAgent(agentId);
    if (!context.mounted) return;
    await _open(context, c, fileTransfer: fileTransfer);
  } on TrmmApiException catch (e) {
    if (context.mounted) trmmSnack(context, e.message, error: true);
  }
}

/// Computers that only have remote access (TRMM agent failed to install).
Future<void> takeControlDevice(BuildContext context, int deviceId,
    {bool fileTransfer = false}) async {
  try {
    final c = await TrmmSession.to.api.connectDevice(deviceId);
    if (!context.mounted) return;
    await _open(context, c, fileTransfer: fileTransfer);
  } on TrmmApiException catch (e) {
    if (context.mounted) trmmSnack(context, e.message, error: true);
  }
}

/// RustDesk Quick Support: the customer reads the ID and temporary password.
Future<void> connectById(BuildContext context, String id, String password) async {
  // the QS executable uses the rendezvous server of the active TRMM
  await applyTrmmRemoteServer();
  if (!context.mounted) return;
  await connect(context, id.replaceAll(' ', ''), password: password.isEmpty ? null : password);
}

/// Dialog that polls the agent until the provision task ends (max ~11 min).
Future<bool> waitProvision(BuildContext context, String agentId) async {
  final api = TrmmSession.to.api;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      Timer? timer;
      var started = DateTime.now();
      return StatefulBuilder(builder: (ctx, setState) {
        timer ??= Timer.periodic(const Duration(seconds: 5), (t) async {
          try {
            final s = await api.remoteAccessOfAgent(agentId);
            if (s['status'] == 'ok') {
              t.cancel();
              if (ctx.mounted) Navigator.pop(ctx, true);
            } else if (s['status'] == 'error' || s['status'] == 'not_installed') {
              t.cancel();
              if (ctx.mounted) {
                Navigator.pop(ctx, false);
                trmmSnack(context, '${tr('Error')}: ${s['last_error'] ?? ''}', error: true);
              }
            } else if (DateTime.now().difference(started).inMinutes >= 11) {
              t.cancel();
              if (ctx.mounted) Navigator.pop(ctx, false);
            }
          } catch (_) {}
        });
        return AlertDialog(
          title: Text(tr('Remote access')),
          content: Row(children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: Text(tr('Installing remote access, this can take a few minutes...'))),
          ]),
          actions: [
            TextButton(
                onPressed: () {
                  timer?.cancel();
                  started = DateTime(0);
                  Navigator.pop(ctx, false);
                },
                child: Text(tr('Close'))),
          ],
        );
      });
    },
  );
  return result == true;
}

/// MeshCentral take control / terminal / files in a window of the app
/// (trmm_webview.dart; the browser only when no webview is available).
Future<void> openMesh(BuildContext context, String agentId, String kind) async {
  try {
    final r = await TrmmSession.to.api.meshUrls(agentId);
    final url = r[kind] as String?;
    if (url == null || url.isEmpty) return;
    // same title as the remote access window: "Client - Site - hostname"
    // (+ what it is for terminal / files)
    final name = [r['client'], r['site'], r['hostname']]
        .map((e) => '${e ?? ''}'.trim())
        .where((e) => e.isNotEmpty)
        .join(' - ');
    final what = switch (kind) {
      'terminal' => ' (${tr('Terminal')})',
      'file' => ' (${tr('File Transfer')})',
      _ => '',
    };
    await openTrmmWebView(url, title: name.isEmpty ? tr('Take Control (MeshCentral)') : '$name$what');
  } on TrmmApiException catch (e) {
    if (context.mounted) trmmSnack(context, e.message, error: true);
  }
}
