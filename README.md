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
  5) Controllers off        [not installed]
  6) Decky plugins          [not installed]
  7) Android TV (Waydroid)  [not installed]
  8) BC-250 Control Center  [not installed]

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

TV sleeps when the board powers off, wakes and switches to this input on
boot. Installs `cec-tv` (`on` / `off` / `cycle` / `status` / `monitor`) and
`cec.service`.

Two variants, chosen automatically:

- **With `bc250-cec` present** (it ships with the BC-250 kernel packages):
  hooks only. `bc250-cec` already registers the adapter and answers the TV,
  so a second follower would fight it for `/dev/cec0` and the logical
  address would flap.
- **Without it:** the full version, running `cec-follower` itself.

Waking at boot waits for the bus rather than firing on a timer. Straight
after a cold boot the DP link is still settling and the physical address
reads back as `f.f.f.f`; an adapter in that state cannot claim a logical
address, so anything sent then goes nowhere. `boot-on` polls for up to 60s
until the address is valid, then sends full wake sequences. Every 10s of that
wait it forces a DP re-detect through `trigger_hotplug` — the same debugfs
poke bc250-cec uses — because a display in standby often ignores the first
EDID read after the adapter powers up.

The boot unit is wanted by `multi-user.target`, not `graphical.target`. With
the TV off the adapter hands the driver a fallback EDID, and the graphical
session can fail to come up on that — which would stop the very service meant
to turn the TV on from ever running.

It is deliberately not ordered `After=bc250-cec.service`: that service is
itself `After=graphical.target`, which closes a loop, and systemd breaks an
ordering cycle by deleting one of the jobs — ours. The symptom is an empty
journal and a service that silently never ran.

### Wake-on-LAN

Optional, and off unless you ask for it: the CEC install offers it as a
fallback and a single `n` skips it. If a MAC is given, the boot path sends a
magic packet before touching CEC at all.

This exists because the CEC physical address is derived from the display's
EDID. A TV that stops answering while in standby leaves it at `f.f.f.f`, so
no logical address can be claimed and nothing can be transmitted — there is
no wake command to send. The adapter even supplies its own fallback EDID, so
the link reads as connected while the display is electrically absent. The
adapter's capability mask also lacks `CEC_CAP_PHYS_ADDR`, so the address
cannot be set by hand to work around it.

Wake-on-LAN goes over the network and does not care about HDMI. Once the
panel is on it answers EDID again and the CEC side claims the input as usual.
Turn on network standby first — Samsung: Settings → General → Network →
Expert Settings → Power On with Mobile. Find the MAC with the TV on:
`ip neigh | grep 192.168`. Test it any time with `tv-wol <mac>`.

Whether the CEC route alone can work depends on the display. The adapter is powered
from the DisplayPort connector, so a full poweroff kills it; on the next boot
it has to read EDID afresh from a display that is in standby. A set that does
not answer leaves the physical address at `f.f.f.f`, no logical address can be
claimed, and nothing can be transmitted — the journal says so plainly. Waking
such a set over CEC from a cold boot is not possible; its own remote is the
only way in. A set that stays reachable in standby works fine, which is why
`cec-tv off` then `cec-tv on` with the board still running is a different
case entirely.

Each sequence is Image View On, an Active Source broadcast, and the remote's
power-on key. Image View On alone is not enough on many sets — Samsung wants
the source to claim the path as well as ask for power, and some models only
act on the remote key.

The reported power state is not trusted as proof: a Samsung in standby
answers `GIVE_DEVICE_POWER_STATUS` with `on`, which is how an earlier version
came to send one Image View On, believe it had worked, and leave the TV dark.
Two full sequences always go out; only from the third does a reported `on`
end it early, for the case where the set really is already awake. It
re-registers between rounds because the link drops and returns as a set
wakes, which clears the logical address. Progress goes to the journal:
`journalctl -b -u cec.service`.

Standby at poweroff is a separate unit (`cec-standby.service`) started as
`poweroff.target` is reached, not an `ExecStop` on the boot unit. By that
point every normal service is already stopped, `bc250-cec` included, so
nothing is left to replug the link — and because the unit is wanted only by
`poweroff.target`/`halt.target`, a reboot never triggers it. An `ExecStop`
hook failed on both counts: it ran while `bc250-cec` was still live, and its
`systemctl stop bc250-cec` call could block inside the shutdown transaction
until the stop timeout killed it, so the standby never went out.

`bc250-cec` replugs the DP link whenever the display changes power state.
That replug re-announces the physical address, and a Samsung reads a source
appearing as "wake up" — so a standby is undone a second later. `cec-tv`
pauses `bc250-cec` around a deliberate power-off and resumes it on the next
power-on, so its link-drop workaround stays active the rest of the time.

Needs a DP-to-HDMI adapter that tunnels CEC. Most cheap active ones do not.
Confirmed working: UGREEN 8K DP 1.4 → HDMI 2.1 (Realtek RTD2173). The
Chrontel CH7218 is also confirmed. Check with `cec-ctl --list-devices`
before bothering.

### 2. LED strip daemon

Clones [peterdk31/bc250_ws2812b_controller](https://github.com/peterdk31/bc250_ws2812b_controller)
to `/opt/bc250` and runs its `make install`. Optionally runs `make flash`,
which downloads the prebuilt ESP32 image from the repo's releases and writes
it with esptool — no ESP-IDF toolchain needed, but it does need internet at
flash time, and it rewrites the power/fan/BLE config partitions.

`make install` never overwrites an existing `/etc/led-controller/config.json`,
so a fresh install needs `strip.leds`, `strip.pin` and the serial port set by
hand, then `systemctl restart led-controller`.

### 3. Power button / suspend

Masks `sleep.target`, `suspend.target`, `hibernate.target` and
`hybrid-sleep.target` — these boards hang on resume, so nothing should be
able to suspend them, including a CEC standby arriving over the bus. Adds a
logind drop-in setting `HandlePowerKey=poweroff`.

### 4. Guide button → input

Pressing the controller's guide button wakes the TV and claims the input.
An evdev listener watches for `BTN_MODE` with a 3-second debounce (guide is
also Steam's menu button). Optionally adds a udev rule that does the same on
controller connect, as a fallback if Steam grabs the pad exclusively.

Check Steam isn't eating the button first: `sudo evtest`, press guide, look
for `BTN_MODE`.

### 5. Controllers off

Disconnects Bluetooth controllers just before a poweroff, so the ESP32 power
switch doesn't see a reconnecting pad and turn the board straight back on.
Runs on poweroff only, not reboot.

DualSense and DS4 read a host-initiated disconnect as "turn off". 8BitDo and
Xbox pads go back to advertising until their own idle timer fires — for
those the real fix is on the ESP32 side (only count a wake once the pad has
been silent for ~10s).

### 6. Decky plugins

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

### 7. Android TV (Waydroid)

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

### 8. BC-250 Control Center

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
