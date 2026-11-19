// "No permission" (HTTP 403) notices: big and in the middle of the screen,
// a small snackbar at the bottom was easy to miss.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/trmm_client.dart';
import 'trmm_i18n.dart';

/// big centered notice, used inside panels and in the dialog
class TrmmForbiddenView extends StatelessWidget {
  final String message;
  const TrmmForbiddenView(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detail = tr(message);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 64, color: cs.error),
            const SizedBox(height: 16),
            Text(tr('Permission denied'),
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(color: cs.error, fontWeight: FontWeight.w600)),
            if (detail != tr('Permission denied')) ...[
              const SizedBox(height: 12),
              Text(detail, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// error inside a panel: the big notice for 403, plain text otherwise
Widget trmmErrorView(BuildContext context, String message, {bool colored = true}) {
  if (isTrmmForbidden(message)) return TrmmForbiddenView(message);
  // selectable, with a copy button: error messages are often sent to support
  return Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SelectableText(message,
              style: colored ? TextStyle(color: Theme.of(context).colorScheme.error) : null),
        ),
        IconButton(
          tooltip: tr('Copy'),
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: message)),
        ),
      ]),
    ),
  );
}

bool _dialogOpen = false;

/// modal notice in the middle of the screen (one at a time)
Future<void> showTrmmForbidden(BuildContext context, String message) async {
  if (_dialogOpen) return;
  _dialogOpen = true;
  try {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: SizedBox(width: 420, child: TrmmForbiddenView(message)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: Text('OK')),
          ),
        ],
      ),
    );
  } finally {
    _dialogOpen = false;
  }
}
