# Nextcloud / WebDAV Auto-Mount (davfs2 + systemd user service)

A small set of Bash scripts that mount a Nextcloud (or other WebDAV) share
at the **user level** via `davfs2`, replace chosen folders in your home
directory with symlinks into the mounted drive, and keep working locally
(with a sync-back via `rsync`) when the drive is unmounted or unreachable.
Everything runs as a `systemd --user` service with health checks and
automatic restarts.

- **`install.sh`** – interactive installer. Sets up `davfs2`, asks for your
  server details and folder mappings, writes the config/secrets files, and
  creates + enables the systemd user service.
- **`drivemount.sh`** (v1.2) – the main script. Mounts/unmounts the drive,
  creates the symlinks, and syncs data.
- **`drivemount_wrapper.sh`** – thin wrapper used as the systemd
  `ExecStart`. Calls `drivemount.sh`, reports readiness via
  `systemd-notify`, and polls `--health-check` in a loop.

> Currently optimized for **Nextcloud**. Other WebDAV providers may need
> manual adjustment (the WebDAV path is hardcoded to
> `/remote.php/webdav`).

## How it fits together

```mermaid
flowchart TD
    S[systemd --user service] --> W[drivemount_wrapper.sh]
    W -->|on start| R[drivemount.sh --run]
    R --> M{Already mounted?}
    M -- yes --> Done1[exit 0]
    M -- no --> Mount[mount via davfs2 / fstab entry]
    Mount --> Sync[rsync local shadow dirs to remote dirs]
    Sync --> Link[symlink local dirs to remote dirs]
    W -->|every 30s| HC[drivemount.sh --health-check]
    HC -- ok --> Notify[systemd-notify: healthy]
    HC -- fail --> Fail[systemd-notify: unhealthy, exit]
    Fail --> Restart[systemd restarts the service]
    Stop[service stop / Ctrl-C] --> Destroy[drivemount.sh --destroy]
    Destroy --> Relink[symlink local dirs back to shadow dirs]
    Destroy --> Umount[umount the drive]
```

## Prerequisites

- A Debian/Ubuntu-based system with `apt` and `sudo` access
- `systemd` with user services available (default on most modern desktop
  distros)
- A Nextcloud (or compatible WebDAV) server and login/app-password
- `curl` (for health checks) and `rsync` (for syncing local changes back)
- `git`, to clone the repository

## Installation

### Option 1: Git clone

Clone the repository:

```bash
git clone https://github.com/<USERNAME>/<REPOSITORY>.git
cd <REPOSITORY>
```

Make the installation script executable:

```bash
chmod +x install.sh
```

Start the installation:

```bash
./install.sh
```

---

### Option 2: GitHub ZIP download

Download the repository as a ZIP file.

Unzip the ZIP file:

```bash
unzip <REPOSITORY>.zip
cd <REPOSITORY>
```

Make the installation script executable:

```bash
chmod +x install.sh
```

Start the installation:

```bash
./install.sh
```

---


1. Ask for confirmation if you run it as root (it's meant for **per-user**
   installs, not root).
2. Install `davfs2` via `apt` and add your user to the `davfs2` group.
3. Reconfigure `davfs2` (`davfs2/suid_file` → true) so non-root users can
   mount.
4. Create `~/.local/bin` and `~/.local/share` if they don't exist.
5. Prompt you interactively for:
   - Your Nextcloud **domain** (e.g. `cloud.example.com`)
   - Your **username** and **password** for that server
   - One or more **folder mappings**: a *remote* directory (path inside
     your Nextcloud, relative to the WebDAV root) and the *local* folder
     name it should appear as in your `$HOME`. You can add as many
     mappings as you like.
6. Write your credentials to `~/.davfs2/secrets` (`chmod 600`).
7. Write `~/.local/share/drive_mount_config.sh` with your settings (see
   below).
8. Append a `noauto` mount entry for the drive to `/etc/fstab`.
9. Create `/etc/systemd/user/<username>@<domain>.service`.
10. Copy `drivemount.sh` and `drivemount_wrapper.sh` into `~/.local/bin/`.
11. Create the mountpoint directory `~/<username>@<domain>`.
12. Reload the user systemd daemon, then **enable and start** the new
    service.

### About the davfs2 group

Adding your user to the `davfs2` group only takes effect in **new** login
sessions. If the service fails on its first run with a permissions error,
log out and back in (or reboot) and try again:

```bash
systemctl --user restart <username>@<domain>.service
```

### Keep the service running after logout (optional)

User services normally stop when you log out. To allow it to keep running
(e.g. on a headless box), enable lingering for your user once:

```bash
sudo loginctl enable-linger "$USER"
```

## 3. Verify it worked

```bash
systemctl --user status "<username>@<domain>.service"
journalctl --user -u "<username>@<domain>.service" -f
```

You should see your mapped folders in `$HOME` as symlinks pointing into
`~/<username>@<domain>/...`.

## Using `drivemount.sh` manually

Once installed, you can call the main script directly instead of (or in
addition to) the systemd service:

| Flag | Action |
|---|---|
| *(no flag)* | Same as `--run` |
| `-r`, `--run` | Mounts the drive (if not already mounted), syncs local changes up, then symlinks local folders to the remote drive |
| `-d`, `--destroy` | Symlinks local folders back to local "shadow" copies and unmounts the drive |
| `-s`, `--sync` | Runs an `rsync` of the local shadow folders up to the remote drive |
| `--dry-sync` | Same as `--sync`, but as a dry run (`-auvn`, no changes made) |
| `--health-check` | Checks reachability of the remote server (used by the wrapper script's polling loop) |
| `-v`, `--version` | Prints the script version |
| `-h`, `--help` | Shows usage |

Example:

```bash
~/.local/bin/drivemount.sh --dry-sync
```

## Files written / used by these scripts

| Path | Created by | Purpose |
|---|---|---|
| `~/.davfs2/secrets` | `install.sh` | WebDAV URL + username + password (`chmod 600`) |
| `~/.local/share/drive_mount_config.sh` | `install.sh` | `mountinfo` and `dirs` associative arrays, sourced by `drivemount.sh` |
| `/etc/fstab` | `install.sh` | `noauto` entry describing the WebDAV mount |
| `/etc/systemd/user/<username>@<domain>.service` | `install.sh` | The user-level systemd unit |
| `~/.local/bin/drivemount.sh`, `drivemount_wrapper.sh` | `install.sh` (copied from the repo) | The scripts actually invoked by systemd |
| `~/<username>@<domain>/` | `install.sh` | The mountpoint for the WebDAV share |
| `~/.<localdir-lowercased>/` | `drivemount.sh` | "Shadow" folder holding your data locally while the drive is unmounted |

### Example `drive_mount_config.sh`

```bash
declare -A mountinfo
declare -A dirs

mountinfo["username"]="alice"
mountinfo["domain"]="cloud.example.com"

dirs["Documents"]="Docs"
dirs["Pictures"]="Photos"
```

With this config, `~/Documents` becomes a symlink to
`~/alice@cloud.example.com/Docs` whenever the drive is mounted, and to the
local shadow folder `~/.documents` whenever it isn't.

## Managing the systemd service

```bash
systemctl --user start   "<username>@<domain>.service"
systemctl --user stop    "<username>@<domain>.service"
systemctl --user restart "<username>@<domain>.service"
systemctl --user enable  "<username>@<domain>.service"
systemctl --user disable "<username>@<domain>.service"
systemctl --user status  "<username>@<domain>.service"
```

## Uninstalling

There's no automated uninstaller yet. To remove everything manually:

```bash
systemctl --user disable --now "<username>@<domain>.service"
rm /etc/systemd/user/<username>@<domain>.service
~/.local/bin/drivemount.sh -d        # unmount and relink to local data
rm ~/.local/bin/drivemount.sh ~/.local/bin/drivemount_wrapper.sh
rm ~/.local/share/drive_mount_config.sh
rm -r ~/.davfs2/secrets
sudo sed -i '/automatically added my drivemount install/,+1d' /etc/fstab
systemctl --user daemon-reload
```

Your data remains safe in the hidden shadow folders (`~/.<localdir>`)
after running `drivemount.sh -d`.


## Author

Niclas Fuchs
