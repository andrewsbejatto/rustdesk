// Server selection + login (username/password -> TOTP, or first time TOTP setup).

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api/trmm_client.dart';
import '../store/server_store.dart';
import '../trmm_i18n.dart';
import '../trmm_session.dart';

class TrmmLoginPage extends StatefulWidget {
  const TrmmLoginPage({super.key});

  @override
  State<TrmmLoginPage> createState() => _TrmmLoginPageState();
}

class _TrmmLoginPageState extends State<TrmmLoginPage> {
  final session = TrmmSession.to;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  LoginStep _step = LoginStep.credentials;
  Map<String, dynamic>? _totpSetup;
  bool _busy = false;
  bool _savePass = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fillSaved();
  }

  /// username and, when saved, password of the active server
  void _fillSaved() {
    final s = session.server;
    _user.text = s?.username ?? '';
    _pass.text = s?.password ?? '';
    _savePass = s?.password != null;
  }

  /// unchecking "Save password" forgets the saved password at once
  Future<void> _setSavePass(bool v) async {
    setState(() => _savePass = v);
    final s = session.server;
    if (!v && s != null && s.password != null) {
      s.password = null;
      await session.store.save();
    }
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on TrmmApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _submitCredentials() => _run(() async {
        final step =
            await session.checkCredentials(_user.text.trim(), _pass.text, savePassword: _savePass);
        if (step == LoginStep.setupTotp) {
          _totpSetup = await session.setupTotp();
        }
        _code.clear();
        _step = step;
      });

  Future<void> _submitCode() => _run(() async {
        await session.verifyTotp(_code.text);
        _pass.clear();
      });

  Future<void> _editServer([TrmmServer? s]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => ServerDialog(server: s));
    if (saved == true) {
      if (s == null) await session.selectServer(session.store.servers.last.id);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = session.store.servers;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: servers.isEmpty ? _noServer() : _form(servers),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _noServer() => Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.dns_outlined, size: 48),
        const SizedBox(height: 12),
        Text(tr('Add a Tactical RMM server to start'), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: () => _editServer(), icon: const Icon(Icons.add), label: Text(tr('Add server'))),
      ]);

  Widget _form(List<TrmmServer> servers) {
    final active = session.server!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('TRMM Desktop', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: active.id,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Server')),
              items: [
                for (final s in servers)
                  DropdownMenuItem(value: s.id, child: Text(s.name, overflow: TextOverflow.ellipsis))
              ],
              onChanged: _busy
                  ? null
                  : (id) async {
                      if (id == null) return;
                      await session.selectServer(id);
                      setState(() {
                        _step = LoginStep.credentials;
                        _fillSaved();
                      });
                    },
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              if (v == 'add') _editServer();
              if (v == 'edit') _editServer(active);
              if (v == 'remove') {
                session.store.remove(active.id);
                await session.store.save();
                final next = session.store.active;
                if (next != null) await session.selectServer(next.id);
                setState(() {});
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'add', child: Text(tr('Add server'))),
              PopupMenuItem(value: 'edit', child: Text(tr('Edit server'))),
              PopupMenuItem(value: 'remove', child: Text(tr('Remove server'))),
            ],
          ),
        ]),
        const SizedBox(height: 20),
        ..._stepFields(),
        if (_error != null) ...[
          const SizedBox(height: 12),
          SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 20),
        Row(children: [
          if (_step != LoginStep.credentials)
            TextButton(
                onPressed: _busy ? null : () => setState(() => _step = LoginStep.credentials),
                child: Text(tr('Back'))),
          const Spacer(),
          FilledButton(
            onPressed: _busy ? null : (_step == LoginStep.credentials ? _submitCredentials : _submitCode),
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_step == LoginStep.credentials ? tr('Next') : tr('Login')),
          ),
        ]),
      ],
    );
  }

  List<Widget> _stepFields() {
    switch (_step) {
      case LoginStep.credentials:
        return [
          TextField(
            controller: _user,
            decoration: InputDecoration(labelText: tr('Username')),
            autofocus: _user.text.isEmpty,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: InputDecoration(labelText: tr('Password')),
            autofocus: _user.text.isNotEmpty,
            onSubmitted: (_) => _submitCredentials(),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _savePass,
            onChanged: _busy ? null : (v) => _setSavePass(v ?? false),
            title: Text(tr('Save password')),
            subtitle: Text(tr('save_password_help')),
          ),
        ];
      case LoginStep.setupTotp:
        final qr = _totpSetup?['qr_url'] as String?;
        return [
          Text(tr('Set up two-factor authentication'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(tr('Scan the QR code with your authenticator app, then enter the code')),
          if (qr != null)
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.symmetric(vertical: 12),
                child: QrImageView(data: qr, size: 200),
              ),
            ),
          if (_totpSetup?['totp_key'] != null) SelectableText('${tr('Key')}: ${_totpSetup!['totp_key']}'),
          _codeField(),
        ];
      default:
        return [
          Text(tr('Enter the 6 digit code of your authenticator app')),
          _codeField(),
        ];
    }
  }

  Widget _codeField() => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: TextField(
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: InputDecoration(labelText: tr('Two-factor code')),
        onSubmitted: (_) => _submitCode(),
      ));
}

class ServerDialog extends StatefulWidget {
  final TrmmServer? server;
  const ServerDialog({super.key, this.server});

  @override
  State<ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<ServerDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.server?.name ?? '');
  late final _api = TextEditingController(text: widget.server?.apiUrl ?? 'https://');
  late final _web = TextEditingController(text: widget.server?.webUrl ?? '');

  String? _url(String? v, {bool optional = false}) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return optional ? null : tr('Required');
    final u = Uri.tryParse(s);
    if (u == null || u.scheme != 'https' || u.host.isEmpty) {
      return tr('Invalid URL');
    }
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final store = TrmmSession.to.store;
    final api = _api.text.trim().replaceAll(RegExp(r'/+$'), '');
    final name = _name.text.trim().isEmpty ? Uri.parse(api).host : _name.text.trim();
    final s = widget.server;
    if (s == null) {
      store.add(name: name, apiUrl: api, webUrl: _web.text.trim());
    } else {
      final changed = s.apiUrl != api;
      s
        ..name = name
        ..apiUrl = api
        ..webUrl = _web.text.trim();
      if (changed) {
        s.token = null;
        s.password = null; // never sent to another server
      }
    }
    await store.save();
    if (s != null) await TrmmSession.to.selectServer(s.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.server == null ? tr('Add server') : tr('Edit server')),
        content: SizedBox(
          width: 380,
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(controller: _name, decoration: InputDecoration(labelText: tr('Name'))),
              const SizedBox(height: 16),
              TextFormField(
                controller: _api,
                decoration: InputDecoration(labelText: tr('API URL'), hintText: 'https://api.example.com'),
                validator: _url,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _web,
                decoration: InputDecoration(
                    labelText: tr('Dashboard URL (optional)'), hintText: 'https://rmm.example.com'),
                validator: (v) => _url(v, optional: true),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: _save, child: Text(tr('Save'))),
        ],
      );
}
