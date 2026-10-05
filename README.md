# bc250-setup

Menu-driven installer that turns a CachyOS BC-250 into a console-like box
usable entirely from game mode. Every component installs and reverts
independently.

```sh
sudo sh bc250-setup.sh
```

```
  ======== BC-250 setup ========
  1) HDMI-CEC TV control    [not installed]
  2) LED strip daemon       [not installed]
  3) Power button / suspend [not installed]
  4) Guide button -> input  [not installed]
  5) Decky plugins          [not installed]
  6) Android TV (Waydroid)  [not installed]
  7) BC-250 Control Center  [not installed]

  a) Install all
  s) Status — what is actually installed
  t) Test HDMI-CEC
  u) Update this script
  r) Revert / remove
  q) Quit
```

Take a snapper snapshot before the first run. Install components one at a
time rather than `a` until you know each works on that box.

## Components

### 1. HDMI-CEC TV control

The TV sleeps when the board powers off. Waking it and switching the input
are manual — `cec-tv on`, `cec-tv off`, `cec-tv cycle` — or bound to the
controller's guide button with component 4.

There is deliberately no boot-time wake. It needs the display to answer EDID
while it is in standby, and not every set does: the adapter is powered from
the DisplayPort connector, so a full poweroff wipes the EDID it was holding,
and on the next boot a silent display leaves the CEC physical address at
`f.f.f.f`. No logical address can be claimed and nothing can be transmitted,
so there is no wake command to send. It works on sets that stay reachable in
standby and cannot work on those that do not, which is not something software
can decide.

Two variants, chosen automatically:

- **With `bc250-cec` present** (it ships with the BC-250 kernel packages):
  only the poweroff standby is installed. `bc250-cec` already registers the
  adapter and answers the TV, and a second follower would fight it for
  `/dev/cec0`, making the logical address flap.
- **Without it:** `cec.service` runs `cec-follower` so the TV's queries get
  answered, plus the same standby unit.

`cec-tv off` pauses `bc250-cec` first and resumes it afterwards, because its
replug re-announces the physical address and a Samsung reads a source
appearing as "wake up" — undoing the standby a second later.

Standby at poweroff is its own unit, started as `poweroff.target` is reached
rather than hung off an `ExecStop`. By that point every normal service is
stopped, `bc250-cec` included, so nothing is left to replug the link; and
because it is wanted only by `poweroff.target`/`halt.target`, a reboot never
triggers it.

Needs a DP-to-HDMI adapter that tunnels CEC. Most cheap active ones do not.
Confirmed working: UGREEN 8K DP 1.4 to HDMI 2.1, and Chrontel CH7218 based
units. Check with `cec-ctl --list-devices` before bothering.

### 2. LED strip daemon

Clones [peterdk31/bc250_ws2812b_controller](https://github.com/peterdk31/bc250_ws2812b_controller)
to `/opt/bc250` and runs its `make install`. Optionally runs `make flash`,
which downloads the prebuilt ESP32 image from the repo's releases and writes
it with esptool — no ESP-IDF toolchain needed, but it does need internet at
flash time, and it rewrites the power/fan/BLE config partitions.

`make install` never overwrites an existing `/etc/led-controller/config.json`.
The installer then sets `strip.leds` to 26, the length of the BC-250 front
strip, on a fresh or existing config. `strip.pin` and `serial.port` keep their
defaults (4 and `/dev/led-controller`); change them by hand only if your
wiring differs, then `systemctl restart led-controller`.

### 3. Power button / suspend

Masks `sleep.target`, `suspend.target`, `hibernate.target` and
`hybrid-sleep.target` — these boards hang on resume, so nothing should be
able to suspend them, including a CEC standby arriving over the bus. Adds a
logind drop-in setting `HandlePowerKey=poweroff`.

### 4. Guide button → input

Pressing the controller's guide button wakes the TV and claims the input.
An evdev listener watches for `BTN_MODE` with a 3-second debounce (guide is
also Steam's menu button). It opens each input device at most once and then
holds it, caching which paths are not gamepads, so at steady state it opens
nothing: repeatedly reopening the keyboard and pad to re-read their
capabilities left the controller dead in game mode until a key was pressed. Optionally adds a udev rule that does the same on
controller connect, as a fallback if Steam grabs the pad exclusively.

Check Steam isn't eating the button first: `sudo evtest`, press guide, look
for `BTN_MODE`.

### 5. Decky plugins

Three plugins are embedded in the script as base64 — no separate files
needed:

| Plugin | What it does |
|---|---|
| BC-250 Lighting | WS2812B strip and Nollie fan zones |
| System Updates | CachyOS updates and notifications from game mode |
| Discord Deck | Voice channels, audio device switching, speaking indicators |

Installs Decky Loader first if it's missing, using the official installer.
The copies under `plugins/` are the same zips, kept as a backup and for
installing by hand.

No credentials are baked in. Discord Deck stores its client ID and secret in
Decky's settings dir at runtime (mode 600), not in the plugin.

Installing Discord Deck offers to set those credentials up front, writing
`~/homebrew/settings/Discord Deck/config.json` directly so you don't have to
type two long strings into a text field with a controller. It prints the
steps and skips if a config already exists:

1. <https://discord.com/developers/applications>
2. New Application, any name
3. OAuth2 in the sidebar
4. Under Redirects, add `http://localhost`, then Save Changes
5. Copy the Client ID
6. Reset Secret, copy that

Discord has no anonymous path for this — the client ID identifies the app to
the local RPC socket and the secret is required to exchange the auth code for
a token, so every install needs its own application.

### 6. Android TV (Waydroid)

Installs `waydroid`, `cage` and `wlr-randr`, initialises a WayDroid-ATV
image (local zips if present in Downloads, otherwise the OTA channel),
enables the container, sets controller passthrough props, and writes
`~/waydroid-tv.sh`.

The launcher hands Android only Steam's virtual pad (`Microsoft X-Box 360
pad*`), so physical controllers stay hidden and presses don't leak through
while you're in the Steam UI. **Steam Input must be on for the shortcut** or
that virtual pad won't exist and Android will see no controller at all.

Still manual: adding `~/waydroid-tv.sh` to Steam as a non-Steam game, and
Button Mapper inside Android for the Xbox button.

### 7. BC-250 Control Center

Installs [movacx/bc250-control-center](https://github.com/movacx/bc250-control-center)
from the AUR (`bc250-control-center-git`) — system monitoring, GPU control,
CPU tuning, compute units and fan control in one desktop app.

Needs an AUR helper; offers to install `paru` if none is found. The build
runs as the invoking user, since AUR helpers refuse to run as root, so it
asks for a password partway through.

After installing, launch it and choose **Prepare dependencies** on its
dashboard — it detects the distro and pulls the governor, fan and CU tools
itself. Revert removes the package but leaves those dependencies alone.

## Status

The `[installed]` tags in the menu only read the marker files under
`/var/lib/bc250-setup`. `s` checks the system itself — binaries, unit states,
masked targets, config values, installed packages — and marks each line:

```
  1. HDMI-CEC TV control            [installed]
     [+] /dev/cec0            addr 2.0.0.0, mask 0x0010
     [+] TV                   reports on
     [!] cec-tv               missing: /usr/local/bin/cec-tv
     [+] cec.service          enabled, active
     [!] cec-standby          unit missing
     [+] bc250-cec            running (owns registration)
```

`[+]` fine, `[-]` not installed, `[!]` marked installed but broken. The count
of `[!]` lines is summarised at the end. This is what catches a component
that was installed once and has since lost a file or a unit — a system
update, a half-finished revert, a manual edit.

## Updating

`u` fetches the newest copy of the script from this repo and replaces the
running one, so a box only ever needs the single file. It tries, in order:

1. `git pull` — if the script sits in a git checkout. Runs as whoever owns
   the checkout, so git doesn't refuse on ownership and no root-owned objects
   are left behind.
2. `gh` — works while the repo is private, if the CLI is signed in
   (`pacman -S github-cli && gh auth login`).
3. A plain `raw.githubusercontent.com` download — works once the repo is
   public.

The download is checked before it goes anywhere near the real path: it must
parse as shell and contain this installer's own menu text, so a 404 page or
a truncated transfer can't clobber a working copy. An identical file is
reported as already current and nothing is written. Otherwise the old
version is kept as `bc250-setup.sh.bak` and the new one moved into place with
`mv`, which is a rename — the copy the running shell is still reading stays
intact. It then offers to re-exec on the new version.

Updating the script does not touch the helper scripts and units an install
already wrote to disk, so a newer version can sit there while the old files
keep running. After an update the next start offers to re-apply the
components that are marked installed. The LED daemon, Decky, Android TV and
Control Center install external software rather than files this script owns,
so an update never stales those.

## Notes

- Run with `sudo`, not from a root shell. It reads `SUDO_USER` to find the
  real user, so it works unchanged whatever the account is called.
- State lives in `/var/lib/bc250-setup`, so revert only undoes what the
  script actually did.
- `systemctl stop cec.service` also turns the TV off, since `ExecStop` fires
  on any stop and not just shutdown.
