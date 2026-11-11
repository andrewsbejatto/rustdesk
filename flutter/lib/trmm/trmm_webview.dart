// MeshCentral pages (take control, terminal, files, quick support) in a
// window of the app (WebView2 on Windows, WebKitGTK on Linux) instead of the
// default browser. Falls back to the browser when no webview is available.
//
// Security: the window only navigates inside the MeshCentral origin of the
// page it was opened with (other links go to the system browser), and each
// TRMM server has its own browser profile, deleted at logout.

import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'trmm_session.dart';

bool? _available;

Future<String> _profileDir(String serverId) async {
  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  final safe = serverId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return '${support.path}${sep}trmm${sep}webview$sep$safe';
}

bool _sameOrigin(Uri a, Uri b) => a.scheme == b.scheme && a.host == b.host && a.port == b.port;

Future<void> openTrmmWebView(String url, {required String title}) async {
  final start = Uri.tryParse(url);
  if (start == null || start.scheme != 'https') return;
  try {
    _available ??= await WebviewWindow.isWebviewAvailable();
  } catch (_) {
    _available = false;
  }
  if (_available != true) {
    await launchUrl(start, mode: LaunchMode.externalApplication);
    return;
  }
  final serverId = TrmmSession.to.server?.id ?? 'default';
  final webview = await WebviewWindow.create(
    configuration: CreateConfiguration(
      title: title,
      windowWidth: 1366,
      windowHeight: 860,
      // no flutter title bar (it would need a hook in main())
      titleBarHeight: 0,
      // WebView2 data outside Program Files, one profile per TRMM server
      userDataFolderWindows: await _profileDir(serverId),
      // MeshCentral never uses them; don't let a page ask for them
      denyCameraAndMicrophone: true,
    ),
  );
  webview.setOnUrlRequestCallback((requested) {
    final u = Uri.tryParse(requested);
    if (requested == 'about:blank' || (u != null && _sameOrigin(u, start))) return true;
    // outside MeshCentral: system browser (http/https only), never in this window
    if (u != null && (u.scheme == 'https' || u.scheme == 'http')) {
      launchUrl(u, mode: LaunchMode.externalApplication);
    }
    // Windows cancels the navigation with false; WebKitGTK ignores the answer
    if (Platform.isLinux) webview.stop();
    return false;
  });
  webview.launch(url);
}

/// logout: forget the MeshCentral session cookies of this server
Future<void> clearTrmmWebViewData(String serverId) async {
  try {
    final dir = Directory(await _profileDir(serverId));
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // in use by an open window: removed at the next logout
  }
}
