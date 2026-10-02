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
  t) Test HDMI-CEC
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

## Notes

- Run with `sudo`, not from a root shell. It reads `SUDO_USER` to find the
  real user, so it works unchanged on a box where the account is `bc250`
  rather than `edgar`.
- State lives in `/var/lib/bc250-setup`, so revert only undoes what the
  script actually did.
- `systemctl stop cec.service` also turns the TV off, since `ExecStop` fires
  on any stop and not just shutdown.
