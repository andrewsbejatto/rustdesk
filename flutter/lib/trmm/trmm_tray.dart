// Tray icon of the technician app and the "close" choice: go to the system
// tray (keeps running: alerts, quick support requests) or end the app.
// Managed computers and the quick support window always end on close.

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'trmm_i18n.dart';
import 'trmm_native.dart';

/// local option: "" (ask) | "tray" | "quit"
const kTrmmCloseAction = 'trmm-close-action';

String get trmmCloseAction => bind.mainGetLocalOption(key: kTrmmCloseAction);

Future<void> setTrmmCloseAction(String v) => bind.mainSetLocalOption(key: kTrmmCloseAction, value: v);

bool get _isTechnicianApp => !bind.isIncomingOnly() && !isTrmmManagedHost();

class _Tray with TrayListener {
  bool shown = false;

  Future<void> show() async {
    if (shown) return;
    // remove the icon when the app ends (no ghost icon in the tray)
    trmmBeforeQuit = hide;
    await trayManager.setIcon(isWindows ? 'assets/trmm_tray.ico' : 'assets/trmm_tray.png');
    try {
      await trayManager.setToolTip('TRMM Desktop');
    } catch (_) {} // not on every linux desktop
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: tr('Open TRMM Desktop')),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: tr('Quit')),
    ]));
    trayManager.addListener(this);
    shown = true;
  }

  Future<void> hide() async {
    if (!shown) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
    shown = false;
  }

  @override
  void onTrayIconMouseDown() => trmmRestoreFromTray();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') trmmRestoreFromTray();
    if (menuItem.key == 'quit') trmmQuitApp();
  }
}

final _tray = _Tray();

/// hides the main window and shows the tray icon
Future<void> trmmHideToTray() async {
  trmmQuitWhenAlone = false;
  await _tray.show();
  await windowManager.hide();
}

Future<void> trmmRestoreFromTray() async {
  await windowManager.show();
  await windowManager.focus();
  await rustDeskWinManager.registerActiveWindow(kMainWindowId);
  await _tray.hide();
}

/// Main window close button. Returns false when the close was cancelled.
Future<bool> trmmOnMainWindowClose(BuildContext context) async {
  var action = 'quit';
  if (_isTechnicianApp) {
    action = trmmCloseAction;
    if (action != 'tray' && action != 'quit') {
      if (!context.mounted) return false;
      action = await _ask(context) ?? 'cancel';
    }
  }
  if (action == 'cancel') return false;
  if (action == 'tray') {
    await trmmHideToTray();
    return true;
  }
  // end the app, after the remote session windows if any
  trmmQuitWhenAlone = true;
  await windowManager.hide();
  if (!await _sessionWindowsVisible()) await trmmQuitApp();
  // safety net: a session window that ends without telling the main window
  // (peer disconnected, error) must not keep a hidden app running
  var busy = false;
  Timer.periodic(const Duration(seconds: 3), (t) async {
    if (!trmmQuitWhenAlone) {
      t.cancel(); // restored from the tray / reopened
      return;
    }
    if (busy) return;
    busy = true;
    try {
      await trmmQuitIfAlone();
    } finally {
      busy = false;
    }
  });
  return true;
}

/// Session windows still on screen. RustDesk keeps closed session windows
/// hidden for reuse and its active window list (getActiveWindows) can miss a
/// hide event, which kept a hidden app running: the real state is checked.
Future<bool> _sessionWindowsVisible() async {
  try {
    for (final id in await DesktopMultiWindow.getAllSubWindowIds()) {
      final hidden =
          await WindowController.fromWindowId(id).isHidden().timeout(const Duration(seconds: 2));
      if (!hidden) return true;
    }
    return false;
  } catch (_) {
    return rustDeskWinManager.getActiveWindows().any((id) => id != kMainWindowId);
  }
}

/// Main window closed with "quit": ends the app once no session window is
/// visible. Opening the app again (main window shown) cancels it.
Future<void> trmmQuitIfAlone() async {
  if (!trmmQuitWhenAlone) return;
  if (await windowManager.isVisible()) {
    trmmQuitWhenAlone = false;
    return;
  }
  if (!await _sessionWindowsVisible()) await trmmQuitApp();
}

Future<String?> _ask(BuildContext context) async {
  var remember = false;
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(tr('Close TRMM Desktop')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Keep running in the system tray (alerts and quick support requests) or quit the app?')),
          const SizedBox(height: 12),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? false),
            title: Text(tr('Remember my choice')),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: Text(tr('Cancel'))),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, 'quit'), child: Text(tr('Quit'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'tray'), child: Text(tr('Minimize to tray'))),
        ],
      ),
    ),
  );
  if (remember && (r == 'tray' || r == 'quit')) await setTrmmCloseAction(r!);
  return r;
}
