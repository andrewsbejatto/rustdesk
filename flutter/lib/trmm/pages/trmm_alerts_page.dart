// Alerts (same "top 10" list as the bell of the web panel).

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../api/trmm_client.dart';
import '../trmm_i18n.dart';
import '../trmm_remote.dart';
import '../trmm_session.dart';

class TrmmAlertsDialog extends StatelessWidget {
  const TrmmAlertsDialog({super.key});

  Color _color(String? severity) {
    switch (severity) {
      case 'error':
        return Colors.red;
      case 'warning':
        return Colors.orange;
      default:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = TrmmSession.to;
    Future<void> act(Future<void> Function() f) async {
      try {
        await f();
      } on TrmmApiException catch (e) {
        if (context.mounted) trmmSnack(context, e.message, error: true);
      }
      s.refreshAlerts();
    }

    return Dialog(
      child: SizedBox(
        width: 620,
        height: 480,
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: Obx(() => Text('${tr('Alerts')} (${s.alertsCount.value})')),
            trailing: IconButton(
                onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ),
          const Divider(height: 1),
          Expanded(
            child: Obx(() => s.alerts.isEmpty
                ? Center(child: Text(tr('No alerts')))
                : ListView(children: [
                    for (final a in s.alerts)
                      ListTile(
                        leading: Icon(Icons.warning_amber, color: _color(a['severity'] as String?)),
                        title: Text('${a['client'] ?? ''} - ${a['site'] ?? ''} - ${a['hostname'] ?? ''}'),
                        subtitle: Text('${a['message'] ?? ''}'),
                        trailing: Wrap(children: [
                          IconButton(
                            tooltip: tr('Snooze 1 day'),
                            icon: const Icon(Icons.snooze),
                            onPressed: () => act(() => s.api.snoozeAlert((a['id'] as num).toInt(), 1)),
                          ),
                          IconButton(
                            tooltip: tr('Resolve'),
                            icon: const Icon(Icons.check),
                            onPressed: () => act(() => s.api.resolveAlert((a['id'] as num).toInt())),
                          ),
                        ]),
                      ),
                  ])),
          ),
        ]),
      ),
    );
  }
}
