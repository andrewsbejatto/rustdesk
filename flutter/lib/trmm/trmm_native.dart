// OS integration of the TRMM Desktop app: alert notifications and start with
// the system. No extra flutter plugins: Windows notifications are shown by
// the app's own executable (`--trmm-notify`, see src/core_main.rs).

import 'dart:convert';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const _runValue = 'TRMMDesktop';

/// Computer managed by Tactical RMM (host installed by the TRMM server): the
/// flag file is written by the install script (remoteaccess/scripts.py) and
/// the TRMM screens are hidden there.
bool isTrmmManagedHost() {
  try {
    if (Platform.isWindows) {
      final pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      return File('$pd${Platform.pathSeparator}TRMMDesktop${Platform.pathSeparator}host').existsSync();
    }
    if (Platform.isLinux) return File('/etc/trmmdesktop/host').existsSync();
  } catch (_) {}
  return false;
}

/// TRMM Desktop has no tray icon (hide-tray), so closing the main window must
/// end the app: RustDesk would only hide it and keep an invisible instance
/// running (a new start would just show that old instance again). With remote
/// session windows open, the app ends when the last one is closed.
bool trmmQuitWhenAlone = false;

/// hook run just before the process ends (tray icon removal)
Future<void> Function()? trmmBeforeQuit;

/// quick support: tells Tactical RMM that the session ended (a network call,
/// so it gets more time than the other hooks)
Future<void> Function()? trmmQsBeforeQuit;

Future<void> trmmQuitApp() async {
  // windowManager.destroy() may never answer (flutter#66631) and the process
  // stayed alive without a window: hide quickly and end the process, as
  // RustDesk does (SystemNavigator.pop + exit)
  Future<void> quick(Future<void> Function() f) async {
    try {
      await f().timeout(const Duration(milliseconds: 600));
    } catch (_) {}
  }

  if (trmmBeforeQuit != null) await quick(trmmBeforeQuit!);
  if (trmmQsBeforeQuit != null) {
    try {
      await trmmQsBeforeQuit!().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
  await quick(() => windowManager.hide());
  exit(0);
}

/// system notification (Windows toast / Linux notify-send)
Future<void> trmmNotify(String title, String text) async {
  try {
    if (Platform.isWindows) {
      // base64: an alert text can never be read as another command line flag
      String b(String v) => base64Url.encode(utf8.encode(v));
      await Process.start(Platform.resolvedExecutable, ['--trmm-notify', b(title), b(text)],
          mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('notify-send', ['-a', 'TRMM Desktop', title, text],
          mode: ProcessStartMode.detached);
    }
  } catch (_) {
    // no notification daemon: ignore
  }
}

File _linuxAutostart() {
  final home = Platform.environment['HOME'] ?? '';
  return File('$home/.config/autostart/trmmdesktop.desktop');
}

Future<bool> isStartWithSystem() async {
  try {
    if (Platform.isWindows) {
      final r = await Process.run('reg', ['query', _runKey, '/v', _runValue]);
      return r.exitCode == 0;
    }
    if (Platform.isLinux) return _linuxAutostart().existsSync();
  } catch (_) {}
  return false;
}

/// starts the app minimized when the user logs in
Future<void> setStartWithSystem(bool on) async {
  final exe = Platform.resolvedExecutable;
  if (Platform.isWindows) {
    if (on) {
      await Process.run(
          'reg', ['add', _runKey, '/v', _runValue, '/t', 'REG_SZ', '/d', '"$exe" --trmm-minimized', '/f']);
    } else {
      await Process.run('reg', ['delete', _runKey, '/v', _runValue, '/f']);
    }
  } else if (Platform.isLinux) {
    final f = _linuxAutostart();
    if (on) {
      await f.parent.create(recursive: true);
      await f.writeAsString('[Desktop Entry]\nType=Application\nName=TRMM Desktop\n'
          'Exec="$exe" --trmm-minimized\nX-GNOME-Autostart-enabled=true\n');
    } else if (f.existsSync()) {
      await f.delete();
    }
  }
}
