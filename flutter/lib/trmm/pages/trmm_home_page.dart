// Entry of the TRMM part: login screen or dashboard, depending on the session.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../trmm_i18n.dart';
import '../trmm_native.dart';
import '../trmm_session.dart';
import 'trmm_dashboard_page.dart';
import 'trmm_login_page.dart';

class TrmmHomePage extends StatefulWidget {
  const TrmmHomePage({super.key});

  @override
  State<TrmmHomePage> createState() => _TrmmHomePageState();
}

class _TrmmHomePageState extends State<TrmmHomePage> with AutomaticKeepAliveClientMixin {
  late final TrmmSession session;

  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<TrmmSession>()) {
      session = Get.find<TrmmSession>();
    } else {
      session = Get.put(TrmmSession(), permanent: true);
      session.onNewAlert = (a) => trmmNotify(
          '${tr('Alerts')}: ${a['client'] ?? ''} - ${a['hostname'] ?? ''}',
          '${a['message'] ?? ''}');
      session.onInstallRequest = (s) => trmmNotify(tr('Quick Support'),
          tr('Quick support install request: {0}', ['${s['hostname'] ?? ''}']));
      session.init();
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Obx(() {
      if (!session.ready.value) return const Center(child: CircularProgressIndicator());
      // keyed by server so switching servers rebuilds the screens
      final key = ValueKey('${session.server?.id}-${session.loggedIn.value}');
      return session.loggedIn.value
          ? TrmmDashboardPage(key: key)
          : TrmmLoginPage(key: key);
    });
  }
}
