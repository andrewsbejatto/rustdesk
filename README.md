# TRMM Desktop – a RustDesk fork for Tactical RMM (`trmm-desktop`)

**TRMM Desktop** is an **unofficial fork** of [**RustDesk**](https://github.com/rustdesk/rustdesk)
that turns it into a desktop client for [Tactical RMM](https://github.com/amidaware/tacticalrmm)
with remote control built in. It is not affiliated with, endorsed or supported by
the RustDesk team or by AmidaWare LLC (Tactical RMM). For RustDesk itself, see the
[original repository](https://github.com/rustdesk/rustdesk) and its
[original README](https://github.com/rustdesk/rustdesk#readme).

- Branch `trmm-desktop`: **TRMM Desktop 1.0.0**, based on **RustDesk 1.5.1**.
- It needs the Tactical RMM backend from
  [andrewsbejatto/tacticalrmm, branch `trmm-custom`](https://github.com/andrewsbejatto/tacticalrmm/tree/trmm-custom)
  (the `remoteaccess`, `quicksupport` and `recordings` apps).
- `libs/hbb_common` points to
  [andrewsbejatto/hbb_common, branch `trmm-desktop`](https://github.com/andrewsbejatto/hbb_common/tree/trmm-desktop).

It was built by an MSP for its own daily use and is shared for the community.

> [!Caution]
> **Misuse disclaimer (from RustDesk, applies here too):** the developers do not
> condone or support any unethical or illegal use of this software. Unauthorized
> access, control or invasion of privacy is strictly against our guidelines.

## One app, three roles

The same executable works as:

1. **Technician app.** It opens the Tactical RMM screens instead of the
   RustDesk home page.
2. **Managed host.** It is installed silently on the managed computers by
   Tactical RMM, through the Tactical agent:
   - permanent password only;
   - hidden tray and connection window;
   - no auto-update;
   - its own service and folders, so it does not clash with a regular RustDesk
     install.
3. **Quick support.** Executable name containing `-qs`, e.g. `TRMM-Suporte.exe`,
   downloaded from Tactical with a configuration appended to the file:
   - the configuration is signed with the server's Ed25519 key;
   - the app only accepts the keys compiled into its build;
   - RustDesk's "config in the file name" is disabled.

## Tactical RMM in the app (Flutter, `flutter/lib/trmm`)

- **Servers:** login with 2FA, several Tactical RMM servers, tokens kept
  encrypted (DPAPI on Windows, a 600-mode file on Linux).
- **Agents:**
  - client/site tree with servers / workstations / mixed views;
  - agent list with search, status and alert icons;
  - agent tabs: summary, checks, tasks, patches, software, history, notes,
    assets, pending actions, audit, debug.
- **Agent actions:** run script or command, reboot / shutdown, Wake-on-LAN,
  maintenance mode, edit, remove, and the remote access ones: install,
  repair, change password.
- **Remote Background:** terminal, processes, services, event log, registry.
  There is also a native file browser (Tactical agent 2.12+).
- **Take Control:**
  - opens **inside the app** with the RustDesk engine, with file transfer;
  - offers to install the host when the computer doesn't have it yet;
  - MeshCentral pages (desktop, terminal, files) open in an embedded WebView
    limited to the MeshCentral address, with one profile per server.
- **Bulk install / update of the remote access:** right click on all
  clients, a client or a site. The server queues it and installs 3 computers
  at a time.
- **Quick Support:**
  - MeshCentral by code;
  - TRMM Desktop: the customer's session appears as a card, double-click to
    connect;
  - approve or deny "install permanent access" requests.
- **Alerts:** tray notifications with resolve/snooze. Also start with the
  system and close to tray.
- **Session recordings:** list and play the recordings stored in S3.
- **Install agent:** the Tactical agent alone or combined with remote access.
- Brazilian Portuguese and English, following the Tactical user's language.

## Remote session recording (host side)

Remote sessions are end-to-end encrypted: the relay server can't see the
screen. So when Tactical enables recording, the **managed host** (and the
quick support executable) records the incoming session:
- `src/hbbs_http/record_upload.rs` streams the video to Tactical RMM
  **during** the session, over https with a per-device token;
- the local file is deleted after the upload, and leftovers are sent again
  when the service starts;
- the CLI `--record-config <file>` is used by the provisioning scripts.

## Building

Build it like RustDesk with Flutter (`python build.py --flutter`; see the
[original README](https://github.com/rustdesk/rustdesk#readme) for the
dependencies: Flutter 3.24.5, vcpkg libraries, LLVM). One extra environment
variable is required:

```bash
# public keys printed by `python manage.py remoteaccess_signing_key` on each
# Tactical RMM server, comma separated
export TRMM_TRAILER_KEYS="key1=,key2="
```

Without it, the quick support executable ignores the configuration it was
downloaded with. The technician app and the managed hosts work without it.

The server address and key are **not** compiled in:
- the technician app gets them from Tactical after login;
- the hosts get them from the provisioning script.

## License

Like RustDesk, this fork is licensed under the **GNU AGPL-3.0** (see
[LICENCE](LICENCE)). Its full source code is published here. The app uses its
own name and icons and does not use the RustDesk brand. "Tactical RMM" is a
trade mark of AmidaWare LLC.

---

### Português (resumo)

Fork não oficial do [RustDesk](https://github.com/rustdesk/rustdesk) que vira
o app **TRMM Desktop**: as telas do Tactical RMM com o acesso remoto do
RustDesk dentro do mesmo programa. É ao mesmo tempo:
- o app do técnico;
- o host silencioso dos computadores gerenciados;
- o Suporte Rápido, com configuração assinada.

Grava as sessões e envia ao Tactical RMM. Precisa do backend do branch
`trmm-custom` do fork `andrewsbejatto/tacticalrmm`. Licença AGPL-3.0. Não tem
relação com a equipe do RustDesk nem com a AmidaWare.
