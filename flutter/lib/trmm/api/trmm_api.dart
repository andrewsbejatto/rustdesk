// Typed wrappers for the Tactical RMM endpoints used by TRMM Desktop.
// Endpoint map: TacticalRmm/api/tacticalrmm/*/urls.py

import 'trmm_client.dart';

/// Result of POST /v2/checkcreds/
class CheckCredsResult {
  final bool totpRequired;
  /// 180s token returned when the user has no 2FA yet (setup flow)
  final String? setupToken;
  CheckCredsResult(this.totpRequired, this.setupToken);
}

class TrmmApi {
  final TrmmClient client;
  TrmmApi(this.client);

  // ---------------------------------------------------------------- auth
  Future<CheckCredsResult> checkCreds(String username, String password) async {
    final r = await client.post('/v2/checkcreds/', {'username': username, 'password': password});
    if (r is Map && r['totp'] == true) return CheckCredsResult(true, null);
    return CheckCredsResult(false, r is Map ? r['token'] as String? : null);
  }

  /// returns the knox token
  Future<String> login(String username, String password, String totpCode) async {
    final r = await client.post('/v2/login/',
        {'username': username, 'password': password, 'twofactor': totpCode});
    return r['token'] as String;
  }

  /// with the 180s setup token: {username, totp_key, qr_url} or false
  Future<Map<String, dynamic>?> setupTotp() async {
    final r = await client.post('/accounts/users/setup_totp/');
    return r is Map<String, dynamic> ? r : null;
  }

  Future<void> logout() => client.post('/logout/');

  Future<Map<String, dynamic>> dashInfo() async =>
      Map<String, dynamic>.from(await client.get('/core/dashinfo/'));

  Future<void> saveUiPrefs(Map<String, dynamic> prefs) => client.patch('/accounts/users/ui/', prefs);

  // ---------------------------------------------------------------- tree / agents
  Future<List<dynamic>> clients() async => await client.get('/clients/') as List;

  /// monitoringType: server | workstation | null (mixed)
  Future<List<dynamic>> agents({int? clientId, int? siteId, String? monitoringType}) async =>
      await client.get('/agents/', query: {
        if (siteId != null) 'site': siteId else if (clientId != null) 'client': clientId,
        if (monitoringType != null) 'monitoring_type': monitoringType,
      }) as List;

  Future<Map<String, dynamic>> agent(String agentId) async =>
      Map<String, dynamic>.from(await client.get('/agents/$agentId/'));

  Future<void> editAgent(String agentId, Map<String, dynamic> data) =>
      client.put('/agents/$agentId/', data);

  Future<void> setMaintenance(String agentId, bool on) =>
      client.put('/agents/$agentId/', {'maintenance_mode': on});

  Future<dynamic> ping(String agentId) => client.get('/agents/$agentId/ping/');
  Future<dynamic> refreshWmi(String agentId) => client.post('/agents/$agentId/wmi/');
  Future<dynamic> reboot(String agentId) => client.post('/agents/$agentId/reboot/');
  Future<dynamic> rebootLater(String agentId, String datetime) =>
      client.patch('/agents/$agentId/reboot/', {'datetime': datetime});
  Future<dynamic> shutdown(String agentId) => client.post('/agents/$agentId/shutdown/');
  Future<dynamic> wakeOnLan(String agentId) => client.post('/agents/$agentId/wol/');
  Future<dynamic> recover(String agentId, String mode) =>
      client.post('/agents/$agentId/recover/', {'mode': mode});
  Future<dynamic> uninstall(String agentId) => client.delete('/agents/$agentId/');

  Future<dynamic> sendCommand(String agentId,
          {required String cmd,
          required String shell,
          String? customShell,
          int timeout = 30,
          bool runAsUser = false}) =>
      client.post('/agents/$agentId/cmd/', {
        'cmd': cmd,
        'shell': shell,
        'custom_shell': customShell,
        'timeout': timeout,
        'run_as_user': runAsUser,
      });

  Future<dynamic> runScript(String agentId, Map<String, dynamic> data) =>
      client.post('/agents/$agentId/runscript/', data);

  Future<List<dynamic>> scripts({bool community = true}) async =>
      await client.get('/scripts/', query: {'showCommunityScripts': community}) as List;

  // ---------------------------------------------------------------- remote background
  Future<List<dynamic>> processes(String agentId) async =>
      await client.get('/agents/$agentId/processes/') as List;

  Future<dynamic> killProcess(String agentId, int pid) =>
      client.delete('/agents/$agentId/processes/$pid/');

  Future<List<dynamic>> services(String agentId) async =>
      await client.get('/services/$agentId/') as List;

  /// action: start | stop | restart
  Future<dynamic> serviceAction(String agentId, String name, String action) =>
      client.post('/services/$agentId/${Uri.encodeComponent(name)}/', {'sv_action': action});

  /// startType: auto | autodelay | manual | disabled
  Future<dynamic> serviceStartType(String agentId, String name, String startType) =>
      client.put('/services/$agentId/${Uri.encodeComponent(name)}/', {'startType': startType});

  /// logType: Application | System | Security
  Future<List<dynamic>> eventLog(String agentId, String logType, int days) async =>
      await client.get('/agents/$agentId/eventlog/$logType/$days/') as List;

  /// mesh take control / terminal / files urls
  Future<Map<String, dynamic>> meshUrls(String agentId) async =>
      Map<String, dynamic>.from(await client.get('/agents/$agentId/meshcentral/'));

  // ---------------------------------------------------------------- alerts
  Future<Map<String, dynamic>> topAlerts({int top = 10}) async =>
      Map<String, dynamic>.from(await client.patch('/alerts/', {'top': top}));

  Future<void> resolveAlert(int id) => client.put('/alerts/$id/', {'id': id, 'type': 'resolve'});

  Future<void> snoozeAlert(int id, int days) =>
      client.put('/alerts/$id/', {'id': id, 'type': 'snooze', 'snooze_days': days});

  // ---------------------------------------------------------------- remote access (TRMM Desktop)
  Future<List<dynamic>> remoteDevices({int? clientId, int? siteId}) async =>
      await client.get('/remoteaccess/devices/', query: {
        if (siteId != null) 'site': siteId else if (clientId != null) 'client': clientId,
      }) as List;

  Future<Map<String, dynamic>> remoteAccessOfAgent(String agentId) async =>
      Map<String, dynamic>.from(await client.get('/remoteaccess/agents/$agentId/'));

  Future<Map<String, dynamic>> provisionRemoteAccess(String agentId) async =>
      Map<String, dynamic>.from(await client.post('/remoteaccess/agents/$agentId/provision/'));

  Future<Map<String, dynamic>> changeRemotePassword(String agentId) async =>
      Map<String, dynamic>.from(await client.post('/remoteaccess/agents/$agentId/password/'));

  /// {remote_id, password, id_server, relay_server, key, hostname}
  Future<Map<String, dynamic>> connectAgent(String agentId) async =>
      Map<String, dynamic>.from(await client.get('/remoteaccess/agents/$agentId/connect/'));

  Future<Map<String, dynamic>> connectDevice(int deviceId) async =>
      Map<String, dynamic>.from(await client.get('/remoteaccess/devices/$deviceId/connect/'));

  Future<dynamic> bulkProvision(Map<String, dynamic> target) =>
      client.post('/remoteaccess/bulk/provision/', target);

  // ---------------------------------------------------------------- quick support (MeshCentral)
  Future<List<dynamic>> quickSupportSessions() async =>
      await client.get('/quicksupport/sessions/') as List;

  /// {session, control, terminal, file}
  Future<Map<String, dynamic>> quickSupportConnect(String code) async =>
      Map<String, dynamic>.from(await client.post('/quicksupport/connect/', {'code': code}));

  Future<void> quickSupportEnd(String sessionId) =>
      client.post('/quicksupport/sessions/$sessionId/end/');
}
