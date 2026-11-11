// Global state of the TRMM part of the app: servers, login, dashinfo flags
// and the alert watcher (tray notifications).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'api/trmm_api.dart';
import 'api/trmm_client.dart';
import 'store/server_store.dart';
import 'trmm_i18n.dart';
import 'trmm_remote.dart';
import 'trmm_webview.dart';

enum LoginStep { credentials, totp, setupTotp, done }

class TrmmSession extends GetxController {
  static TrmmSession get to => Get.find<TrmmSession>();

  final store = ServerStore();
  final ready = false.obs;
  final loggedIn = false.obs;
  final dashInfo = <String, dynamic>{}.obs;
  final alerts = <Map<String, dynamic>>[].obs;
  final alertsCount = 0.obs;

  TrmmApi? _api;
  Timer? _alertTimer;
  final Set<int> _seenAlerts = {};

  /// called for each new alert (tray notification)
  void Function(Map<String, dynamic> alert)? onNewAlert;

  /// called for each new quick support "install permanent access" request
  void Function(Map<String, dynamic> session)? onInstallRequest;
  final Set<String> _seenInstallRequests = {};
  int _qsTick = 0;

  TrmmApi get api {
    final a = _api;
    if (a == null) throw StateError('no server');
    return a;
  }

  TrmmServer? get server => store.active;
  bool get canUseRemoteAccess => dashInfo['can_use_remote_access'] == true;
  bool get canUseQuickSupport => dashInfo['can_use_quick_support'] == true;
  String get language => (dashInfo['language'] as String?) ?? '';

  Future<void> init() async {
    await store.load();
    final s = store.active;
    if (s != null) {
      _useServer(s);
      if (s.loggedIn) {
        try {
          await _afterLogin();
        } catch (e) {
          debugPrint('trmm: stored session not valid: $e');
          loggedIn.value = false;
        }
      }
    }
    ready.value = true;
  }

  void _useServer(TrmmServer s) {
    _api?.client.close();
    final client = TrmmClient(s.apiUrl, token: s.token);
    client.onUnauthorized = _onUnauthorized;
    _api = TrmmApi(client);
  }

  Future<void> selectServer(String id) async {
    _stopAlerts();
    store.activeId = id;
    await store.save();
    loggedIn.value = false;
    final s = store.active;
    if (s == null) return;
    _useServer(s);
    if (s.loggedIn) {
      try {
        await _afterLogin();
      } catch (_) {
        loggedIn.value = false;
      }
    }
  }

  // ---------------------------------------------------------------- login
  String? _pendingUser;
  String? _pendingPassword;
  bool _pendingSave = false;

  /// step 1: returns what the login screen must ask next.
  /// [savePassword]: keep the password for the next logins (saved only
  /// after the login succeeds)
  Future<LoginStep> checkCredentials(String username, String password,
      {bool savePassword = false}) async {
    // a new login never sends the old (maybe expired) token: knox rejects
    // every request with an invalid token, even the login itself
    api.client.token = null;
    final r = await api.checkCreds(username, password);
    _pendingUser = username;
    _pendingPassword = password;
    _pendingSave = savePassword;
    if (r.totpRequired) return LoginStep.totp;
    // no 2FA yet: the 180s token allows only the TOTP setup
    api.client.token = r.setupToken;
    return LoginStep.setupTotp;
  }

  /// first time 2FA: {totp_key, qr_url}
  Future<Map<String, dynamic>?> setupTotp() => api.setupTotp();

  /// step 2: TOTP code
  Future<void> verifyTotp(String code) async {
    final token = await api.login(_pendingUser!, _pendingPassword!, code.trim());
    final s = store.active!;
    s.token = token;
    s.username = _pendingUser!;
    s.password = _pendingSave ? _pendingPassword : null;
    api.client.token = token;
    _pendingPassword = null;
    await store.save();
    await _afterLogin();
  }

  Future<void> _afterLogin() async {
    final info = await api.dashInfo();
    dashInfo.assignAll(info);
    setTrmmLanguage(language);
    loggedIn.value = true;
    if (canUseRemoteAccess) await applyTrmmRemoteServer();
    _startAlerts();
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } catch (_) {}
    final id = server?.id;
    _clearSession();
    // MeshCentral cookies of the embedded browser go away with the session
    if (id != null) await clearTrmmWebViewData(id);
  }

  /// 401: expired/invalid token. Forget it even when not logged in yet
  /// (stored session restored at startup), otherwise it keeps being sent.
  void _onUnauthorized() => _clearSession();

  void _clearSession() {
    _stopAlerts();
    final s = store.active;
    if (s != null) {
      s.token = null;
      store.save();
    }
    api.client.token = null;
    dashInfo.clear();
    loggedIn.value = false;
  }

  // ---------------------------------------------------------------- alerts (same poll as the web panel)
  void _startAlerts() {
    _stopAlerts();
    _seenAlerts.clear();
    _pollAlerts(notify: false);
    _alertTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      // alerts every 60 s, quick support install requests every 20 s
      if (_qsTick++ % 3 == 0) _pollAlerts();
      _pollInstallRequests();
    });
  }

  void _stopAlerts() {
    _alertTimer?.cancel();
    _alertTimer = null;
  }

  Future<void> refreshAlerts() => _pollAlerts(notify: false);

  Future<void> _pollInstallRequests() async {
    if (!loggedIn.value || !canUseQuickSupport) return;
    try {
      final r = await api.quickSupportSessions();
      for (final s in r) {
        if (s['install_status'] == 'requested' && _seenInstallRequests.add('${s['id']}')) {
          onInstallRequest?.call(Map<String, dynamic>.from(s));
        }
      }
    } catch (_) {}
  }

  Future<void> _pollAlerts({bool notify = true}) async {
    if (!loggedIn.value) return;
    try {
      final r = await api.topAlerts();
      final list = [for (final a in (r['alerts'] as List? ?? [])) Map<String, dynamic>.from(a)];
      alerts.assignAll(list);
      alertsCount.value = (r['alerts_count'] as num?)?.toInt() ?? list.length;
      for (final a in list) {
        final id = (a['id'] as num).toInt();
        if (_seenAlerts.add(id) && notify) onNewAlert?.call(a);
      }
    } on TrmmApiException catch (e) {
      // 403: user can't list alerts, stop polling
      if (e.forbidden) _stopAlerts();
    } catch (_) {
      // offline: try again on the next tick
    }
  }

  @override
  void onClose() {
    _stopAlerts();
    _api?.client.close();
    super.onClose();
  }
}
