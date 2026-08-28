# ERealm

ERealm is an interactive Bash script for installing and managing `realm` port forwarding on Linux servers.


## Features

- Install the pinned `realm` release automatically
- Uninstall `realm` and clean related files
- Add and delete forwarding rules
- Show service status, config path, log path, BBR status, and current forwarding rules
- Shortcut command `realm`

## Usage

```bash
bash <(curl -Ls https://raw.githubusercontent.com/flyto23/Erealm/main/install.sh)
```

## Menu

```text
1. Install Realm
2. Uninstall Realm
3. Add Forwarding Rule
4. Delete Forwarding Rule
5. Uninstall Script
0. Exit
```

## What The Script Manages

- `realm` binary: `/usr/local/bin/realm`
- shortcut command: `/usr/local/sbin/realm`
- config directory: `/etc/realm`
- config file: `/etc/realm/config.toml`
- forwarding list: `/etc/realm/forwards.list`
- log file: `/var/log/realm/realm.log`
- systemd service: `/etc/systemd/system/realm.service`

## Notes

- The script currently installs Realm `v2.7.0`.
- Forwarding rules are validated before they are written.
- The repository stores the installer as `install.sh`, while the installed shortcut command is `realm`.

## License

Use at your own risk.
