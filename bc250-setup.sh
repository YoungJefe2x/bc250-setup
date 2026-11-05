#!/bin/sh
# bc250-setup.sh — install / revert the BC-250 game-mode components
#
#   sudo sh bc250-setup.sh
#
# Components:
#   cec     HDMI-CEC TV control (TV on/off with the board)
#   led     WS2812B LED strip daemon + ESP32 firmware flash
#   power   disable sleep/suspend; power button = shutdown
#   guide   controller guide button switches the TV to this input
#   decky   Decky plugins installed from local zip files
#   apps    Android TV (Waydroid), Xbox Cloud Gaming, GeForce NOW, Discord
#           and JDownloader 2, each added to the Steam library
#   aur     AUR packages: BC-250 Control Center (GPU/CPU/fan tuning)
#   streamres  Steam Link streams at 1080p so they show the whole screen
#   claude  Claude Code on its self-updating native install, plus an update timer
#
# Every component can be installed and reverted independently. What has been
# installed is recorded under /var/lib/bc250-setup so revert knows what to undo.
#
# `s` checks the system itself and reports what is really installed.
# `u` pulls a newer copy of this script from GitHub and replaces itself.

set -e

STATE_DIR=/var/lib/bc250-setup
LED_SRC=/opt/bc250/bc250_ws2812b_controller
LED_REPO=https://github.com/peterdk31/bc250_ws2812b_controller.git

# Where `u) Update this script` pulls a newer copy from.
SELF_OWNER=YoungJefe2x
SELF_REPO=bc250-setup
SELF_BRANCH=main
SELF_FILE=bc250-setup.sh

# ---------------------------------------------------------------- helpers ---

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo:  sudo sh $0" >&2
    exit 1
fi

# The invoking user, for anything that belongs in a home directory.
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -n "$REAL_HOME" ] || REAL_HOME=/root

mkdir -p "$STATE_DIR"
# Where this copy lives, so the System Updates plugin can offer to update it.
_self_path=$(readlink -f "$0" 2>/dev/null) || _self_path=""
if [ -f "$_self_path" ]; then
    printf '%s\n' "$_self_path" > "$STATE_DIR/script-path" 2>/dev/null || true
fi

mark()      { touch "$STATE_DIR/$1"; }
unmark()    { rm -f "$STATE_DIR/$1"; }
is_done()   { [ -e "$STATE_DIR/$1" ]; }
# Colors only on a real terminal, and never when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m');  C_BOLD=$(printf '\033[1m');  C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m');   C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
    C_CYAN=$(printf '\033[36m')
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi
# Box-drawing and dots when the terminal speaks UTF-8, plain ASCII otherwise.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*|*UTF8*|*utf-8*) G_ON="●"; G_OFF="○"; G_LINE="─" ;;
    *) G_ON="*"; G_OFF="-"; G_LINE="-" ;;
esac

status() {
    if is_done "$1"; then printf '%s%s installed%s' "$C_GREEN" "$G_ON" "$C_RESET"
    else printf '%s%s not installed%s' "$C_DIM" "$G_OFF" "$C_RESET"; fi
}

say()  { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
warn() { printf '%s!!%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }

# confirm "question" [y]: with nobody at the keyboard (--refresh), the
# optional second argument is the answer, and no means no.
confirm() {
    if [ -n "${UNATTENDED:-}" ]; then
        [ "${2:-n}" = y ]
        return
    fi
    printf '%s?%s %s %s[y/N]%s ' "$C_CYAN" "$C_RESET" "$1" "$C_DIM" "$C_RESET"
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pause() { printf '\n%sPress Enter to continue...%s ' "$C_DIM" "$C_RESET"; read -r _; }

# A horizontal rule as wide as the menus.
rule() {
    _r=""; _i=0
    while [ "$_i" -lt 46 ]; do _r="$_r$G_LINE"; _i=$((_i + 1)); done
    printf '  %s%s%s\n' "$C_DIM" "$_r" "$C_RESET"
}

# Title block: name, then host and kernel underneath.
header() {
    [ -t 1 ] && printf '\033[H\033[2J'
    echo
    printf '  %s%sBC-250 setup%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$1" "$C_RESET"
    printf '  %s%s  ·  kernel %s%s\n' "$C_DIM" "$(uname -n)" "$(uname -r)" "$C_RESET"
    rule
}

# One menu line: key, label, and an optional status on the right.
item() {
    if [ -n "${3:-}" ]; then
        printf '  %s%s%s  %-26s %s\n' "$C_BOLD" "$1" "$C_RESET" "$2" "$3"
    else
        printf '  %s%s%s  %s\n' "$C_BOLD" "$1" "$C_RESET" "$2"
    fi
}

# ----------------------------------------------------------- dependencies ---

# Packages more than one component needs.
ensure_base() {
    say "Installing base dependencies"
    pacman -S --needed --noconfirm base-devel git curl unzip
}

have_esptool() {
    command -v esptool >/dev/null 2>&1 || command -v esptool.py >/dev/null 2>&1
}

# Installed system-wide on purpose: `make flash` runs as root and won't see
# anything under a user's ~/.local/bin.
install_esptool() {
    have_esptool && return 0
    say "Installing esptool"
    pacman -S --needed --noconfirm python-esptool 2>/dev/null || true
    have_esptool && return 0
    pacman -S --needed --noconfirm python-pip 2>/dev/null || true
    pip install --break-system-packages esptool 2>/dev/null || true
    have_esptool
}

decky_present() {
    [ -d "$REAL_HOME/homebrew/services" ] && return 0
    systemctl list-unit-files 2>/dev/null | grep -q '^plugin_loader'
}

decky_loader_install() {
    if decky_present; then
        say "Decky Loader already installed"
        return 0
    fi
    say "Installing Decky Loader"
    say "This runs the official installer as $REAL_USER; it will ask for a password."
    confirm "Continue?" || return 1
    pacman -S --needed --noconfirm curl
    runuser -u "$REAL_USER" -- sh -c \
        'curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh' \
        || { warn "Decky Loader install failed"; return 1; }
    mark decky-loader
    say "Decky Loader installed. It appears in game mode after a Steam restart."
}

decky_loader_revert() {
    is_done decky-loader || return 0
    confirm "Also uninstall Decky Loader itself?" || return 0
    runuser -u "$REAL_USER" -- sh -c \
        'curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/uninstall.sh | sh' \
        || warn "Decky Loader uninstall failed"
    unmark decky-loader
}

# =================================================================== CEC ====

cec_install() {
    say "HDMI-CEC TV control"

    if [ ! -e /dev/cec0 ]; then
        warn "/dev/cec0 does not exist."
        warn "The TV must be on and set to this input, with a CEC-capable"
        warn "active DP-to-HDMI adapter, then replug the DP cable."
        confirm "Install anyway (it will work once /dev/cec0 appears)?" y || return 1
    fi

    pacman -S --needed --noconfirm v4l-utils

    cat > /usr/local/bin/cec-tv << 'SCRIPT'
#!/bin/sh
# cec-tv — control the TV over HDMI-CEC
# usage: cec-tv {register|on|off|cycle [secs]|status|monitor}
#   (poweroff-standby is for cec-standby.service, not for typing)
DEV=/dev/cec0
OSD="CachyOS"

get_pa() {
    cec-ctl -d "$DEV" 2>/dev/null | awk '/Physical Address/ {print $4; exit}'
}
register() {
    cec-ctl -d "$DEV" --playback --osd-name "$OSD" >/dev/null 2>&1
}
# Any tool that grabs the adapter wipes the registration; put it back.
ensure_registered() {
    mask=$(cec-ctl -d "$DEV" 2>/dev/null | awk '/Logical Address Mask/ {print $5; exit}')
    case "$mask" in
        ""|0x0000) register ;;
    esac
    return 0
}

# bc250-cec (from the BC-250 kernel packages) replugs the DP link whenever the
# display powers off or on. That replug re-announces our physical address, and
# a Samsung reads a source appearing as "wake up" — so it turns the TV straight
# back on after a standby. Pause it around a deliberate power-off and bring it
# back on the next power-on, so its link-drop workaround stays active the rest
# of the time.
PAUSE_FLAG=/run/cec-tv.bc250-cec-paused

pause_bc250_cec() {
    if systemctl is-active --quiet bc250-cec >/dev/null 2>&1; then
        systemctl stop bc250-cec 2>/dev/null && : > "$PAUSE_FLAG"
        sleep 1
    fi
    return 0
}

resume_bc250_cec() {
    if [ -e "$PAUSE_FLAG" ]; then
        rm -f "$PAUSE_FLAG"
        systemctl start bc250-cec 2>/dev/null
    fi
    return 0
}

tv_power_state() {
    cec-ctl -d "$DEV" --to 0 --give-device-power-status 2>/dev/null |
        awk '/pwr-state/ {print $2; exit}'
}

# Wait for the adapter to exist and for the TV to have handed us a physical
# address. Straight after a link change the address reads back as f.f.f.f, and
# an adapter in that state cannot claim a logical address, so anything sent
# then goes nowhere.
wait_for_bus() {
    _limit=${1:-15}
    _n=0
    while [ "$_n" -lt "$_limit" ]; do
        if [ -e "$DEV" ]; then
            case "$(get_pa)" in
                ""|f.f.f.f) : ;;
                *) return 0 ;;
            esac
        fi
        _n=$((_n + 1))
        sleep 1
    done
    echo "cec-tv: no usable CEC address after ${_limit}s" >&2
    return 1
}

# One full wake attempt. Image View On alone is not enough on a lot of sets:
# Samsung in particular wants the source to claim the path as well as ask for
# power, and some models only act on the remote's power key.
wake_once() {
    _p=$(get_pa)
    cec-ctl -d "$DEV" --to 0 --image-view-on >/dev/null 2>&1
    if [ -n "$_p" ] && [ "$_p" != "f.f.f.f" ]; then
        cec-ctl -d "$DEV" --active-source phys-addr="$_p" >/dev/null 2>&1
    fi
    cec-ctl -d "$DEV" --to 0 --user-control-pressed ui-cmd=power-on-function >/dev/null 2>&1
    cec-ctl -d "$DEV" --to 0 --user-control-released >/dev/null 2>&1
}

tv_on() {
    ensure_registered
    # Samsung sets report power status 'on' even while they are in standby, so
    # the reply cannot be trusted as proof of anything. Always send at least
    # two full wake sequences; only from the third do we let a reported 'on'
    # end it early, for the case where the set really is awake already.
    _try=1
    while [ "$_try" -le 5 ]; do
        wake_once
        sleep 4
        # The link drops and returns as a set wakes, which clears the address.
        ensure_registered
        _st=$(tv_power_state)
        echo "cec-tv: wake attempt $_try — TV reports '${_st:-no answer}'"
        if [ "$_try" -ge 2 ]; then
            case "$_st" in
                on|to-on) break ;;
            esac
        fi
        _try=$((_try + 1))
    done

    ensure_registered
    pa=$(get_pa)
    if [ -n "$pa" ] && [ "$pa" != "f.f.f.f" ]; then
        cec-ctl -d "$DEV" --active-source phys-addr="$pa" >/dev/null 2>&1
        echo "cec-tv: claimed active source $pa"
    else
        echo "cec-tv: no valid physical address — did not claim active source" >&2
    fi
    resume_bc250_cec
}

case "$1" in
    register) register ;;
    on)
        # Resume bc250-cec even when this fails: `off` stopped it, and leaving
        # it stopped means nothing replugs the link when the display returns,
        # so the adapter keeps serving its fallback EDID and the address stays
        # invalid forever -- CEC then looks dead even with the TV switched on.
        if wait_for_bus 15; then
            tv_on
        else
            resume_bc250_cec
            exit 1
        fi
        ;;
    off)
        pause_bc250_cec
        ensure_registered
        cec-ctl -d "$DEV" --to 0 --standby >/dev/null 2>&1
        ;;
    poweroff-standby)
        # Run by cec-standby.service as poweroff.target is reached — i.e. after
        # every normal service has already been stopped, bc250-cec included.
        # Nothing is left to replug the link, so no systemctl call is needed
        # here (and calling one mid-shutdown can block until the unit times
        # out, which is what killed the earlier ExecStop version). The unit is
        # wanted only by poweroff/halt, so a reboot never reaches this.
        [ -e "$DEV" ] || exit 0
        ensure_registered
        cec-ctl -d "$DEV" --to 0 --standby >/dev/null 2>&1
        # Give the TV a moment to act before the board cuts power.
        sleep 2
        ;;
    status)  cec-ctl -d "$DEV" --to 0 --give-device-power-status ;;
    cycle)
        # Off, wait, on. The screen is dark for the middle part, so this is
        # meant to be watched on the TV rather than read in the terminal.
        secs=${2:-20}
        "$0" off
        sleep "$secs"
        "$0" on
        ;;
    monitor) exec cec-ctl -d "$DEV" -M ;;
    *) echo "usage: cec-tv {register|on|off|cycle [secs]|status|monitor}" >&2; exit 1 ;;
esac
SCRIPT
    chmod +x /usr/local/bin/cec-tv

    # Two flavours of the boot unit. If bc250-cec is present it already
    # registers the adapter and answers the TV's queries, so running our own
    # cec-follower would be a second claimant on /dev/cec0 — that is what makes
    # the logical address flap. In that case ours only does the boot wake.
    # When bc250-cec is present it already registers the adapter and answers
    # the TV, so a second follower of ours would fight it for /dev/cec0 --
    # that is what made the logical address flap. Nothing of ours is needed
    # at boot in that case; standby at poweroff is a separate unit.
    if systemctl list-unit-files 2>/dev/null | grep -q '^bc250-cec'; then
        say "bc250-cec detected — it handles the bus; no boot unit of our own"
        rm -f /etc/systemd/system/cec.service
    else
        cat > /etc/systemd/system/cec.service << 'UNIT'
[Unit]
Description=HDMI-CEC follower

[Service]
Type=simple
ExecStartPre=/usr/local/bin/cec-tv register
ExecStart=/usr/bin/cec-follower -d /dev/cec0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    fi

    # Standby is its own unit, started as poweroff.target is reached rather
    # than hung off the boot unit's ExecStop. Three reasons that matters:
    #   - ExecStop runs while the rest of the system is still being torn down,
    #     and ordering put it BEFORE bc250-cec stopped, so bc250-cec was still
    #     live to replug the link and wake the TV straight back up;
    #   - calling `systemctl stop bc250-cec` from inside a shutdown transaction
    #     can block until the unit's own stop timeout kills it, so the standby
    #     never went out at all;
    #   - being wanted only by poweroff/halt means a reboot never triggers it,
    #     with no need to guess from the job list.
    cat > /etc/systemd/system/cec-standby.service << 'UNIT'
[Unit]
Description=HDMI-CEC TV standby at poweroff
DefaultDependencies=no
After=bc250-cec.service
Before=poweroff.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cec-tv poweroff-standby
TimeoutStartSec=20

[Install]
WantedBy=poweroff.target halt.target
UNIT

    # `systemctl enable` adds symlinks but never removes stale ones. An
    # earlier version of this unit was WantedBy=graphical.target, and a
    # leftover graphical.target.wants link rebuilds the ordering cycle that
    # makes systemd delete our start job -- the service then silently never
    # runs and the journal is empty. Clear every wants link first.
    systemctl disable cec.service cec-standby.service cec-watch.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/*.target.wants/cec.service \
          /etc/systemd/system/*.target.wants/cec-standby.service \
          /etc/systemd/system/*.target.wants/cec-watch.service
    systemctl daemon-reload
    if [ -e /etc/systemd/system/cec.service ]; then
        systemctl enable --now cec.service || warn "check: systemctl status cec.service"
    fi
    systemctl enable cec-standby.service || warn "could not enable cec-standby.service"

    if journalctl -b -q --no-pager 2>/dev/null | grep -q "ordering cycle.*cec.service"; then
        warn "This boot already hit an ordering cycle involving cec.service."
        warn "The links are fixed now, but reboot before judging the result."
    fi
    mark cec
    say "Done. The TV sleeps at poweroff; wake and input switching are manual:"
    say "  cec-tv on | cec-tv off | cec-tv cycle"
    say "There is no boot-time wake: that needs the display to answer EDID"
    say "while it is in standby, which not every set does."
}

# Diagnose the CEC chain and, if asked, power-cycle the TV to prove it works.
cec_test() {
    say "HDMI-CEC test"

    if [ ! -e /dev/cec0 ]; then
        warn "/dev/cec0 does not exist — no CEC adapter."
        warn "Check: the TV is on and set to this input, and the DP-to-HDMI"
        warn "adapter actually tunnels CEC (a cheap passive one will not)."
        warn "Then replug the DP cable and try again."
        return 1
    fi
    say "/dev/cec0 present"

    pa=$(cec-ctl -d /dev/cec0 2>/dev/null | awk '/Physical Address/ {print $4; exit}')
    mask=$(cec-ctl -d /dev/cec0 2>/dev/null | awk '/Logical Address Mask/ {print $5; exit}')
    say "Physical address: ${pa:-unknown}   logical mask: ${mask:-unknown}"
    case "$pa" in
        f.f.f.f) warn "Address is invalid — the HDMI link is down right now." ;;
    esac
    case "$mask" in
        0x0000|"") warn "Adapter is unregistered; nothing can transmit until it is." ;;
    esac

    if systemctl list-unit-files 2>/dev/null | grep -q '^bc250-cec'; then
        if systemctl is-active --quiet bc250-cec >/dev/null 2>&1; then
            say "bc250-cec: running (it owns registration; ours is hooks only)"
        else
            warn "bc250-cec is installed but NOT running."
            warn "If a power-off was interrupted it can be left stopped:"
            warn "  sudo systemctl start bc250-cec"
        fi
    else
        say "bc250-cec: not installed"
    fi

    if is_done cec; then
        if [ -e /etc/systemd/system/cec.service ]; then
            say "cec.service (follower): $(systemctl is-enabled cec.service 2>/dev/null || echo unknown)"
        else
            say "cec.service: not needed (bc250-cec is the follower)"
        fi
        _sb=$(systemctl is-enabled cec-standby.service 2>/dev/null || echo missing)
        say "cec-standby.service (poweroff): $_sb"
        case "$_sb" in
            enabled) : ;;
            *) warn "The standby unit is not enabled — the TV will not sleep on"
               warn "poweroff. Re-run option 1 to install the current version." ;;
        esac
        _stale=$(ls /etc/systemd/system/graphical.target.wants/cec.service 2>/dev/null || true)
        if [ -n "$_stale" ]; then
            _bad "stale symlink" "graphical.target.wants/cec.service — causes a cycle"
        fi
        if journalctl -b -q --no-pager 2>/dev/null | grep -q "ordering cycle.*cec.service"; then
            _bad "ordering cycle" "systemd deleted the boot job this boot"
        fi
        say "This boot's wake attempt:"
        journalctl -b -u cec.service --no-pager -q 2>/dev/null | tail -8 | sed 's/^/    /'
        say "Last poweroff standby attempt:"
        journalctl -b -1 -u cec-standby.service --no-pager -q 2>/dev/null | tail -5 | sed 's/^/    /'
    else
        warn "The CEC component is not installed — option 1 installs it."
    fi

    say "Devices on the bus:"
    cec-ctl -d /dev/cec0 -S 2>/dev/null | sed -n '/System Information/,$p' | \
        grep -E "OSD Name|Physical Address|Primary Device Type|Power Status" | sed 's/^/    /'

    echo
    if confirm "Power-cycle the TV now? (off, 20s, back on — watch the TV)"; then
        if [ -x /usr/local/bin/cec-tv ]; then
            /usr/local/bin/cec-tv cycle 20
            say "If the TV went off, stayed off, and came back on the right input, it works."
        else
            warn "cec-tv is not installed — run option 1 first."
            return 1
        fi
    fi
}

cec_revert() {
    say "Removing HDMI-CEC TV control"
    systemctl disable --now cec.service cec-watch.service 2>/dev/null || true
    systemctl disable cec-standby.service 2>/dev/null || true
    rm -f /etc/systemd/system/cec.service \
          /etc/systemd/system/cec-standby.service \
          /etc/systemd/system/cec-watch.service \
          /etc/systemd/system/*.target.wants/cec.service \
          /etc/systemd/system/*.target.wants/cec-standby.service \
          /etc/systemd/system/*.target.wants/cec-watch.service \
          /usr/local/bin/cec-tv
    systemctl daemon-reload
    unmark cec
    say "Removed. v4l-utils was left installed."
}

# =================================================================== LED ====

# Every BC-250 front strip here is the same 26-LED WS2812B, so set the count
# rather than leave upstream's default (33) for someone to fix by hand.
LED_COUNT=26
LED_CONFIG=/etc/led-controller/config.json

led_set_count() {
    [ -f "$LED_CONFIG" ] || { warn "$LED_CONFIG missing; set strip.leds to $LED_COUNT by hand"; return 0; }
    python3 - "$LED_CONFIG" "$LED_COUNT" << 'PY' || warn "could not set strip.leds; set it to $LED_COUNT by hand"
import json, sys
path, count = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    cfg = json.load(f)
if cfg.get("strip", {}).get("leds") == count:
    sys.exit(0)
cfg.setdefault("strip", {})["leds"] = count
with open(path, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
print(f">> strip.leds set to {count}")
PY
}

# Newer daemons renamed config keys and reject the old ones: "esp32" {...}
# moved to the top level, "sinks": {"serial"} became "serial", the
# steam_download effect became progress with source steam_dl, and rules take
# no extra keys (BC-250 Lighting 0.2.2 put _decky_* markers there; they now
# go in settings). Migrate a copy, and only replace the config when the
# freshly built daemon accepts it, so the running old daemon is never left
# with a file it can't read.
led_migrate_config() {
    [ -f "$LED_CONFIG" ] && [ -x "$LED_SRC/led" ] || return 0
    "$LED_SRC/led" --check "$LED_CONFIG" > /dev/null 2>&1 && return 0
    _tmp=$(mktemp "$LED_CONFIG.migrate.XXXXXX") || return 0
    python3 - "$LED_CONFIG" "$_tmp" << 'PY' || { rm -f "$_tmp"; warn "could not migrate $LED_CONFIG"; return 0; }
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    cfg = json.load(f)
esp = cfg.pop("esp32", None)
if isinstance(esp, dict):
    for k, v in esp.items():
        cfg.setdefault(k, v)
sinks = cfg.pop("sinks", None)
if isinstance(sinks, dict):
    if isinstance(sinks.get("serial"), dict):
        cfg.setdefault("serial", sinks["serial"])
    cmd = sinks.get("power_button_command") or cfg.pop("power_button_command", None)
    if sinks.get("power_button") and cmd:
        cfg.setdefault("power_switch", {}).setdefault("short_press", cmd)
for r in cfg.get("rules") or []:
    if not isinstance(r, dict):
        continue
    if r.get("effect") == "steam_download":
        r["effect"] = "progress"
        r.setdefault("settings", {}).setdefault("source", "steam_dl")
    for k in [k for k in r if k.startswith("_")]:
        r.setdefault("settings", {})[k] = r.pop(k)
with open(dst, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
PY
    if "$LED_SRC/led" --check "$_tmp" > /dev/null 2>&1; then
        cp -p "$LED_CONFIG" "$LED_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
        chmod --reference="$LED_CONFIG" "$_tmp" 2>/dev/null || true
        mv "$_tmp" "$LED_CONFIG"
        say "Migrated $LED_CONFIG to the new daemon's format (backup kept next to it)"
    else
        rm -f "$_tmp"
        warn "$LED_CONFIG still fails the new daemon's check; see: $LED_SRC/led --check $LED_CONFIG"
    fi
}

# The receiver's serial port. make install adds a udev rule that names it
# /dev/led-controller; nudge udev so that link exists without a replug, then
# fall back to the first ttyACM/ttyUSB the way upstream's Makefile does.
led_find_port() {
    udevadm trigger --subsystem-match=tty --action=add 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true
    for _p in /dev/led-controller /dev/ttyACM* /dev/ttyUSB*; do
        [ -e "$_p" ] && { echo "$_p"; return 0; }
    done
    return 0
}

# The receiver firmware release last flashed from here, so updates know
# when there is a newer one.
LED_FW_REPO=peterdk31/bc250_ws2812b_controller
LED_FW_STATE="$STATE_DIR/led-firmware"

led_latest_release() {
    curl -fsSL --max-time 20 "https://api.github.com/repos/$LED_FW_REPO/releases/latest" 2>/dev/null |
        sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1
}

# A receiver that also switches the PSU (power_switch enabled) resets mid-flash
# and could cut the machine's power, so it is never flashed unattended.
led_runs_power_switch() {
    python3 - "$LED_CONFIG" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if (cfg.get("power_switch") or {}).get("enabled") else 1)
PY
}

led_flash_if_new() {
    _tag=$(led_latest_release)
    if [ -z "$_tag" ]; then
        warn "could not look up the latest receiver firmware; not flashing"
        return 0
    fi
    if [ "$(cat "$LED_FW_STATE" 2>/dev/null)" = "$_tag" ]; then
        return 0
    fi
    if led_runs_power_switch; then
        warn "receiver firmware $_tag is out, but this receiver runs the power switch;"
        warn "flash it yourself: cd $LED_SRC && sudo make flash"
        return 0
    fi
    install_esptool || { warn "esptool missing; receiver not flashed"; return 1; }
    port=$(led_find_port)
    if [ -z "$port" ]; then
        warn "no ESP32 serial port found; receiver not flashed"
        return 1
    fi
    say "Flashing receiver firmware $_tag on $port"
    # make flash stops the daemon while it has the port and starts it again.
    if ( cd "$LED_SRC" && make flash PORT="$port" TARGET=esp32c3 FW_RELEASE="$_tag" ); then
        printf '%s\n' "$_tag" > "$LED_FW_STATE"
    else
        warn "receiver flash failed; it keeps its old firmware. Retry: cd $LED_SRC && sudo make flash"
        return 1
    fi
}

led_install() {
    say "WS2812B LED strip daemon"

    ensure_base

    mkdir -p /opt/bc250
    if [ -d "$LED_SRC/.git" ]; then
        say "Updating existing checkout"
        git -C "$LED_SRC" pull --ff-only || warn "pull failed; using the checkout as-is"
    else
        git clone "$LED_REPO" "$LED_SRC"
    fi

    # make install refuses a config the new daemon's `led --check` rejects, so
    # build first and bring the config up to the new format before installing.
    ( cd "$LED_SRC" && make ) && led_migrate_config
    ( cd "$LED_SRC" && make install )
    # make install never overwrites an existing /etc/led-controller/config.json
    led_set_count

    if [ -n "${UNATTENDED:-}" ]; then
        # An update flashes new receiver firmware on its own when a release
        # came out since the last flash; the daemon and firmware move together.
        led_flash_if_new || true
        ans=n
    else
        printf '\nFlash the ESP32 receiver now? (needs esptool; skip if already flashed) [y/N, Enter skips] '
        read -r ans
    fi
    case "$ans" in
        y|Y|yes|YES)
            if ! install_esptool; then
                warn "Could not install esptool automatically."
                warn "Try:  sudo pip install --break-system-packages esptool"
                warn "Then: cd $LED_SRC && sudo make flash"
            else
                port=$(led_find_port)
                if [ -z "$port" ]; then
                    warn "No ESP32 serial port found. Plug the receiver in by USB, then:"
                    warn "  cd $LED_SRC && sudo make flash"
                else
                    say "Flashing the receiver on $port"
                    _tag=$(led_latest_release)
                    if ( cd "$LED_SRC" && make flash PORT="$port" TARGET=esp32c3 ${_tag:+FW_RELEASE="$_tag"} ); then
                        [ -z "$_tag" ] || printf '%s\n' "$_tag" > "$LED_FW_STATE"
                    else
                        warn "flash failed; you can retry with: cd $LED_SRC && sudo make flash"
                    fi
                fi
            fi
            ;;
    esac

    # Restart rather than --now, so a re-run applies the LED count to a daemon
    # that is already running.
    { systemctl enable led-controller && systemctl restart led-controller; } \
        || warn "check: systemctl status led-controller"
    mark led
    say "Done. strip.leds is set to $LED_COUNT. If the pin or serial port differ,"
    say "edit $LED_CONFIG (strip.pin, serial.port), then: sudo systemctl restart led-controller"
}

led_revert() {
    say "Removing LED strip daemon"
    systemctl disable --now led-controller 2>/dev/null || true
    if [ -d "$LED_SRC" ]; then
        ( cd "$LED_SRC" && make uninstall ) || warn "make uninstall failed"
        if confirm "Also delete the source checkout at $LED_SRC?"; then
            rm -rf "$LED_SRC"
        fi
    else
        warn "No checkout at $LED_SRC — nothing to run make uninstall from."
        warn "Remove by hand: /usr/local/bin/led, /etc/led-controller,"
        warn "/etc/systemd/system/led-controller.service"
    fi
    systemctl daemon-reload
    unmark led
    say "Removed. The ESP32 keeps its firmware; reflash it separately if you care."
}

# ================================================================= POWER ====

power_install() {
    say "Disable sleep / suspend (power button = shutdown)"
    say "These boards hang on resume, so suspend is masked entirely."

    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/99-bc250.conf << 'CONF'
[Login]
HandlePowerKey=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
CONF

    # Never restart systemd-logind here: it owns the running game-mode session,
    # and restarting it drops that session and leaves the screen black.
    # The new power-key setting takes effect at the next boot.
    mark power
    say "Done. Reboot once for the power button change to take effect."
}

power_revert() {
    say "Restoring default power behaviour"
    systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
    rm -f /etc/systemd/logind.conf.d/99-bc250.conf
    # No logind restart (it kills the session); applies at the next boot.
    unmark power
    say "Restored. Reboot to apply. Suspend is possible again — remember it hangs this board."
}

# ================================================================= GUIDE ====

guide_install() {
    say "Controller guide button switches TV input"

    if ! is_done cec; then
        warn "This needs the HDMI-CEC component (option 1) — it calls cec-tv."
        confirm "Install anyway?" y || return 1
    fi

    pacman -S --needed --noconfirm python-evdev

    cat > /usr/local/bin/cec-guide-watch << 'SCRIPT'
#!/usr/bin/env python3
"""Press the guide button -> wake the TV and claim the input."""
import select
import subprocess
import time

import evdev

DEBOUNCE = 3.0          # guide is also Steam's menu button; don't spam CEC
RESCAN = 30.0           # seconds between looking for new controllers
CEC_TV = "/usr/local/bin/cec-tv"


def probe(path):
    """True if this device reports a guide button. Opens it briefly."""
    dev = None
    try:
        dev = evdev.InputDevice(path)
        return evdev.ecodes.BTN_MODE in dev.capabilities().get(evdev.ecodes.EV_KEY, [])
    except OSError:
        return False
    finally:
        if dev is not None:
            try:
                dev.close()
            except OSError:
                pass


def main():
    last = 0.0
    open_devs = {}          # path -> InputDevice, held open, not churned
    not_gamepads = set()    # paths already checked and rejected
    next_scan = 0.0

    while True:
        now = time.time()

        # Rescan occasionally for controllers that connected or went away.
        # Devices already open are left strictly alone: closing and reopening
        # them repeatedly disturbs whatever else is reading the controller,
        # which is how an earlier version left the pad dead in game mode.
        if now >= next_scan:
            next_scan = now + RESCAN
            present = set(evdev.list_devices())

            # Forget paths that have gone away, so a reused path is probed
            # again rather than trusted from a previous device.
            not_gamepads.intersection_update(present)
            for path in list(open_devs):
                if path not in present:
                    try:
                        open_devs.pop(path).close()
                    except OSError:
                        open_devs.pop(path, None)

            # Only ever open a path we have not already classified. At steady
            # state this opens nothing at all: repeatedly opening the
            # keyboard and the pad just to re-read their capabilities is what
            # disturbed input in game mode before.
            for path in present - set(open_devs) - not_gamepads:
                if probe(path):
                    try:
                        open_devs[path] = evdev.InputDevice(path)
                    except OSError:
                        pass
                else:
                    not_gamepads.add(path)

        if not open_devs:
            time.sleep(2)
            continue

        try:
            ready, _, _ = select.select(list(open_devs.values()), [], [], 2)
        except (OSError, ValueError):
            # A device vanished mid-select; drop everything and rescan.
            for dev in open_devs.values():
                try:
                    dev.close()
                except OSError:
                    pass
            open_devs.clear()
            next_scan = 0
            continue

        for dev in ready:
            try:
                for ev in dev.read():
                    if (ev.type == evdev.ecodes.EV_KEY
                            and ev.code == evdev.ecodes.BTN_MODE
                            and ev.value == 1):
                        now = time.time()
                        if now - last > DEBOUNCE:
                            last = now
                            subprocess.run([CEC_TV, "on"], check=False)
            except OSError:
                try:
                    dev.close()
                except OSError:
                    pass
                open_devs.pop(dev.path, None)
                next_scan = 0


if __name__ == "__main__":
    main()
SCRIPT
    chmod +x /usr/local/bin/cec-guide-watch

    cat > /etc/systemd/system/cec-guide.service << 'UNIT'
[Unit]
Description=Switch TV input on controller guide button
After=cec.service
Wants=cec.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cec-guide-watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now cec-guide.service || \
        warn "check: systemctl status cec-guide.service"

    # Fallback for the case where Steam grabs the pad exclusively: a controller
    # waking up is itself an event we can hang the input switch on.
    # A refresh keeps whatever was picked last time.
    if { [ -n "${UNATTENDED:-}" ] && is_done guide-udev; } ||
        confirm "Also switch input when a controller connects? (helps if Steam grabs the button)"; then
        mkdir -p /etc/udev/rules.d
        cat > /etc/udev/rules.d/99-cec-controller.rules << 'RULE'
ACTION=="add", SUBSYSTEM=="input", ATTRS{name}=="*Controller*", RUN+="/usr/local/bin/cec-tv on"
RULE
        udevadm control --reload-rules 2>/dev/null || true
        mark guide-udev
    fi

    mark guide
    say "Done. Check it works with:  sudo evtest   (look for BTN_MODE)"
}

guide_revert() {
    say "Removing guide-button input switching"
    systemctl disable --now cec-guide.service 2>/dev/null || true
    rm -f /etc/systemd/system/cec-guide.service /usr/local/bin/cec-guide-watch
    if is_done guide-udev; then
        rm -f /etc/udev/rules.d/99-cec-controller.rules
        udevadm control --reload-rules 2>/dev/null || true
        unmark guide-udev
    fi
    systemctl daemon-reload
    unmark guide
    say "Removed."
}

# =========================================================== CONTROLLERS ====

# This used to be a component: disconnect BT controllers at poweroff so the
# ESP32 switch would not see a reconnecting pad and turn the board straight
# back on. Powering off turns the pad off by itself, so it earned nothing.
# Left here only to clear it off boxes that installed it.
ctrl_cleanup() {
    [ -e "$STATE_DIR/ctrl" ] || [ -e /etc/systemd/system/controllers-off.service ] || return 0
    say "Removing the old 'controllers off' component (no longer part of this script)"
    systemctl disable --now controllers-off.service 2>/dev/null || true
    rm -f /etc/systemd/system/controllers-off.service \
          /etc/systemd/system/*.target.wants/controllers-off.service \
          /usr/local/bin/controllers-off.sh
    systemctl daemon-reload 2>/dev/null || true
    unmark ctrl
    return 0
}

# ================================================================ ANDROID ===

WAYDROID_IMG_DIR=/etc/waydroid-extra/images
ATV_OTA_SYS=https://waydroid-atv.github.io/ota/a16-tv/system
ATV_OTA_VEN=https://waydroid-atv.github.io/ota/a16-tv/vendor

# The pieces this script writes for Android TV: the sudoers rule, the
# hold-View/Menu-for-Home service and the launcher. Kept apart from atv_install so
# an update can re-apply them without re-initialising Waydroid.
atv_write_files() {
    # Passwordless rule for exactly one command: re-adding an input device so
    # Android notices Steam's virtual pad. Validated before it goes live,
    # because a broken sudoers file can lock you out of sudo.
    tmp=$(mktemp)
    echo "$REAL_USER ALL=(root) NOPASSWD: /usr/bin/tee /sys/class/input/event*/uevent" > "$tmp"
    if visudo -cf "$tmp" >/dev/null 2>&1; then
        install -m 440 -o root -g root "$tmp" /etc/sudoers.d/waydroid-udev
        say "sudoers rule installed"
    else
        warn "sudoers rule failed validation — not installed; controller won't auto-attach"
    fi
    rm -f "$tmp"

    # The earlier Start + Select helper ran from the launcher through sudo.
    # Its replacement below is a root service, so it needs neither.
    rm -f /usr/local/bin/atv-home-combo

    # Steam keeps the guide (Xbox / PS) button for its own menu, so Android never
    # sees a Home press. Holding View or Menu stands in for it. Runs as root so it can read
    # the pad and reach Waydroid without any sudo rule; it only acts while the
    # Android TV window (cage) is up. It also keeps controllers that reconnect
    # while Android TV is open out of Android, so input stays with whatever is
    # on screen.
    cat > /usr/local/bin/atv-home-button << 'HOMEBTN'
#!/usr/bin/env python3
"""Android TV helper: Home on a held button, and only Steam's pad in Android.

Hold View or Menu on the controller -> Android Home, in Android TV only.
Reads Steam's virtual pad, the "Microsoft X-Box 360 pad" Android also sees.
Steam presents every controller through it, so Create / Options on a
PlayStation pad arrive here as View / Menu.
A hold of HOLD seconds presses Home once; a short tap is left alone.

Android is meant to see only Steam's virtual pad: the launcher hands it just
that one, so the Quick Access menu and the rest of Steam keep their input.
A controller or keyboard that reconnects while Android TV is open is
announced to Android like any new device, and Android would then read it
directly whatever is on screen. Its node is removed again from Android's own
/dev/input (a separate tmpfs; the host's node is untouched).

While another app is in front of Android TV (Steam's menu, Discord, a game),
atv-input-gate flags it in /run/user/<uid>/atv-input-blocked. Steam's pad
is then removed from Android's /dev/input as well, and created again once
Android TV is in front, so only Android stops reading it.
"""
import glob, os, select, struct, subprocess, time

HOLD = 0.8
EVENT = struct.Struct("llHHi")
EV_KEY = 0x01
BUTTONS = (0x13A, 0x13B)  # BTN_SELECT (View), BTN_START (Menu)
PAD = "Microsoft X-Box 360 pad"
# Android's device manager creates the node a moment after the device shows
# up; remove it then, and once more in case it was slow.
PURGE_AFTER = (1.5, 5.0)
BLOCK_FLAG = "/run/user/*/atv-input-blocked"


def name(path):
    node = os.path.basename(path)
    try:
        with open(f"/sys/class/input/{node}/device/name") as f:
            return f.read().strip()
    except OSError:
        return ""


def android_up():
    return subprocess.run(["pgrep", "-x", "cage"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def shell(*cmd, timeout=15):
    return subprocess.run(["/usr/bin/waydroid", "shell", "--", *cmd],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=timeout, text=True)


def home():
    shell("input", "keyevent", "3")


def own_dev_input():
    """True when Android's /dev/input is its own, not the host's."""
    try:
        mounts = shell("cat", "/proc/mounts").stdout
    except (OSError, subprocess.SubprocessError):
        return False
    dev = [l.split() for l in mounts.splitlines() if len(l.split()) > 2]
    if any(m[1] == "/dev/input" for m in dev):
        return False
    return any(m[1] == "/dev" and m[2] == "tmpfs" for m in dev)


def blocked():
    return bool(glob.glob(BLOCK_FLAG))


def pad_paths():
    return sorted(p for p in glob.glob("/dev/input/event*") if name(p).startswith(PAD))


def hide_pads():
    """Take Steam's pad out of Android only; the host's node stays."""
    paths = pad_paths()
    if paths and own_dev_input():
        try:
            shell("rm", "-f", *paths)
        except (OSError, subprocess.SubprocessError):
            pass


def show_pads():
    """Create Steam's pad in Android's /dev/input again."""
    cmds = []
    for path in pad_paths():
        try:
            with open(f"/sys/class/input/{os.path.basename(path)}/dev") as f:
                major, minor = f.read().strip().split(":")
        except (OSError, ValueError):
            continue
        cmds.append(f"[ -e {path} ] || {{ mknod {path} c {major} {minor}"
                    f" && chown root:input {path} && chmod 660 {path}; }}")
    if cmds and own_dev_input():
        try:
            shell("sh", "-c", "; ".join(cmds))
        except (OSError, subprocess.SubprocessError):
            pass


def purge(paths):
    """Drop host devices other than Steam's pad from Android."""
    # Names are read again now: a node that has only just appeared can
    # briefly have none, and Steam's pads must stay.
    paths = [p for p in paths if os.path.exists(p) and not name(p).startswith(PAD)]
    if paths and own_dev_input():
        try:
            shell("rm", "-f", *sorted(paths))
            print("removed from Android:", *sorted(paths), flush=True)
        except (OSError, subprocess.SubprocessError):
            pass


def sweep(hidden):
    """Check Android's own /dev/input and drop anything that is not allowed.

    Reconnects are caught as they happen, but Android can create a node
    later than expected; this catches whatever got past that.
    """
    try:
        listing = shell("ls", "/dev/input").stdout.split()
    except (OSError, subprocess.SubprocessError):
        return
    extra = []
    for node in listing:
        if not node.startswith("event"):
            continue
        path = "/dev/input/" + node
        if not os.path.exists(path):
            continue    # not a host device; leave Android's own alone
        if hidden or not name(path).startswith(PAD):
            extra.append(path)
    if extra and own_dev_input():
        try:
            shell("rm", "-f", *sorted(extra))
            print("removed from Android:", *sorted(extra), flush=True)
        except (OSError, subprocess.SubprocessError):
            pass


SWEEP_EVERY = 3.0

fds = {}            # fd -> path, Steam pads held open
down = {}           # (fd, button) -> time it went down, None once fired
seen = set()        # every event node seen so far
was_up = None       # unknown until the first scan
purges = []         # (when, paths)
hidden = False      # Steam's pad is out of Android while another app is in front
next_scan = 0.0
next_flag = 0.0
next_sweep = 0.0
while True:
    now = time.monotonic()
    if now >= next_sweep:
        next_sweep = now + SWEEP_EVERY
        if android_up():
            sweep(hidden)
    if now >= next_flag:
        next_flag = now + 0.2
        up_now = android_up()
        want = up_now and blocked()
        if want != hidden:
            if want:
                hide_pads()
            elif up_now:
                show_pads()
            hidden = want
    if now >= next_scan:
        next_scan = now + 1
        up = android_up()
        paths = set(glob.glob("/dev/input/event*"))
        new = paths - seen
        seen = paths
        for path in paths:
            if path in fds.values() or not name(path).startswith(PAD):
                continue
            try:
                fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
            except OSError:
                pass
        # Opening Android TV starts clean; anything plugged in after that is
        # kept out of Android. Starting while it is already open (after an
        # update) clears out whatever got in before.
        if up and was_up is None:
            purges.append((now, paths))
        elif up and was_up and new:
            purges += [(now + d, new) for d in PURGE_AFTER]
            if hidden:
                # A pad recreated on reconnect must stay out while hidden.
                purges += [(now + d, "pads") for d in PURGE_AFTER]
        if not up:
            purges.clear()
        was_up = up
    for item in [p for p in purges if p[0] <= now]:
        purges.remove(item)
        if item[1] == "pads":
            if hidden:
                hide_pads()
        else:
            purge(item[1])
    if not fds:
        time.sleep(0.5)
        continue
    ready, _, _ = select.select(list(fds), [], [], 0.1)
    for fd in ready:
        try:
            data = os.read(fd, EVENT.size * 64)
        except BlockingIOError:
            continue
        except OSError:
            os.close(fd)
            fds.pop(fd, None)
            for key in [k for k in down if k[0] == fd]:
                del down[key]
            continue
        for off in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _s, _us, etype, code, value = EVENT.unpack_from(data, off)
            if etype == EV_KEY and code in BUTTONS:
                if value == 1:
                    down[(fd, code)] = time.monotonic()
                elif value == 0:
                    down.pop((fd, code), None)
    now = time.monotonic()
    for key, since in list(down.items()):
        if since is not None and now - since >= HOLD:
            down[key] = None
            if android_up() and not hidden:
                home()
HOMEBTN
    chmod 755 /usr/local/bin/atv-home-button

    cat > /etc/systemd/system/atv-home-button.service << 'UNIT'
[Unit]
Description=Android TV: hold View/Create or Menu/Options for Home; keep other controllers and other apps' input out
After=waydroid-container.service

[Service]
ExecStart=/usr/local/bin/atv-home-button
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable atv-home-button.service >/dev/null 2>&1 || true
    systemctl restart atv-home-button.service || \
        warn "check: systemctl status atv-home-button"

    # Steam's menu, Discord or a game can open over Android TV without
    # stopping it, and Android reads Steam's virtual pad directly, so it would
    # act on every press meant for the app in front. This user helper follows
    # gamescope's focused app and Steam's overlay (Quick Access) and flags when
    # Android TV is not what the controller is driving;
    # atv-home-button (root) then takes the pad out of Android only, so the
    # app in front keeps it. Started by the launcher.
    pacman -Q python-xlib >/dev/null 2>&1 || \
        pacman -S --needed --noconfirm python-xlib || warn "python-xlib install failed"
    cat > /usr/local/bin/atv-input-gate << 'GATE'
#!/usr/bin/env python3
"""Flag when Android TV is not what the controller is driving.

Reads gamescope's root display (:0; Steam starts shortcuts with DISPLAY=:1,
which lacks gamescope's atoms) five times a second:
- GAMESCOPE_FOCUSED_APP: the app in front. Android TV's own app id comes
  from SteamAppId in the launcher's environment; Steam's menu is 769.
- STEAM_INPUT_FOCUS on Steam's overlay window (STEAM_OVERLAY): set while
  Quick Access or another overlay takes the controller, even though the app
  in front stays Android TV.
While either says the input is not Android's, $XDG_RUNTIME_DIR/atv-input-blocked
exists; atv-home-button removes Steam's pad from Android's /dev/input then
and puts it back once Android TV has the controller again. Exits when
Android TV (cage) closes, clearing the flag.
"""
import os, signal, subprocess, sys, time
from Xlib import X, display

ANDROID = os.environ.get("SteamAppId", "")
STEAM_UI = 769
FLAG = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}",
                    "atv-input-blocked")


def cage_up():
    return subprocess.run(["pgrep", "-x", "cage"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def flag(on):
    try:
        if on:
            open(FLAG, "w").close()
        else:
            os.unlink(FLAG)
    except OSError:
        pass


def card(win, atom):
    prop = win.get_full_property(atom, X.AnyPropertyType)
    return int(prop.value[0]) if prop is not None and len(prop.value) else None


def blocked(d, root, atoms):
    app = card(root, atoms["GAMESCOPE_FOCUSED_APP"])
    if app is not None:
        if ANDROID and app != int(ANDROID):
            return True
        if not ANDROID and app == STEAM_UI:
            return True
    for win in root.query_tree().children:
        try:
            if card(win, atoms["STEAM_OVERLAY"]) and card(win, atoms["STEAM_INPUT_FOCUS"]):
                return True
        except Exception:
            continue    # window went away while being read
    return False


signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
flag(False)
d = display.Display(":0")
root = d.screen().root
atoms = {n: d.intern_atom(n) for n in
         ("GAMESCOPE_FOCUSED_APP", "STEAM_OVERLAY", "STEAM_INPUT_FOCUS")}
seen_cage = False   # the launcher starts this before cage is up
last = None
next_cage = 0.0
try:
    while True:
        now = time.monotonic()
        if now >= next_cage:
            next_cage = now + 1
            up = cage_up()
            if seen_cage and not up:
                break
            seen_cage = seen_cage or up
        state = blocked(d, root, atoms)
        if state != last:
            flag(state)
            last = state
        time.sleep(0.2)
finally:
    flag(False)
GATE
    chmod 755 /usr/local/bin/atv-input-gate

    cat > "$REAL_HOME/waydroid-tv.sh" << 'LAUNCH'
#!/bin/bash
# Android TV (Waydroid) launcher for game mode
# Exit Game in Steam ends this whole process tree, so a plain stop at the end
# never runs and Android keeps reading the controller in the background. Stop
# the session on any exit, from a detached process Steam does not track.
stop_android() {
  trap - EXIT HUP INT TERM
  kill "$GATE" 2>/dev/null
  setsid -f /usr/bin/waydroid session stop >/dev/null 2>&1 < /dev/null
}
# Cut Android off from the controller while the Steam menu has focus.
/usr/local/bin/atv-input-gate &
GATE=$!
trap stop_android EXIT
trap 'stop_android; exit 0' HUP INT TERM
cage -- bash -c '
  OUT=$(wlr-randr | head -1 | cut -d" " -f1)
  wlr-randr --output "$OUT" --custom-mode 1920x1080 2>/dev/null
  waydroid show-full-ui 2>&1 | while read -r line; do
    case "$line" in
      *"is ready"*)
        sleep 2
        for d in /sys/class/input/event*; do
          n=$(cat "$d/device/name" 2>/dev/null)
          case "$n" in "Microsoft X-Box 360 pad"*) sudo -n tee "$d/uevent" <<< add ;; esac
        done
        ;;
    esac
  done
' &
wait $!
LAUNCH
    chmod +x "$REAL_HOME/waydroid-tv.sh"
    chown "$REAL_USER" "$REAL_HOME/waydroid-tv.sh"

}

atv_install() {
    say "Android TV (Waydroid) for game mode"

    pacman -S --needed --noconfirm waydroid cage wlr-randr unzip python-xlib

    # Download the WayDroid-ATV system and vendor images from its OTA channel;
    # waydroid init fetches and verifies them itself. Zips already sitting in
    # ~/Downloads are only a fallback for when the download fails.
    say "Downloading the WayDroid-ATV images (large; this takes a while)"
    if ! waydroid init -f -c "$ATV_OTA_SYS" -v "$ATV_OTA_VEN" -r lineage -s GAPPS; then
        zipdir="$REAL_HOME/Downloads"
        sys=$(ls -t "$zipdir"/*waydroid_tv*system*.zip 2>/dev/null | head -1)
        ven=$(ls -t "$zipdir"/*waydroid_tv*vendor*.zip 2>/dev/null | head -1)
        if [ -z "$sys" ] || [ -z "$ven" ]; then
            warn "Download failed. Check the network and run this option again."
            return 1
        fi
        warn "Download failed; using local images instead:"
        warn "  $(basename "$sys") + $(basename "$ven")"
        mkdir -p "$WAYDROID_IMG_DIR"
        unzip -o -q "$sys" -d "$WAYDROID_IMG_DIR"
        unzip -o -q "$ven" -d "$WAYDROID_IMG_DIR"
        waydroid init -f || { warn "waydroid init failed"; return 1; }
    fi

    # WayDroid-ATV's setup wizard stops on a Bluetooth remote pairing screen
    # that a controller can't get past. This prop skips it.
    _prop=/var/lib/waydroid/waydroid_base.prop
    if [ -f "$_prop" ]; then
        if grep -q '^atv.setup.bt_remote_pairing=' "$_prop"; then
            sed -i 's/^atv\.setup\.bt_remote_pairing=.*/atv.setup.bt_remote_pairing=false/' "$_prop"
        else
            echo "atv.setup.bt_remote_pairing=false" >> "$_prop"
        fi
        say "Skipping the Bluetooth remote pairing screen"
    else
        warn "$_prop not found; the BT remote pairing screen won't be skipped"
    fi

    systemctl enable --now waydroid-container || \
        warn "check: systemctl status waydroid-container"

    # Let Android see the controller directly.
    if runuser -u "$REAL_USER" -- waydroid prop set persist.waydroid.uevent true 2>/dev/null && \
       runuser -u "$REAL_USER" -- waydroid prop set persist.waydroid.udev true 2>/dev/null; then
        say "Controller passthrough enabled"
    else
        warn "Couldn't set the controller props yet (they need a running session)."
        warn "After the first launch, run once:"
        warn "  waydroid prop set persist.waydroid.uevent true"
        warn "  waydroid prop set persist.waydroid.udev true"
        warn "  waydroid session stop"
    fi

    atv_write_files

    mark atv
    say "Done. The System Updates plugin adds \"Android TV\" to your Steam"
    say "library on its own within a few seconds in game mode. Without it, add"
    say "$REAL_HOME/waydroid-tv.sh as a Non-Steam Game in desktop mode."
    say "Keep Steam Input on for it — the virtual pad Android uses only"
    say "exists while Steam Input is enabled."
    say "In Android TV, hold View or Menu (Create or Options on PlayStation) for Home."
}

atv_revert() {
    say "Removing Android TV (Waydroid)"
    runuser -u "$REAL_USER" -- waydroid session stop 2>/dev/null || true
    systemctl disable --now waydroid-container 2>/dev/null || true
    systemctl disable --now atv-home-button.service 2>/dev/null || true
    rm -f /etc/systemd/system/atv-home-button.service
    systemctl daemon-reload
    rm -f /etc/sudoers.d/waydroid-udev "$REAL_HOME/waydroid-tv.sh" \
          /usr/local/bin/atv-home-button /usr/local/bin/atv-home-combo \
          /usr/local/bin/atv-input-gate

    if confirm "Delete Android data and images too? (apps, logins, everything)"; then
        rm -rf /var/lib/waydroid "$REAL_HOME/.local/share/waydroid" "$WAYDROID_IMG_DIR"
        rmdir /etc/waydroid-extra 2>/dev/null || true
        rm -f "$REAL_HOME"/.local/share/applications/waydroid.*.desktop
    fi
    if confirm "Uninstall the waydroid, cage and wlr-randr packages?"; then
        pacman -Rns --noconfirm waydroid cage wlr-randr || warn "package removal failed"
    fi
    unmark atv
    say "Removed. System Updates takes the Android TV shortcut out of Steam."
}

# ================================================================== APPS ===
# Cloud gaming apps from Flatpak. Each gets a small launcher in the home
# folder, which System Updates adds to the Steam library like Android TV.


# flatpak_has APP: installed system-wide or for the user.
flatpak_has() {
    command -v flatpak >/dev/null 2>&1 || return 1
    flatpak info "$1" >/dev/null 2>&1 ||
        runuser -u "$REAL_USER" -- flatpak info "$1" >/dev/null 2>&1
}

# Xbox Cloud Gaming runs in Microsoft Edge (Flatpak), full screen on
# xbox.com/play. Better xCloud, a userscript that adds controller options and
# stream settings, is added once by hand with Tampermonkey: its own guide is
# better-xcloud.github.io/chromium.
XCLOUD_BROWSER=com.microsoft.Edge

EDGE_CHORD_DIR="$REAL_HOME/.var/app/$XCLOUD_BROWSER/gamepad-chord"

# write_edge_chord: an Edge add-on, loaded by the launchers, that reports View
# and Menu pressed together as the Xbox button on xbox.com and GeForce NOW,
# since Steam keeps the Xbox button for itself in game mode.
write_edge_chord() {
    mkdir -p "$EDGE_CHORD_DIR"
    cat > "$EDGE_CHORD_DIR/manifest.json" << 'CHORD'
{
  "manifest_version": 3,
  "name": "Guide button chord",
  "version": "1.0",
  "description": "View + Menu together act as the Xbox button.",
  "content_scripts": [{
    "matches": ["https://play.geforcenow.com/*", "https://www.xbox.com/*"],
    "js": ["chord.js"],
    "run_at": "document_start",
    "all_frames": true,
    "world": "MAIN"
  }]
}
CHORD
    cat > "$EDGE_CHORD_DIR/chord.js" << 'CHORD'
// Steam keeps the Xbox button for itself in game mode, so pressing View and
// Menu together is reported to the page as the Xbox (guide) button instead.
(() => {
  const real = navigator.getGamepads.bind(navigator);
  const VIEW = 8, MENU = 9, GUIDE = 16;
  const btn = (pressed) => ({ pressed, touched: pressed, value: pressed ? 1 : 0 });
  navigator.getGamepads = function () {
    return Array.from(real(), (pad) => {
      if (!pad || pad.buttons.length <= MENU) return pad;
      const buttons = Array.from(pad.buttons, (b) => ({ pressed: b.pressed, touched: b.touched, value: b.value }));
      while (buttons.length <= GUIDE) buttons.push(btn(false));
      if (buttons[VIEW].pressed && buttons[MENU].pressed) {
        buttons[VIEW] = btn(false);
        buttons[MENU] = btn(false);
        buttons[GUIDE] = btn(true);
      }
      return {
        id: pad.id, index: pad.index, connected: pad.connected,
        timestamp: pad.timestamp, mapping: pad.mapping, axes: pad.axes,
        buttons, vibrationActuator: pad.vibrationActuator,
      };
    });
  };
  navigator.getGamepads.toString = () => 'function getGamepads() { [native code] }';
})();
CHORD
    chown "$REAL_USER" "$REAL_HOME/.var" "$REAL_HOME/.var/app" "$REAL_HOME/.var/app/$XCLOUD_BROWSER"
    chown -R "$REAL_USER" "$EDGE_CHORD_DIR"
}

# write_edge_launcher FILE URL: a launcher that opens URL in Edge full screen.
write_edge_launcher() {
    write_edge_chord
    cat > "$1" << LAUNCH
#!/bin/sh
# Started from the Steam library in game mode.
unset LD_PRELOAD
exec flatpak run $XCLOUD_BROWSER --kiosk --start-fullscreen --no-first-run --load-extension=$EDGE_CHORD_DIR $2 "\$@"
LAUNCH
    chmod +x "$1"
    chown "$REAL_USER" "$1"
    # Lets the browser's Gamepad API see Steam's virtual controller.
    flatpak override --filesystem=/run/udev:ro "$XCLOUD_BROWSER" 2>/dev/null || true
}

# edge_ensure: Microsoft Edge from Flathub, installed if missing.
edge_ensure() {
    flatpak_has "$XCLOUD_BROWSER" && return 0
    pacman -S --needed --noconfirm flatpak
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install -y --noninteractive flathub "$XCLOUD_BROWSER" || {
        warn "Couldn't install Microsoft Edge from Flathub"
        return 1
    }
}

xcloud_write_files() {
    write_edge_launcher "$REAL_HOME/xbox-cloud-gaming.sh" https://www.xbox.com/play
}

xcloud_install() {
    say "Xbox Cloud Gaming (Edge)"
    edge_ensure || return 1
    xcloud_write_files
    mark xcloud
    say "Done. System Updates adds \"Xbox Cloud Gaming\" to your Steam library"
    say "within a few seconds in game mode. Sign in with your Microsoft account"
    say "once at xbox.com/play; Game Pass Ultimate is needed to play."
    say ""
    say "For Better xCloud's controller-friendly menus, once, in desktop mode:"
    say "  1. Open Edge, go to edge://extensions and turn on Developer mode."
    say "  2. Add Tampermonkey from the Chrome Web Store."
    say "  3. Open https://github.com/redphx/better-xcloud/releases/latest/download/better-xcloud.user.js"
    say "     and press Install."
}

xcloud_revert() {
    say "Removing Xbox Cloud Gaming"
    rm -f "$REAL_HOME/xbox-cloud-gaming.sh"
    if flatpak_has "$XCLOUD_BROWSER" && confirm "Uninstall Microsoft Edge too?"; then
        flatpak uninstall -y --noninteractive "$XCLOUD_BROWSER" 2>/dev/null ||
            runuser -u "$REAL_USER" -- flatpak uninstall -y --noninteractive "$XCLOUD_BROWSER" ||
            warn "uninstall failed"
    fi
    unmark xcloud
    say "Removed. System Updates takes the shortcut out of Steam."
}

# GeForce NOW's own Linux app needs a Vulkan video-decode queue, which the
# BC-250 GPU does not have (it stops with error 0xC0F11312), so it runs in
# Edge at play.geforcenow.com instead, decoding video on the CPU.
gfn_install() {
    say "GeForce NOW (Edge)"
    edge_ensure || return 1
    write_edge_launcher "$REAL_HOME/geforce-now.sh" https://play.geforcenow.com
    mark gfn
    say "Done. System Updates adds \"GeForce NOW\" to your Steam library"
    say "within a few seconds in game mode. Sign in with your NVIDIA account"
    say "the first time. Video is decoded by the CPU on this board."
}

gfn_revert() {
    say "Removing GeForce NOW from Steam"
    rm -f "$REAL_HOME/geforce-now.sh"
    unmark gfn
    say "Removed. System Updates takes the shortcut out of Steam."
}

discord_install() {
    say "Discord"
    discord_client
    _cmd=""
    for _b in discord discord-canary discord-ptb vesktop; do
        command -v "$_b" >/dev/null 2>&1 && { _cmd="$_b"; break; }
    done
    if [ -n "$_cmd" ]; then
        _run="exec $_cmd"
    else
        _id=$(runuser -u "$REAL_USER" -- flatpak list --app --columns=application 2>/dev/null |
            grep -E '^(com\.discordapp\.Discord(Canary|PTB)?|dev\.vencord\.Vesktop|io\.github\.milkshiift\.GoofCord)$' | head -n 1)
        [ -n "$_id" ] || { warn "No Discord client found"; return 1; }
        _run="exec flatpak run $_id"
    fi
    # Discord Deck's "Mute Discord pings": the official client's notification
    # sounds go through Chromium, its voice chat doesn't, so --mute-audio
    # silences only the pings. Vesktop and GoofCord play voice via Chromium.
    _mute=""
    case "$_run" in
        *vesktop* | *Vesktop* | *GoofCord*) ;;
        *) _mute="grep -q '\"mute_sounds\": false' \"\$HOME/homebrew/settings/discord-deck/config.json\" 2>/dev/null || set -- --mute-audio \"\$@\"" ;;
    esac
    cat > "$REAL_HOME/discord.sh" << LAUNCH
#!/bin/sh
# Started from the Steam library in game mode.
unset LD_PRELOAD
$_mute
$_run "\$@"
LAUNCH
    chmod +x "$REAL_HOME/discord.sh"
    chown "$REAL_USER" "$REAL_HOME/discord.sh"
    mark discord
    say "Done. System Updates adds \"Discord\" to your Steam library"
    say "within a few seconds in game mode."
}

discord_revert() {
    say "Removing Discord from Steam"
    rm -f "$REAL_HOME/discord.sh"
    unmark discord
    say "Removed. The Discord app itself stays installed; System Updates"
    say "takes the shortcut out of Steam."
}

# JDownloader 2 (Flatpak). It has no controller support of its own, so
# System Updates gives its Steam shortcut a mouse-style layout: right stick
# moves the pointer, triggers click, left stick scrolls.
JD_APP=org.jdownloader.JDownloader

jd_write_launcher() {
    cat > "$REAL_HOME/jdownloader.sh" << LAUNCH
#!/bin/sh
# Started from the Steam library in game mode.
# gamescope doesn't reparent windows; without this Java draws a blank window.
exec flatpak run --env=_JAVA_AWT_WM_NONREPARENTING=1 $JD_APP "\$@"
LAUNCH
    chmod +x "$REAL_HOME/jdownloader.sh"
    chown "$REAL_USER" "$REAL_HOME/jdownloader.sh"
}

jd_install() {
    say "JDownloader 2"
    if ! flatpak_has "$JD_APP"; then
        command -v flatpak >/dev/null 2>&1 || pacman -S --needed --noconfirm flatpak || return 1
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        flatpak install -y --noninteractive flathub "$JD_APP" || {
            warn "JDownloader install failed"
            return 1
        }
    fi
    jd_write_launcher
    mark jd
    say "Done. System Updates adds \"JDownloader 2\" to your Steam library"
    say "within a few seconds in game mode, with a mouse-style controller layout"
    say "(reconnect the controller once if it still acts as a gamepad)."
    say "The first start downloads JDownloader's own files, so give it a minute."
    say "Downloads go to ~/Downloads."
}

jd_revert() {
    say "Removing JDownloader 2 from Steam"
    rm -f "$REAL_HOME/jdownloader.sh"
    unmark jd
    if flatpak_has "$JD_APP" && confirm "Uninstall JDownloader 2 too?"; then
        flatpak uninstall -y --noninteractive "$JD_APP" 2>/dev/null ||
            runuser -u "$REAL_USER" -- flatpak uninstall -y --noninteractive "$JD_APP" ||
            warn "could not uninstall $JD_APP"
    fi
    say "Removed. System Updates takes the shortcut out of Steam."
}

# Summary for the main menu line.
apps_status() {
    _n=0
    for _a in atv xcloud gfn discord jd; do is_done "$_a" && _n=$((_n + 1)); done
    if [ "$_n" -gt 0 ]; then printf '%s%s %s of 5 installed%s' "$C_GREEN" "$G_ON" "$_n" "$C_RESET"
    else printf '%s%s not installed%s' "$C_DIM" "$G_OFF" "$C_RESET"; fi
}

apps_menu() {
    while :; do
        header "apps"
        printf '  %sEach one is added to your Steam library. Pick an installed one to remove it.%s\n\n' "$C_DIM" "$C_RESET"
        item 1 "Android TV (Waydroid)"   "$(status atv)"
        item 2 "Xbox Cloud Gaming"       "$(status xcloud)"
        item 3 "GeForce NOW"             "$(status gfn)"
        item 4 "Discord"                 "$(status discord)"
        item 5 "JDownloader 2"           "$(status jd)"
        echo
        item b "Back"
        printf '\n  %sChoice:%s ' "$C_CYAN" "$C_RESET"
        read -r c
        case "$c" in
            1) if is_done atv; then
                   if confirm "Remove Android TV?"; then atv_revert || true; fi
               else atv_install || true; fi
               pause ;;
            2) if is_done xcloud; then
                   if confirm "Remove Xbox Cloud Gaming?"; then xcloud_revert || true; fi
               else xcloud_install || true; fi
               pause ;;
            3) if is_done gfn; then
                   if confirm "Remove GeForce NOW from Steam?"; then gfn_revert || true; fi
               else gfn_install || true; fi
               pause ;;
            4) if is_done discord; then
                   if confirm "Remove Discord from Steam?"; then discord_revert || true; fi
               else discord_install || true; fi
               pause ;;
            5) if is_done jd; then
                   if confirm "Remove JDownloader 2 from Steam?"; then jd_revert || true; fi
               else jd_install || true; fi
               pause ;;
            b|B) return ;;
            *) warn "no such option"; sleep 1 ;;
        esac
    done
}

# ======================================================== STEAM LINK RES ====

# Steam Link / Remote Play asks for 1080p, and gamescope's capture crops a 4K
# output to that size instead of scaling it, so the client only sees the
# top-left quarter. This user service watches Steam's streaming log and puts
# the TV output on 1080p for as long as a stream runs, then restores it.
STREAMRES_BIN=/usr/local/bin/bc250-stream-res
STREAMRES_UNIT=/etc/systemd/user/bc250-stream-res.service

streamres_write_files() {
    cat > "$STREAMRES_BIN" << 'SCRIPT'
#!/bin/bash
# Run the TV output at 1080p while a Steam Link / Remote Play stream is on.
# gamescope reads the mode for each display from modes.cfg ("Make Model:WxH@Hz 0",
# the same file Steam's Display > Resolution writes) when the nudge atom is set.
LOG="$HOME/.steam/steam/logs/streaming_log.txt"
MODES="$HOME/.config/gamescope/modes.cfg"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/bc250-stream-res"
MODE="${BC250_STREAM_MODE:-1920x1080@60}"
# A desktop stream stops and a game stream starts when a game launches, so
# only go back to the TV's mode once nothing has restarted for this long.
SETTLE=15

nudge() {
    xprop -display "${DISPLAY:-:0}" -root -f GAMESCOPE_DISPLAY_MODE_NUDGE 32c \
        -set GAMESCOPE_DISPLAY_MODE_NUDGE 1 2>/dev/null
}

# "Make Model" exactly as gamescope keys modes.cfg.
display_key() {
    gamescopectl info 2>/dev/null | awk -F': ' '
        /Display Make:/  { make = $2 }
        /Display Model:/ { model = $2 }
        END { if (make != "" && model != "") print make " " model }'
}

# State file: line 1 is the line we added, the rest are the lines it replaced.
to_stream_mode() {
    [ -e "$STATE" ] && return
    key=$(display_key)
    [ -n "$key" ] || return
    ours="$key:$MODE 0"
    mkdir -p "${STATE%/*}" "${MODES%/*}"
    touch "$MODES"
    grep -qxF -- "$ours" "$MODES" && return
    { printf '%s\n' "$ours"; awk -v k="$key:" 'index($0, k) == 1' "$MODES"; } > "$STATE"
    { awk -v k="$key:" 'index($0, k) != 1' "$MODES"; printf '%s\n' "$ours"; } > "$MODES.tmp" &&
        mv "$MODES.tmp" "$MODES"
    nudge
}

to_tv_mode() {
    [ -e "$STATE" ] || return
    ours=$(head -n 1 "$STATE")
    # Leave the file alone if Steam's resolution picker changed it meanwhile.
    if grep -qxF -- "$ours" "$MODES" 2>/dev/null; then
        { grep -vxF -- "$ours" "$MODES"; tail -n +2 "$STATE"; } > "$MODES.tmp" &&
            mv "$MODES.tmp" "$MODES"
        nudge
    fi
    rm -f "$STATE"
}

# A stream cut off by a reboot or crash leaves the 1080p line behind.
to_tv_mode

pending=0
while :; do
    if [ "$pending" = 1 ]; then wait_s=$SETTLE; else wait_s=3600; fi
    if IFS= read -r -t "$wait_s" line; then
        case "$line" in
            *"Streaming started to "*|*">>> Starting desktop stream"*|*">>> Starting game stream"*)
                pending=0; to_stream_mode ;;
            *">>> Stopped desktop stream"*|*">>> Stopped game stream"*)
                pending=1 ;;
        esac
    elif [ $? -gt 128 ]; then
        if [ "$pending" = 1 ]; then pending=0; to_tv_mode; fi
    else
        exit 1
    fi
done < <(tail -n 0 -F "$LOG" 2>/dev/null)
SCRIPT
    chmod +x "$STREAMRES_BIN"

    cat > "$STREAMRES_UNIT" << 'UNIT'
[Unit]
Description=Steam Link streams at 1080p (TV mode restored afterwards)

[Service]
Type=simple
Environment=DISPLAY=:0
Environment=GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
ExecStart=/usr/local/bin/bc250-stream-res
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
}

# systemctl --user for the desktop user, from this root shell.
user_systemctl() {
    _uid=$(id -u "$REAL_USER")
    runuser -u "$REAL_USER" -- env XDG_RUNTIME_DIR="/run/user/$_uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$_uid/bus" systemctl --user "$@"
}

streamres_install() {
    say "Steam Link at 1080p"
    pacman -S --needed --noconfirm xorg-xprop || return 1
    streamres_write_files
    systemctl --global enable bc250-stream-res.service
    user_systemctl daemon-reload 2>/dev/null || true
    user_systemctl restart bc250-stream-res.service 2>/dev/null ||
        warn "starts at your next login (check: systemctl --user status bc250-stream-res)"
    mark streamres
    say "Done. When Steam Link connects the TV output drops to 1080p so the"
    say "stream shows the whole screen; it goes back about 15 seconds after"
    say "the stream ends."
}

streamres_revert() {
    say "Removing Steam Link at 1080p"
    user_systemctl stop bc250-stream-res.service 2>/dev/null || true
    systemctl --global disable bc250-stream-res.service 2>/dev/null || true
    rm -f "$STREAMRES_UNIT" "$STREAMRES_BIN"
    user_systemctl daemon-reload 2>/dev/null || true
    unmark streamres
    say "Removed."
}

# ======================================================= CLAUDE CODE ========
# Claude Code only updates itself when it is the native install in
# ~/.local/bin; a pacman/AUR or npm copy never does, and stays on whatever
# version it was installed at. This moves it to the native install and adds
# a user timer that runs `claude update` a few times a day, so it is current
# even when Claude Code has not been opened for a while.

CLAUDE_UPD_BIN=/usr/local/bin/bc250-claude-update
CLAUDE_UPD_UNIT=/etc/systemd/user/bc250-claude-update.service
CLAUDE_UPD_TIMER=/etc/systemd/user/bc250-claude-update.timer
CLAUDE_FISH_PATH=/etc/fish/conf.d/bc250-local-bin.fish
CLAUDE_NPM_PKG=@anthropic-ai/claude-code

claude_write_files() {
    cat > "$CLAUDE_UPD_BIN" << 'SCRIPT'
#!/bin/sh
# Update the native Claude Code install; run by bc250-claude-update.timer.
CLAUDE="$HOME/.local/bin/claude"
[ -x "$CLAUDE" ] || { echo "no native Claude Code install at $CLAUDE"; exit 0; }
"$CLAUDE" --version
exec "$CLAUDE" update
SCRIPT
    chmod 755 "$CLAUDE_UPD_BIN"

    mkdir -p "$(dirname "$CLAUDE_UPD_UNIT")"
    cat > "$CLAUDE_UPD_UNIT" << 'UNIT'
[Unit]
Description=Update Claude Code

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bc250-claude-update
UNIT
    cat > "$CLAUDE_UPD_TIMER" << 'UNIT'
[Unit]
Description=Update Claude Code a few times a day

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    # The native launcher lives in ~/.local/bin; make sure fish finds it.
    mkdir -p "$(dirname "$CLAUDE_FISH_PATH")"
    cat > "$CLAUDE_FISH_PATH" << 'FISH'
# Native installs such as Claude Code put their launchers here.
fish_add_path -g $HOME/.local/bin
FISH
}

# Copies of Claude Code that never update themselves: "pacman <pkg>" and
# "npm <who>" lines, one per copy found.
claude_unmanaged() {
    for _f in /usr/bin/claude /usr/local/bin/claude; do
        _p=$(pacman -Qqo "$_f" 2>/dev/null) && echo "pacman $_p"
    done | sort -u
    if command -v npm >/dev/null 2>&1; then
        npm ls -g --depth=0 "$CLAUDE_NPM_PKG" >/dev/null 2>&1 && echo "npm root"
        runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" \
            npm ls -g --depth=0 "$CLAUDE_NPM_PKG" >/dev/null 2>&1 && echo "npm user"
    fi
    return 0
}

claude_install() {
    say "Claude Code auto-update"
    if [ "$REAL_USER" = "root" ]; then
        warn "Claude Code installs into your home directory."
        warn "Run this script with sudo from your normal account, not a root shell."
        return 1
    fi
    pacman -S --needed --noconfirm curl || return 1

    say "Installing the native, self-updating Claude Code as $REAL_USER"
    if ! runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" \
        bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
        warn "The Claude Code installer failed; nothing else was changed."
        return 1
    fi

    # Older copies would keep shadowing the native one on PATH.
    claude_unmanaged | while read -r _how _what; do
        case "$_how" in
            pacman) say "Removing package $_what (it never updates itself)"
                    pacman -Rns --noconfirm "$_what" ||
                        warn "removal failed; try: sudo pacman -Rns $_what" ;;
            npm)    say "Removing the npm copy of Claude Code"
                    if [ "$_what" = root ]; then
                        npm uninstall -g "$CLAUDE_NPM_PKG" ||
                            warn "removal failed; try: sudo npm uninstall -g $CLAUDE_NPM_PKG"
                    else
                        runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" \
                            npm uninstall -g "$CLAUDE_NPM_PKG" ||
                            warn "removal failed; try: npm uninstall -g $CLAUDE_NPM_PKG"
                    fi ;;
        esac
    done

    claude_write_files
    systemctl --global enable bc250-claude-update.timer
    user_systemctl daemon-reload 2>/dev/null || true
    if user_systemctl start bc250-claude-update.timer 2>/dev/null; then
        user_systemctl start bc250-claude-update.service 2>/dev/null || true
    else
        warn "the update timer starts at your next login"
    fi
    mark claude
    _v=$(runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" \
        "$REAL_HOME/.local/bin/claude" --version 2>/dev/null) || _v="unknown"
    say "Done. Claude Code $_v now updates itself, and a timer checks for a"
    say "new version every 6 hours. Close and reopen any running Claude Code"
    say "(including Remote Control) to use the new version."
}

claude_revert() {
    say "Removing Claude Code auto-update"
    user_systemctl stop bc250-claude-update.timer 2>/dev/null || true
    systemctl --global disable bc250-claude-update.timer 2>/dev/null || true
    rm -f "$CLAUDE_UPD_TIMER" "$CLAUDE_UPD_UNIT" "$CLAUDE_UPD_BIN" "$CLAUDE_FISH_PATH"
    user_systemctl daemon-reload 2>/dev/null || true
    unmark claude
    say "Removed the update timer. Claude Code itself stays installed and"
    say "still updates itself while it runs."
}

# ========================================================= CONTROL CENTER ===

# movacx/bc250-control-center — system monitoring, GPU/CPU tuning, CU and fan
# control in one desktop app. Shipped on Arch as an AUR package, so this needs
# an AUR helper; CachyOS ships paru.
# Build an AUR package as the normal user and install it as root, so nothing
# stops to ask for a password. Its dependencies come from the repos first.
aur_build_install() {
    _pkg="$1"
    _work=$(mktemp -d)
    chown "$REAL_USER" "$_work"
    _src="$_work/$_pkg"
    if ! runuser -u "$REAL_USER" -- git clone --depth 1 \
        "https://aur.archlinux.org/$_pkg.git" "$_src"; then
        rm -rf "$_work"
        return 1
    fi
    _deps=$(runuser -u "$REAL_USER" -- sh -c "cd '$_src' && makepkg --printsrcinfo" |
        awk -F' = ' '/^\t(make|check)?depends/ {print $2}' |
        sed 's/[<>=].*//' | sort -u | tr '\n' ' ')
    if [ -n "$_deps" ]; then
        say "Dependencies: $_deps"
        # shellcheck disable=SC2086  # a word list on purpose
        pacman -S --needed --asdeps --noconfirm $_deps ||
            warn "some dependencies could not be installed from the repos"
    fi
    if ! runuser -u "$REAL_USER" -- sh -c \
        "cd '$_src' && makepkg -f --noconfirm --nodeps --noprogressbar"; then
        rm -rf "$_work"
        return 1
    fi
    _rc=0
    for _f in "$_src"/*.pkg.tar.*; do
        case "$_f" in *-debug-*) continue ;; esac
        pacman -U --noconfirm "$_f" || _rc=1
    done
    rm -rf "$_work"
    return "$_rc"
}

ctlcenter_install() {
    say "BC-250 Control Center"

    helper=""
    for h in paru yay pikaur trizen; do
        command -v "$h" >/dev/null 2>&1 && { helper="$h"; break; }
    done

    if [ -z "$helper" ]; then
        warn "No AUR helper found (paru, yay, ...)."
        if confirm "Install paru from the CachyOS repos?"; then
            pacman -S --needed --noconfirm paru || {
                warn "paru is not in the configured repos."
                warn "Install an AUR helper yourself, then run this option again."
                return 1
            }
            helper=paru
        else
            return 1
        fi
    fi
    say "Using $helper"

    # AUR helpers refuse to run as root; drop back to the invoking user, who
    # will be asked for a password when the helper calls sudo to install.
    if [ "$REAL_USER" = "root" ]; then
        warn "Cannot build AUR packages as root."
        warn "Run this script with sudo from your normal account, not a root shell."
        return 1
    fi

    say "Building bc250-control-center-git as $REAL_USER (it will ask for a password)"
    if ! runuser -u "$REAL_USER" -- "$helper" -S --needed bc250-control-center-git; then
        warn "Build failed. Try it by hand to see the error:"
        warn "  $helper -S bc250-control-center-git"
        return 1
    fi

    mark ctlcenter
    say "Done. Launch it from the desktop, then pick \"Prepare dependencies\""
    say "on its dashboard — it installs the governor/fan/CU tools it needs."
}

ctlcenter_revert() {
    say "Removing BC-250 Control Center"
    if pacman -Qq bc250-control-center-git >/dev/null 2>&1; then
        pacman -Rns --noconfirm bc250-control-center-git || \
            warn "removal failed; try: sudo pacman -Rns bc250-control-center-git"
    else
        warn "bc250-control-center-git is not installed."
    fi
    warn "Anything its \"Prepare dependencies\" step installed (oberon-governor,"
    warn "nct6687d-dkms and friends) is left alone — remove those by hand if you"
    warn "want them gone."
    unmark ctlcenter
    say "Removed."
}

# Built from the AUR by Control Center's own "Prepare dependencies" step, not
# by this script, so they are listed here but left to Control Center. umr is
# only built there when the repos cannot provide it.
AUR_PULLED_IN="cyan-skillfish-governor-smu umr umr-git"

aur_menu() {
    while :; do
        header "AUR packages"
        printf '  %sBuilt from the AUR as your user. Pick an installed one to remove it.%s\n\n' "$C_DIM" "$C_RESET"
        item 1 "BC-250 Control Center"   "$(status ctlcenter)"
        printf '     %sbc250-control-center-git — monitoring, GPU/CPU tuning, CU and fan control%s\n' "$C_DIM" "$C_RESET"
        echo
        printf '  %sPulled in by Control Center'"'"'s "Prepare dependencies":%s\n' "$C_DIM" "$C_RESET"
        _shown=no
        for _p in $AUR_PULLED_IN; do
            # umr usually comes from the repos; only an AUR build belongs here.
            if _v=$(pacman -Qm "$_p" 2>/dev/null); then _ok "$_p" "${_v#* }"; _shown=yes; fi
        done
        [ "$_shown" = yes ] || _none "none yet" "run Prepare dependencies in Control Center"
        echo
        item l "List every AUR package on this box"
        item b "Back"
        printf '\n  %sChoice:%s ' "$C_CYAN" "$C_RESET"
        read -r c
        case "$c" in
            1) if is_done ctlcenter; then
                   if confirm "Remove BC-250 Control Center?"; then ctlcenter_revert || true; fi
               else ctlcenter_install || true; fi
               pause ;;
            l|L) aur_list; pause ;;
            b|B) return ;;
            *) warn "no such option"; sleep 1 ;;
        esac
    done
}

# Everything installed that no configured repo provides: AUR builds, plus
# anything installed by hand from a file.
aur_list() {
    say "Packages not from any configured repo (pacman -Qm)"
    _list=$(pacman -Qm 2>/dev/null) || true
    if [ -z "$_list" ]; then
        say "None."
        return 0
    fi
    printf '%s\n' "$_list" | sed 's/^/     /'
}

# ============================================================ QUICK BOOT ====
# Limine's own quiet mode hides the boot menu, and a 1 second timeout boots
# the default entry right away. Pressing a key during that second still
# brings the menu up, for the fallback kernel and snapshots.

limine_conf() {
    _esp=$(sed -n 's/^ESP_PATH="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/default/limine 2>/dev/null | tail -n 1)
    for _c in ${_esp:+"$_esp/limine.conf"} /boot/limine.conf /boot/limine/limine.conf \
        /boot/EFI/limine/limine.conf /efi/limine.conf /efi/EFI/limine/limine.conf; do
        [ -f "$_c" ] && { echo "$_c"; return 0; }
    done
    return 1
}

# Set a global option ("timeout: 1") in limine.conf: replace it where it is,
# or add it at the top, before any entry.
limine_set() {
    _file="$1" _key="$2" _val="$3"
    if grep -q "^[[:space:]]*$_key:" "$_file"; then
        sed -i "s|^[[:space:]]*$_key:.*|$_key: $_val|" "$_file"
    else
        sed -i "1i $_key: $_val" "$_file"
    fi
}

boot_install() {
    say "Quick, quiet boot menu"
    if ! _conf=$(limine_conf); then
        warn "No limine.conf found; this only works with the Limine boot loader."
        return 1
    fi
    # Keep the original settings once, for revert.
    if [ ! -e "$STATE_DIR/boot-original" ]; then
        grep -E '^[[:space:]]*(timeout|quiet):' "$_conf" > "$STATE_DIR/boot-original" || true
    fi
    limine_set "$_conf" timeout 1
    limine_set "$_conf" quiet yes
    mark boot
    say "Done ($_conf). The menu is hidden and boots in 1 second."
    say "Press any key while it starts to show the menu (fallback kernel, snapshots)."
}

boot_revert() {
    say "Restoring the Limine boot menu"
    if ! _conf=$(limine_conf); then
        warn "No limine.conf found."
        unmark boot
        return 0
    fi
    sed -i '/^[[:space:]]*quiet:/d; /^[[:space:]]*timeout:/d' "$_conf"
    if [ -s "$STATE_DIR/boot-original" ]; then
        # Back at the top, where global options belong.
        _tmp=$(mktemp)
        cat "$STATE_DIR/boot-original" "$_conf" > "$_tmp" && cat "$_tmp" > "$_conf"
        rm -f "$_tmp"
    else
        limine_set "$_conf" timeout 5
    fi
    rm -f "$STATE_DIR/boot-original"
    unmark boot
    say "Restored."
}

# ============================================================ EXPERIMENTS ===
# Trial fixes, kept apart so they're easy to take back out.

# TV 4K fix. With the TV off when the board boots, the CH7218 adapter hands
# out its own 1080p-only EDID ("CH7218") and keeps it after the TV comes on,
# so the picture stays at 1080p and the Samsung overscans it (looks zoomed).
# That EDID carries no CEC address, so the TV can't be heard turning on, and
# the adapter sends no hotplug. This patches a copy of the daemon to count
# the Samsung's "to-on" as on and to replug while the EDID is the adapter's
# fallback. A timed replug (FALLBACK_PROBE_S) is included but off by default:
# a software hotplug does not make the CH7218 re-read the EDID.
# The package's own file is left alone; a systemd drop-in points the
# service at the copy.
CECFIX_SRC=/usr/lib/bc250-cec/bc250-cec-daemon.sh
CECFIX_SRC_SHA=c86c2e4837b772569951b352b6c2b423d15b72c4462ae52512bba7db7070872c
CECFIX_TARGET=/usr/local/lib/bc250-cec/bc250-cec-daemon.sh
CECFIX_DROPIN_DIR=/etc/systemd/system/bc250-cec.service.d
CECFIX_DROPIN=$CECFIX_DROPIN_DIR/10-bc250-setup-tv-4k.conf

# Against bc250-cec 1-17's daemon (sha256 above).
cecfix_patch() {
    cat << 'CECFIX_PATCH'
--- bc250-cec-daemon.sh.orig
+++ bc250-cec-daemon.sh
@@ -116,6 +116,31 @@
 # visible across them, but a file is. RuntimeDirectory=bc250-cec in the
 # unit creates this, root-owned, cleaned up on stop.
 readonly TRIGGER_STATE_FILE="${BC250_CEC_TRIGGER_STATE_FILE:-/run/bc250-cec/last-trigger}"
+# The CH7218 serves its own built-in EDID (product name "CH7218", a single
+# 1920x1080@60 mode, no CEC physical address) whenever the display behind
+# it was off or unreachable when the board read the EDID -- e.g. TV off at
+# boot. It never raises a hotplug once the TV comes back, and a retrain
+# does not re-read the EDID, so the board stays at 1080p and the TV
+# upscales it (the "zoomed in" picture). Seen on hardware 2026-10-08: TV
+# on at 16:11, board still on the CH7218 EDID until the cable was
+# replugged. While the connector's EDID carries this product name, every
+# relink is a full replug instead, retried a few times since the TV's
+# HDMI input can come up a few seconds after it answers CEC. Empty
+# disables the check.
+readonly FALLBACK_EDID_NAME="${BC250_CEC_FALLBACK_EDID_NAME:-CH7218}"
+readonly FALLBACK_REPLUG_ATTEMPTS="${BC250_CEC_FALLBACK_REPLUG_ATTEMPTS:-3}"
+readonly FALLBACK_REPLUG_DELAY_S="${BC250_CEC_FALLBACK_REPLUG_DELAY_S:-4}"
+# While the fallback EDID is in use the board has no CEC physical address
+# (f.f.f.f), so the TV's power state cannot be read and no CEC event
+# announces it turning on; the adapter raises no hotplug either. The poll
+# loop therefore replugs on a timer while the fallback EDID is present:
+# every FALLBACK_PROBE_S seconds for the first FALLBACK_PROBE_FAST_FOR_S
+# seconds, then every FALLBACK_PROBE_SLOW_S. 0 disables the timer, the
+# default: on the CH7218 a debugfs hotplug blanks the picture but does not
+# make the adapter re-read the TV's EDID (tested 2026-10-09).
+readonly FALLBACK_PROBE_S="${BC250_CEC_FALLBACK_PROBE_S:-0}"
+readonly FALLBACK_PROBE_FAST_FOR_S="${BC250_CEC_FALLBACK_PROBE_FAST_FOR_S:-600}"
+readonly FALLBACK_PROBE_SLOW_S="${BC250_CEC_FALLBACK_PROBE_SLOW_S:-60}"
 
 log() { printf 'bc250-cec: %s\n' "$1"; }
 
@@ -156,9 +181,69 @@
     find_debugfs_file "$connector" trigger_hotplug
 }
 
-# Retrain or replug, depending on which file find_relink_path() returned.
+# True while the connector's EDID is the CH7218's own fallback rather than
+# the display's (see FALLBACK_EDID_NAME). The connector's sysfs directory is
+# globbed like the debugfs one, so the card number is not hardcoded.
+edid_is_fallback() {
+    local connector="$1" edid
+    [[ -n "$FALLBACK_EDID_NAME" ]] || return 1
+    for edid in /sys/class/drm/card*-"$connector"/edid; do
+        [[ -e "$edid" ]] || continue
+        grep -aqF "$FALLBACK_EDID_NAME" "$edid" && return 0
+    done
+    return 1
+}
+
+# Replug until the board reads the display's own EDID, or give up after
+# FALLBACK_REPLUG_ATTEMPTS. A replug is what makes the board re-read the
+# EDID, and gamescope then picks the display's real mode on its own. One
+# wake keypress afterwards for Steam's black-screen-after-replug quirk
+# (see WAKE_KEY), since this is a full replug whatever RELINK_METHOD says.
+replug_off_fallback_edid() {
+    local connector="$1" hotplug_path attempt
+    hotplug_path="$(find_debugfs_file "$connector" trigger_hotplug)" || {
+        log "no trigger_hotplug for $connector; cannot leave the fallback EDID"
+        return 1
+    }
+    for (( attempt = 1; attempt <= FALLBACK_REPLUG_ATTEMPTS; attempt++ )); do
+        log "$connector has the adapter's fallback EDID ($FALLBACK_EDID_NAME); replugging (attempt $attempt/$FALLBACK_REPLUG_ATTEMPTS)"
+        echo 1 > "$hotplug_path" || log "failed to write $hotplug_path"
+        sleep "$FALLBACK_REPLUG_DELAY_S"
+        if ! edid_is_fallback "$connector"; then
+            log "$connector now has the display's own EDID"
+            inject_wake_key
+            return 0
+        fi
+    done
+    log "$connector still has the fallback EDID after $FALLBACK_REPLUG_ATTEMPTS replugs; giving up until the next trigger"
+    return 1
+}
+
+# One timed replug while the connector has the fallback EDID (see
+# FALLBACK_PROBE_S). Quiet while it stays on the fallback, since the TV is
+# usually just off; logs and sends the wake key once the display's own
+# EDID is back.
+probe_off_fallback_edid() {
+    local connector="$1" hotplug_path
+    hotplug_path="$(find_debugfs_file "$connector" trigger_hotplug)" || return 1
+    echo 1 > "$hotplug_path" || { log "failed to write $hotplug_path"; return 1; }
+    sleep "$FALLBACK_REPLUG_DELAY_S"
+    if edid_is_fallback "$connector"; then
+        return 1
+    fi
+    log "$connector now has the display's own EDID"
+    inject_wake_key
+    return 0
+}
+
+# Retrain or replug, depending on which file find_relink_path() returned --
+# or a replug regardless, while the connector is stuck on the fallback EDID.
 relink() {
     local trigger_path="$1" connector="$2"
+    if edid_is_fallback "$connector"; then
+        replug_off_fallback_edid "$connector" || true
+        return 0
+    fi
     case "$trigger_path" in
         */link_settings)
             log "retraining the link on $connector"
@@ -218,7 +303,11 @@
         claim_logical_address "$dev"
         out="$(cec-ctl -d "$dev" --to "$TV_LOGICAL_ADDRESS" --give-device-power-status 2>&1)" || true
     fi
-    if grep -qE 'pwr-state: on\b' <<<"$out"; then
+    # "to-on" counts as on: a Samsung TV keeps answering "to-on" (in
+    # transition standby -> on) indefinitely while fully on -- seen on
+    # hardware 2026-10-08, every reply for 15 hours -- so waiting for a
+    # plain "on" never saw it power on at all.
+    if grep -qE 'pwr-state: (on|to-on)\b' <<<"$out"; then
         printf 'on\n'
     elif grep -qE 'pwr-state: standby\b' <<<"$out"; then
         printf 'off\n'
@@ -360,7 +449,8 @@
 # glitch the picture or spuriously fire a power-off command.
 poll_power_loop() {
     local cec_dev="$1" trigger_path="$2" connector="$3" own_addr="$4"
-    local state prev_state="" baseline_set=0
+    local state prev_state="" baseline_set=0
+    local fallback_since=-1 fallback_last=0 probe_every
 
     while :; do
         state="$(query_power_state "$cec_dev")"
@@ -382,6 +472,26 @@
             log "baseline display power state: $state"
         fi
 
+        # Fallback EDID: replug on a timer until the display's own EDID
+        # appears (see FALLBACK_PROBE_S). Unseen while the TV is off.
+        if (( FALLBACK_PROBE_S > 0 )) && edid_is_fallback "$connector"; then
+            if (( fallback_since < 0 )); then
+                fallback_since=$SECONDS
+                fallback_last=$SECONDS
+                log "$connector has the adapter's fallback EDID ($FALLBACK_EDID_NAME); replugging every ${FALLBACK_PROBE_S}s until the display's own EDID appears"
+            fi
+            probe_every=$FALLBACK_PROBE_S
+            if (( SECONDS - fallback_since >= FALLBACK_PROBE_FAST_FOR_S )); then
+                probe_every=$FALLBACK_PROBE_SLOW_S
+            fi
+            if (( SECONDS - fallback_last >= probe_every )); then
+                fallback_last=$SECONDS
+                probe_off_fallback_edid "$connector" || true
+            fi
+        else
+            fallback_since=-1
+        fi
+
         baseline_set=1
         prev_state="$state"
         sleep "$POLL_INTERVAL_S"
@@ -414,6 +524,16 @@
     log "watching for active-source switches to $own_addr"
 
     while :; do
+        # The physical address comes from the display's EDID, so it changes
+        # under us: f.f.f.f while the adapter serves its fallback EDID, the
+        # real one after a replug (which is also what makes cec-ctl -m exit
+        # and land back here). Seen on hardware 2026-10-08: f.f.f.f all day.
+        local addr
+        addr="$(own_physical_address "$cec_dev")"
+        if [[ -n "$addr" && "$addr" != "$own_addr" ]]; then
+            own_addr="$addr"
+            log "physical address is now $own_addr"
+        fi
         pending=0
         # cec-ctl -m prints each message opcode on one line and its fields
         # (e.g. "phys-addr: 2.3.0.0") on the following indented lines --
CECFIX_PATCH
}

cecfix_restart() {
    systemctl daemon-reload
    if systemctl is-active --quiet bc250-cec.service; then
        systemctl restart bc250-cec.service
    fi
}

cecfix_install() {
    say "TV 4K fix (experiment)"
    if [ ! -f "$CECFIX_SRC" ]; then
        warn "bc250-cec isn't installed ($CECFIX_SRC missing); nothing to patch."
        return 1
    fi
    _sum=$(sha256sum "$CECFIX_SRC" | cut -d' ' -f1)
    if [ "$_sum" != "$CECFIX_SRC_SHA" ]; then
        warn "bc250-cec has been updated since this fix was written, so it"
        warn "can't be applied safely. The packaged version stays in use."
        if is_done cecfix; then
            warn "Removing the old fix so the updated package runs as shipped."
            cecfix_revert
        fi
        return 1
    fi
    command -v patch >/dev/null 2>&1 || pacman -S --needed --noconfirm patch
    _dir=$(mktemp -d)
    cecfix_patch > "$_dir/fix.patch"
    if ! patch -s --fuzz=0 -o "$_dir/daemon.sh" "$CECFIX_SRC" "$_dir/fix.patch" >/dev/null 2>&1 ||
       ! bash -n "$_dir/daemon.sh"; then
        rm -rf "$_dir"
        warn "The patch didn't apply cleanly; nothing was changed."
        return 1
    fi
    install -Dm755 "$_dir/daemon.sh" "$CECFIX_TARGET"
    rm -rf "$_dir"
    mkdir -p "$CECFIX_DROPIN_DIR"
    cat > "$CECFIX_DROPIN" << DROPIN
# Written by bc250-setup.sh (Experiments > TV 4K fix). Remove it from the
# same menu. Runs a patched copy of the packaged daemon.
[Service]
ExecStart=
ExecStart=$CECFIX_TARGET
DROPIN
    cecfix_restart
    mark cecfix
    say "Installed. To try it: TV off, restart the box, then turn the TV on"
    say "once it's up. Expect one quick blink, then 4K."
}

cecfix_revert() {
    say "Removing the TV 4K fix"
    rm -f "$CECFIX_DROPIN" "$CECFIX_TARGET"
    rmdir "$CECFIX_DROPIN_DIR" /usr/local/lib/bc250-cec 2>/dev/null || true
    cecfix_restart
    unmark cecfix
    say "Done. bc250-cec runs the packaged version again."
}

experiments_menu() {
    while :; do
        header "experiments"
        printf '  %sTrial fixes. Pick one again to remove it.%s\n\n' "$C_DIM" "$C_RESET"
        item 1 "TV 4K fix (TV off at boot)" "$(status cecfix)"
        echo
        item b "Back"
        printf '\n  %sChoice:%s ' "$C_CYAN" "$C_RESET"
        read -r c
        case "$c" in
            1) if is_done cecfix; then
                   if confirm "Remove the TV 4K fix?"; then cecfix_revert || true; fi
               else
                   say "If the TV was off when the box started, the picture can get"
                   say "stuck at 1080p and look zoomed in. This makes the box notice"
                   say "the TV turning on and re-read it, so it goes back to 4K."
                   if confirm "Install it?"; then cecfix_install || true; fi
               fi
               pause ;;
            b|B) return ;;
            *) warn "no such option"; sleep 1 ;;
        esac
    done
}

# ================================================================= DECKY ====

DECKY_DIR="$REAL_HOME/homebrew/plugins"

# System packages a bundled plugin needs outside Decky. Keep in step with the
# "packages" lists in plugins/versions.json, which System Updates installs.
plugin_packages() {
    case "$1" in
        # GTK under the system Python draws the speaking overlay; qrencode
        # draws the phone-setup QR code.
        discord-deck) echo "python-gobject python-cairo gtk3 xorg-xprop qrencode" ;;
        cec-remote)   echo "v4l-utils" ;;
    esac
}

plugin_packages_install() {
    _pp=$(plugin_packages "$1")
    [ -n "$_pp" ] || return 0
    # shellcheck disable=SC2086  # a word list on purpose
    pacman -S --needed --noconfirm $_pp ||
        warn "could not install $_pp for $(embedded_label "$1")"
}

# Plugins carried inside this script (see the payload section at the end).
EMBEDDED_PLUGINS="bc250-lighting system-updates discord-deck cec-remote bc250-performance"

embedded_label() {
    case "$1" in
        bc250-lighting) echo "BC-250 Lighting (LED strip + fan zones, idle off)" ;;
        system-updates) echo "System Updates (CachyOS updates from game mode)" ;;
        discord-deck) echo "Discord Deck (voice chat, audio devices, speaking overlay)" ;;
        cec-remote) echo "CEC Remote (TV/soundbar volume, power, input)" ;;
        bc250-performance) echo "BC-250 Performance (SMT and CPU performance mode toggles)" ;;
    esac
}

# Plugins that are not in the Decky store, fetched from their own GitHub
# releases at install time rather than bundled, so you always get the
# current one. Each line: owner/repo|plugin folder|label.
GITHUB_PLUGINS="moi952/decky-quick-tab|decky-quick-tab|Quick Tab (pin plugins as their own Quick Access tabs)"

# The "version" field of the package.json on stdin.
pkg_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1
}

# Version of an installed plugin folder, empty when it is not installed.
installed_version() {
    [ -f "$DECKY_DIR/$1/package.json" ] || return 0
    pkg_version < "$DECKY_DIR/$1/package.json"
}

# True when version $1 is newer than version $2.
version_newer() {
    [ "$1" != "$2" ] &&
        [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Newest release of one GitHub plugin: version and zip URL, tab-separated.
github_info() {
    _json=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null) || return 1
    _url=$(printf '%s\n' "$_json" |
        grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.zip"' |
        head -n 1 | sed 's/.*"\(https[^"]*\)"$/\1/')
    _tag=$(printf '%s\n' "$_json" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$_url" ] || return 1
    printf '%s\t%s\n' "$_tag" "$_url"
}

# Download one GitHub plugin release zip and install it.
github_plugin_install() {
    _url="$1" _label="$2"
    _tmp=$(mktemp -d)
    say "downloading $(basename "$_url")"
    if ! curl -fsSL -o "$_tmp/plugin.zip" "$_url" || ! unzip -tq "$_tmp/plugin.zip" >/dev/null 2>&1; then
        warn "download of $_label failed"
        rm -rf "$_tmp"
        return 1
    fi
    _rc=0
    install_plugin_zip "$_tmp/plugin.zip" || _rc=1
    rm -rf "$_tmp"
    return $_rc
}

# Plugins from the official Decky store. Installed the way Decky's own store
# does it (same zip, checked against the store's sha256), so Decky offers
# their updates as usual afterwards. Each line is the store name.
STORE_PLUGINS="ProtonDB Badges
CSS Loader"
STORE_URL="https://plugins.deckbrew.xyz/plugins"
STORE_CDN="https://cdn.tzatzikiweeb.moe/file/steam-deck-homebrew/versions"

# Folder of the installed plugin whose plugin.json carries this name, the
# way Decky matches store plugins. Empty when it is not installed.
store_plugin_dir() {
    for _f in "$DECKY_DIR"/*/plugin.json; do
        [ -f "$_f" ] || continue
        if grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$1\"" "$_f"; then
            dirname "$_f"
            return 0
        fi
    done
}

# Version, sha256 and download URL of one plugin in the store listing $1,
# tab-separated. Fails when it isn't listed.
store_info() {
    python3 - "$1" "$2" << 'PY'
import json, sys
try:
    plugins = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
for p in plugins:
    if p.get("name") == sys.argv[2] and p.get("versions"):
        v = p["versions"][0]
        print(v["name"].lstrip("v"), v["hash"], v.get("artifact") or "", sep="\t")
        sys.exit(0)
sys.exit(1)
PY
}

# Install one store plugin: name, sha256, download URL.
store_plugin_install() {
    _name="$1" _hash="$2" _url="$3"
    [ -n "$_url" ] || _url="$STORE_CDN/$_hash.zip"
    _old=$(store_plugin_dir "$_name")
    _tmp=$(mktemp -d)
    if ! curl -fsSL -o "$_tmp/plugin.zip" "$_url"; then
        warn "download of $_name failed"
        rm -rf "$_tmp"
        return 1
    fi
    if [ "$(sha256sum "$_tmp/plugin.zip" | cut -d' ' -f1)" != "$_hash" ]; then
        warn "$_name download does not match the store's checksum; not installed"
        rm -rf "$_tmp"
        return 1
    fi
    # Clear the old copy first in case it sits under another folder name.
    if [ -n "$_old" ]; then
        rm -rf "${_old:?}"
    fi
    _dir=$(unzip -Z1 "$_tmp/plugin.zip" 2>/dev/null | head -n 1 | cut -d/ -f1)
    _rc=0
    install_plugin_zip "$_tmp/plugin.zip" || _rc=1
    rm -rf "$_tmp"
    [ "$_rc" -eq 0 ] || return 1

    # A few store plugins list extra binaries in package.json for Decky to
    # fetch at install time. Do the same, hash-checked.
    if [ -n "$_dir" ] && grep -q '"remote_binary"' "$DECKY_DIR/$_dir/package.json" 2>/dev/null; then
        python3 - "$DECKY_DIR/$_dir" << 'PY' || warn "$_name: extra downloads failed; it may not work"
import hashlib, json, os, sys, urllib.request
base = sys.argv[1]
pkg = json.load(open(os.path.join(base, "package.json")))
os.makedirs(os.path.join(base, "bin"), exist_ok=True)
for item in pkg.get("remote_binary", []):
    data = urllib.request.urlopen(item["url"], timeout=120).read()
    if hashlib.sha256(data).hexdigest() != item["sha256hash"]:
        sys.exit(f"checksum mismatch for {item['name']}")
    with open(os.path.join(base, "bin", item["name"]), "wb") as out:
        out.write(data)
PY
    fi

    # Ownership as Decky's store sets it: contents belong to you unless the
    # plugin asks to run as root; the folder and plugin.json stay root's.
    if [ -n "$_dir" ] && [ -d "$DECKY_DIR/$_dir" ]; then
        if ! grep -q '"root"' "$DECKY_DIR/$_dir/plugin.json" 2>/dev/null; then
            chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$DECKY_DIR/$_dir"
        fi
        chown root:root "$DECKY_DIR/$_dir" "$DECKY_DIR/$_dir/plugin.json"
        chmod -R 755 "$DECKY_DIR/$_dir"
    fi
    return 0
}

# Discord Deck needs a Discord application's client ID and secret. Typing two
# long strings into a text field with a controller is miserable, so offer to
# write them straight into the plugin's settings file here instead.
DISCORD_SETTINGS_DIR="$REAL_HOME/homebrew/settings/discord-deck"

discord_credentials() {
    _cfg="$DISCORD_SETTINGS_DIR/config.json"

    if [ -f "$_cfg" ] && grep -q '"client_secret"[[:space:]]*:[[:space:]]*"[^"]' "$_cfg" 2>/dev/null; then
        say "Discord credentials are already set — leaving them alone."
        return 0
    fi

    echo
    echo "  Discord Deck needs its own Discord application."
    echo "  Takes about a minute, on a phone or laptop:"
    echo
    echo "    1. Open  https://discord.com/developers/applications"
    echo "    2. New Application -> give it any name -> Create"
    echo "    3. OAuth2 (left sidebar)"
    echo "    4. Under Redirects, Add Redirect:  http://localhost"
    echo "       then Save Changes at the bottom"
    echo "    5. Copy the CLIENT ID from that page"
    echo "    6. Next to Client Secret, press Reset Secret, then copy it"
    echo
    echo "  Easier: leave these blank and use \"Set up with your phone\" in"
    echo "  Discord Deck. It shows a QR code and you paste them on your phone."
    echo

    printf '  Client ID: '
    read -r _cid
    printf '  Client secret: '
    read -r _csec

    if [ -z "$_cid" ] || [ -z "$_csec" ]; then
        warn "Skipped. Set them up from Discord Deck when you're ready."
        return 0
    fi

    mkdir -p "$DISCORD_SETTINGS_DIR"
    cat > "$_cfg" << JSON
{
  "client_id": "$_cid",
  "client_secret": "$_csec"
}
JSON
    chmod 600 "$_cfg"
    chown -R "$REAL_USER" "$REAL_HOME/homebrew/settings" 2>/dev/null || true
    say "Saved. The plugin will pick them up; press Authorize on first launch."
}

# Discord Deck drives the Discord app, so make sure one is installed. Any
# Flatpak or native client the plugin knows counts; otherwise install Arch's.
discord_client() {
    for _b in discord discord-canary discord-ptb vesktop; do
        command -v "$_b" >/dev/null 2>&1 && return 0
    done
    if command -v flatpak >/dev/null 2>&1 &&
        runuser -u "$REAL_USER" -- flatpak list --app --columns=application 2>/dev/null |
        grep -qE '^(com\.discordapp\.Discord(Canary|PTB)?|dev\.vencord\.Vesktop|io\.github\.milkshiift\.GoofCord)$'; then
        return 0
    fi
    say "Installing Discord"
    pacman -S --needed --noconfirm discord ||
        warn "could not install Discord; install it yourself before using Discord Deck"
}

# Unpack one zip into DECKY_DIR, recording every plugin folder it contained.
install_plugin_zip() {    _zip="$1"
    mkdir -p "$DECKY_DIR"
    _tmp=$(mktemp -d)
    if ! unzip -q -o "$_zip" -d "$_tmp"; then
        warn "could not unzip $(basename "$_zip")"
        rm -rf "$_tmp"
        return 1
    fi
    for _d in "$_tmp"/*; do
        [ -d "$_d" ] || continue
        _name=$(basename "$_d")
        rm -rf "${DECKY_DIR:?}/$_name"
        cp -a "$_d" "$DECKY_DIR/$_name"
        # Decky requires plugin directories to be root-owned.
        chown -R root:root "$DECKY_DIR/$_name"
        printf '%s\n' "$_name" >> "$STATE_DIR/decky-plugins"
        say "installed $_name"
    done
    rm -rf "$_tmp"
    return 0
}

# Install one plugin bundled in this script.
embedded_plugin_install() {
    _stage=$(mktemp -d)
    if ! embed_payload "$1" "$_stage/$1.zip"; then
        warn "could not unpack the bundled $1"
        rm -rf "$_stage"
        return 1
    fi
    _rc=0
    install_plugin_zip "$_stage/$1.zip" || _rc=1
    rm -rf "$_stage"
    [ "$_rc" -eq 0 ] || return 1
    plugin_packages_install "$1"
    if [ "$1" = "discord-deck" ]; then
        # Nobody can type the credentials in from Game Mode; the plugin's
        # own phone setup page asks for them instead.
        [ -n "${UNATTENDED:-}" ] || discord_credentials
        discord_client
    fi
    return 0
}

DECKY_CATALOG="$STATE_DIR/.decky-catalog"

# Every plugin on offer, one per line, tab-separated:
#   source  id  name  folder  version-on-offer  url  hash
# Bundled plugins are read from this script; GitHub and the Decky store are
# asked once, so the menu doesn't wait on the network every time it redraws.
decky_catalog() {
    : > "$DECKY_CATALOG"
    _stage=$(mktemp -d)
    for _p in $EMBEDDED_PLUGINS; do
        embed_payload "$_p" "$_stage/p.zip" 2>/dev/null || continue
        _dir=$(unzip -Z1 "$_stage/p.zip" 2>/dev/null | head -n 1 | cut -d/ -f1)
        _ver=$(unzip -p "$_stage/p.zip" "$_dir/package.json" 2>/dev/null | pkg_version)
        _lab=$(embedded_label "$_p")
        printf 'bundled\t%s\t%s\t%s\t%s\t\t\n' "$_p" "${_lab%% (*}" "$_dir" "$_ver" >> "$DECKY_CATALOG"
    done
    rm -rf "$_stage"
    _old_ifs=$IFS
    IFS='
'
    for _line in $GITHUB_PLUGINS; do
        IFS=$_old_ifs
        _g_repo=${_line%%|*}
        _g_rest=${_line#*|}
        _g_lab=${_g_rest#*|}
        _info=$(github_info "$_g_repo") || _info="	"
        printf 'github\t%s\t%s\t%s\t%s\t%s\t\n' "$_g_repo" "${_g_lab%% (*}" "${_g_rest%%|*}" \
            "$(printf '%s' "$_info" | cut -f1)" "$(printf '%s' "$_info" | cut -f2)" >> "$DECKY_CATALOG"
    done
    _list=$(mktemp)
    curl -fsSL -o "$_list" "$STORE_URL" 2>/dev/null || : > "$_list"
    IFS='
'
    for _s in $STORE_PLUGINS; do
        IFS=$_old_ifs
        _info=$(store_info "$_list" "$_s") || _info="		"
        printf 'store\t%s\t%s\t\t%s\t%s\t%s\n' "$_s" "$_s" \
            "$(printf '%s' "$_info" | cut -f1)" "$(printf '%s' "$_info" | cut -f3)" \
            "$(printf '%s' "$_info" | cut -f2)" >> "$DECKY_CATALOG"
    done
    IFS=$_old_ifs
    rm -f "$_list"
}

# Field $2 of catalog line $1.
cat_field() { sed -n "${1}p" "$DECKY_CATALOG" | cut -f"$2"; }

# Installed folder of catalog line $1, empty when it isn't installed.
cat_installed_dir() {
    if [ "$(cat_field "$1" 1)" = store ]; then
        store_plugin_dir "$(cat_field "$1" 2)"
    else
        _d=$(cat_field "$1" 4)
        [ -d "$DECKY_DIR/$_d" ] && echo "$DECKY_DIR/$_d"
    fi
    return 0
}

# Installed version of catalog line $1, empty when it isn't installed.
cat_installed_version() {
    _idir=$(cat_installed_dir "$1")
    [ -n "$_idir" ] || return 0
    _v=$(pkg_version < "$_idir/package.json" 2>/dev/null) || _v=""
    echo "${_v:-0}"
}

# missing / update / current / unknown for catalog line $1.
cat_state() {
    _cv=$(cat_installed_version "$1")
    _new=$(cat_field "$1" 5)
    if [ -z "$_cv" ]; then
        if [ -n "$_new" ]; then echo missing; else echo unknown; fi
    elif [ -n "$_new" ] && version_newer "$_new" "$_cv"; then echo update
    else echo current; fi
}

cat_status_text() {
    _cur=$(cat_installed_version "$1")
    case "$(cat_state "$1")" in
        missing) printf '%s%s not installed (v%s)%s' "$C_DIM" "$G_OFF" "$(cat_field "$1" 5)" "$C_RESET" ;;
        update)  printf '%s%s update: v%s -> v%s%s' "$C_YELLOW" "$G_ON" "${_cur:-?}" "$(cat_field "$1" 5)" "$C_RESET" ;;
        current) printf '%s%s v%s, up to date%s' "$C_GREEN" "$G_ON" "${_cur:-?}" "$C_RESET" ;;
        *)       printf '%s%s not installed (offline?)%s' "$C_DIM" "$G_OFF" "$C_RESET" ;;
    esac
}

# Install or update catalog line $1. True on success.
cat_install() {
    _id=$(cat_field "$1" 2)
    case "$(cat_field "$1" 1)" in
        bundled) embedded_plugin_install "$_id" ;;
        github)
            _u=$(cat_field "$1" 6)
            [ -n "$_u" ] || { warn "could not reach $_id releases"; return 1; }
            github_plugin_install "$_u" "$(cat_field "$1" 3)" ;;
        store)
            _h=$(cat_field "$1" 7)
            [ -n "$_h" ] || { warn "could not reach the Decky store"; return 1; }
            store_plugin_install "$_id" "$_h" "$(cat_field "$1" 6)" ;;
    esac
}

# Remove the installed copy of catalog line $1.
cat_remove() {
    _idir=$(cat_installed_dir "$1")
    [ -n "$_idir" ] || return 0
    rm -rf "${_idir:?}"
    if [ -f "$STATE_DIR/decky-plugins" ]; then
        grep -vxF "$(basename "$_idir")" "$STATE_DIR/decky-plugins" > "$STATE_DIR/.decky-keep" || true
        mv "$STATE_DIR/.decky-keep" "$STATE_DIR/decky-plugins"
    fi
    say "removed $(cat_field "$1" 3)"
}

# Plugin zips you downloaded yourself.
decky_install_zips() {
    printf 'Folder holding the .zip files [%s/Downloads]: ' "$REAL_HOME"
    read -r zipdir
    [ -n "$zipdir" ] || zipdir="$REAL_HOME/Downloads"
    if [ ! -d "$zipdir" ]; then
        warn "No such directory: $zipdir"
        return 1
    fi
    _found=0 _zi=0
    for z in "$zipdir"/*.zip; do
        [ -e "$z" ] || continue
        _found=1
        printf '  install %s ? [y/N] ' "$(basename "$z")"
        read -r ans
        case "$ans" in
            y|Y|yes|YES) install_plugin_zip "$z" && _zi=1 ;;
        esac
    done
    [ "$_found" -eq 0 ] && warn "No .zip files found in $zipdir"
    [ "$_zi" -eq 1 ]
}

# Decky Loader has to be there first; offer it when it isn't.
decky_ready() {
    decky_present && return 0
    warn "Decky Loader isn't installed; the plugins need it."
    confirm "Install Decky Loader now?" || return 1
    decky_loader_install
}

# Install everything missing and update everything out of date, no questions.
decky_install() {
    say "Decky plugins"
    decky_ready || return 1
    pacman -S --needed --noconfirm unzip
    say "Checking what's on offer"
    decky_catalog
    _changed=0
    _n=$(wc -l < "$DECKY_CATALOG")
    _i=1
    while [ "$_i" -le "$_n" ]; do
        case "$(cat_state "$_i")" in
            missing|update) cat_install "$_i" && _changed=1 ;;
        esac
        _i=$((_i + 1))
    done
    decky_finish
}

# Restart Decky when something changed so it loads the new plugins.
decky_finish() {
    rm -f "$DECKY_CATALOG"
    mark decky
    if [ "$_changed" -eq 1 ]; then
        systemctl restart plugin_loader 2>/dev/null ||
            warn "Could not restart plugin_loader. Restart Decky or reboot."
        say "Done. Plugins appear in the Decky menu in game mode."
    else
        say "Nothing changed."
    fi
}

decky_menu() {
    decky_ready || { pause; return; }
    pacman -S --needed --noconfirm unzip >/dev/null 2>&1 || true
    say "Checking what's on offer"
    decky_catalog
    _changed=0
    while :; do
        header "decky plugins"
        printf '  %sPick one to install or update it; pick an up-to-date one to remove it.%s\n\n' "$C_DIM" "$C_RESET"
        _n=$(wc -l < "$DECKY_CATALOG")
        _i=1
        while [ "$_i" -le "$_n" ]; do
            item "$_i" "$(cat_field "$_i" 3)" "$(cat_status_text "$_i")"
            _i=$((_i + 1))
        done
        echo
        item a "Install / update all that need it"
        item z "Install plugin zips from a folder"
        item b "Back"
        printf '\n  %sChoice:%s ' "$C_CYAN" "$C_RESET"
        read -r c
        case "$c" in
            a|A) _i=1
                 while [ "$_i" -le "$_n" ]; do
                     case "$(cat_state "$_i")" in
                         missing|update) cat_install "$_i" && _changed=1 ;;
                     esac
                     _i=$((_i + 1))
                 done
                 pause ;;
            z|Z) decky_install_zips && _changed=1; pause ;;
            b|B) decky_finish; return ;;
            *[!0-9]*|'') warn "no such option"; sleep 1 ;;
            *) if [ "$c" -ge 1 ] && [ "$c" -le "$_n" ]; then
                   _label=$(cat_field "$c" 3)
                   case "$(cat_state "$c")" in
                       missing) confirm "Install $_label?" && cat_install "$c" && _changed=1 ;;
                       update)  confirm "Update $_label to v$(cat_field "$c" 5)?" && cat_install "$c" && _changed=1 ;;
                       current) confirm "$_label is up to date. Remove it?" && { cat_remove "$c"; _changed=1; } ;;
                       *) warn "$_label couldn't be checked; are you online?" ;;
                   esac
                   pause
               else
                   warn "no such option"; sleep 1
               fi ;;
        esac
    done
}

decky_revert() {
    say "Removing Decky plugins"
    if [ ! -s "$STATE_DIR/decky-plugins" ]; then
        warn "No record of plugins installed by this script."
        decky_loader_revert
        return 0
    fi
    # Read names on fd 3 so plugin folder names containing spaces survive and
    # the prompt below can still read the answer from stdin.
    sort -u "$STATE_DIR/decky-plugins" > "$STATE_DIR/.decky-names"
    while IFS= read -r name <&3; do
        [ -n "$name" ] || continue
        printf '  remove %s ? [y/N] ' "$name"
        read -r ans
        case "$ans" in
            y|Y|yes|YES)
                rm -rf "${DECKY_DIR:?}/$name"
                say "removed $name"
                ;;
        esac
    done 3< "$STATE_DIR/.decky-names"
    rm -f "$STATE_DIR/decky-plugins" "$STATE_DIR/.decky-names"
    systemctl restart plugin_loader 2>/dev/null || true
    unmark decky
    decky_loader_revert
}

# ================================================================= STATUS ===

# The [installed] tags in the menu only read the marker files. This checks the
# system itself, so a component that was marked installed but has since lost a
# service or a file shows up as broken rather than fine.
_PROBLEMS=0

_ok()   { printf '     %s[+]%s %-20s %s\n' "$C_GREEN" "$C_RESET" "$1" "$2"; }
_bad()  { printf '     %s[!]%s %-20s %s%s%s\n' "$C_RED" "$C_RESET" "$1" "$C_RED" "$2" "$C_RESET"; _PROBLEMS=$((_PROBLEMS + 1)); }
_none() { printf '     %s[-] %-20s %s%s\n' "$C_DIM" "$1" "$2" "$C_RESET"; }

# "enabled, active" / "disabled, inactive" / "missing"
_unit() {
    if [ -z "$(systemctl list-unit-files "$1" --no-legend 2>/dev/null)" ]; then
        echo missing
        return 1
    fi
    _en=$(systemctl is-enabled "$1" 2>/dev/null) || true
    _ac=$(systemctl is-active  "$1" 2>/dev/null) || true
    printf '%s, %s\n' "${_en:-not-enabled}" "${_ac:-inactive}"
}

# Report a unit, counting a missing/failed one as a problem only when the
# component is supposed to be installed.
_unit_line() {
    _label="$1"; _u="$2"; _want="$3"
    _s=$(_unit "$_u") || true
    case "$_s" in
        missing)      if [ "$_want" = yes ]; then _bad "$_label" "unit missing"
                      else _none "$_label" "not installed"; fi ;;
        enabled*)     _ok  "$_label" "$_s" ;;
        *)            if [ "$_want" = yes ]; then _bad "$_label" "$_s"
                      else _none "$_label" "$_s"; fi ;;
    esac
}

_file_line() {
    if [ -e "$2" ]; then _ok "$1" "$2"
    elif [ "$3" = yes ]; then _bad "$1" "missing: $2"
    else _none "$1" "not installed"; fi
}

show_status() {
    _PROBLEMS=0
    echo
    header "status"
    printf '  %suser %s  ·  home %s%s\n' "$C_DIM" "$REAL_USER" "$REAL_HOME" "$C_RESET"

    # ---- 1. CEC
    echo
    item 1 "HDMI-CEC TV control" "$(status cec)"
    _w=no; is_done cec && _w=yes
    if [ -e /dev/cec0 ]; then
        _pa=$(cec-ctl -d /dev/cec0 2>/dev/null | awk '/Physical Address/ {print $4; exit}')
        _mk=$(cec-ctl -d /dev/cec0 2>/dev/null | awk '/Logical Address Mask/ {print $5; exit}')
        case "$_pa" in
            ""|f.f.f.f) _bad "/dev/cec0" "present but no address (link down?)" ;;
            *)          _ok  "/dev/cec0" "addr $_pa, mask ${_mk:-?}" ;;
        esac
        _tv=$(cec-ctl -d /dev/cec0 --to 0 --give-device-power-status 2>/dev/null |
                  awk '/pwr-state/ {print $2; exit}')
        [ -n "$_tv" ] && _ok "TV" "reports $_tv" || _none "TV" "no answer"
    else
        if [ "$_w" = yes ]; then _bad "/dev/cec0" "absent — no CEC adapter"
        else _none "/dev/cec0" "absent"; fi
    fi
    _file_line "cec-tv" /usr/local/bin/cec-tv "$_w"
    if [ -e /etc/systemd/system/cec.service ]; then
        _unit_line "cec.service" cec.service "$_w"
    fi
    _unit_line "cec-standby" cec-standby.service "$_w"
    if [ -n "$(systemctl list-unit-files bc250-cec.service --no-legend 2>/dev/null)" ]; then
        if systemctl is-active --quiet bc250-cec >/dev/null 2>&1; then
            _ok "bc250-cec" "running (owns registration)"
        else
            _bad "bc250-cec" "installed but stopped — sudo systemctl start bc250-cec"
        fi
    else
        _none "bc250-cec" "not installed"
    fi

    # ---- 2. LED
    echo
    item 2 "LED strip daemon" "$(status led)"
    _w=no; is_done led && _w=yes
    _file_line "led binary" /usr/local/bin/led "$_w"
    if [ -f /etc/led-controller/config.json ]; then
        # Match on the key itself rather than a field number: the JSON is not
        # guaranteed to put one key per line.
        _leds=$(grep -o '"leds"[[:space:]]*:[[:space:]]*[0-9][0-9]*' \
                /etc/led-controller/config.json 2>/dev/null |
                grep -o '[0-9][0-9]*$' | head -1)
        _port=$(grep -o '"port"[[:space:]]*:[[:space:]]*"[^"]*"' \
                /etc/led-controller/config.json 2>/dev/null | head -1 |
                sed 's/.*:[[:space:]]*"//; s/"$//')
        _ok "config" "${_leds:-?} LEDs, port ${_port:-?}"
    else
        _file_line "config" /etc/led-controller/config.json "$_w"
    fi
    _unit_line "led-controller" led-controller.service "$_w"
    _file_line "source checkout" "$LED_SRC" no

    # ---- 3. Power
    echo
    item 3 "Disable sleep / suspend" "$(status power)"
    _masked=0
    for _t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [ "$(systemctl is-enabled "$_t" 2>/dev/null)" = masked ] && _masked=$((_masked + 1))
    done
    if [ "$_masked" -eq 4 ]; then
        _ok "suspend" "all 4 targets masked"
    elif is_done power; then
        _bad "suspend" "only $_masked/4 targets masked"
    else
        _none "suspend" "$_masked/4 targets masked"
    fi
    _w=no; is_done power && _w=yes
    _file_line "logind drop-in" /etc/systemd/logind.conf.d/99-bc250.conf "$_w"

    # ---- 4. Guide button
    echo
    item 4 "Guide button -> input" "$(status guide)"
    _w=no; is_done guide && _w=yes
    _file_line "cec-guide-watch" /usr/local/bin/cec-guide-watch "$_w"
    _unit_line "cec-guide" cec-guide.service "$_w"
    _file_line "udev fallback" /etc/udev/rules.d/99-cec-controller.rules no

    # ---- 5. Decky
    echo
    item 5 "Decky plugins" "$(status decky)"
    if decky_present; then
        _ok "Decky Loader" "$REAL_HOME/homebrew"
    else
        _none "Decky Loader" "not installed"
    fi
    if [ -d "$DECKY_DIR" ]; then
        for _p in "$DECKY_DIR"/*; do
            [ -d "$_p" ] || continue
            _ok "plugin" "$(basename "$_p")"
        done
    fi
    if [ -f "$DISCORD_SETTINGS_DIR/config.json" ] &&
       grep -q '"client_secret"[[:space:]]*:[[:space:]]*"[^"]' \
            "$DISCORD_SETTINGS_DIR/config.json" 2>/dev/null; then
        _ok "Discord creds" "set"
    elif [ -d "$DECKY_DIR/discord-deck" ]; then
        _bad "Discord creds" "not set — reinstall option 5 to enter them"
    fi

    # ---- 6. Apps
    echo
    item 6 "Apps: Android TV" "$(status atv)"
    _w=no; is_done atv && _w=yes
    if command -v waydroid >/dev/null 2>&1; then _ok "waydroid" "installed"
    elif [ "$_w" = yes ]; then _bad "waydroid" "not installed"
    else _none "waydroid" "not installed"; fi
    _unit_line "waydroid-container" waydroid-container.service "$_w"
    _file_line "launcher" "$REAL_HOME/waydroid-tv.sh" "$_w"
    _file_line "menu input gate" /usr/local/bin/atv-input-gate "$_w"
    _file_line "sudoers rule" /etc/sudoers.d/waydroid-udev "$_w"
    echo
    item 6 "Apps: Xbox Cloud Gaming" "$(status xcloud)"
    _w=no; is_done xcloud && _w=yes
    if flatpak_has "$XCLOUD_BROWSER"; then _ok "Edge (Xbox Cloud Gaming)" "installed"
    elif [ "$_w" = yes ]; then _bad "Edge (Xbox Cloud Gaming)" "not installed"
    else _none "Edge (Xbox Cloud Gaming)" "not installed"; fi
    _file_line "launcher" "$REAL_HOME/xbox-cloud-gaming.sh" "$_w"
    echo
    item 6 "Apps: GeForce NOW" "$(status gfn)"
    _w=no; is_done gfn && _w=yes
    if flatpak_has "$XCLOUD_BROWSER"; then _ok "Edge (GeForce NOW)" "installed"
    elif [ "$_w" = yes ]; then _bad "Edge (GeForce NOW)" "not installed"
    else _none "Edge (GeForce NOW)" "not installed"; fi
    _file_line "launcher" "$REAL_HOME/geforce-now.sh" "$_w"
    echo
    item 6 "Apps: JDownloader 2" "$(status jd)"
    _w=no; is_done jd && _w=yes
    if flatpak_has "$JD_APP"; then _ok "JDownloader 2" "installed"
    elif [ "$_w" = yes ]; then _bad "JDownloader 2" "not installed"
    else _none "JDownloader 2" "not installed"; fi
    _file_line "launcher" "$REAL_HOME/jdownloader.sh" "$_w"

    # ---- 7. AUR packages
    echo
    item 7 "AUR: BC-250 Control Center" "$(status ctlcenter)"
    if pacman -Qq bc250-control-center-git >/dev/null 2>&1; then
        _ok "package" "$(pacman -Q bc250-control-center-git 2>/dev/null)"
    elif is_done ctlcenter; then
        _bad "package" "marked installed but not present"
    else
        _none "package" "not installed"
    fi

    # ---- 8. Quick boot
    echo
    item 8 "Quick, quiet boot menu" "$(status boot)"
    if _conf=$(limine_conf); then
        _t=$(sed -n 's/^[[:space:]]*timeout:[[:space:]]*//p' "$_conf" | head -n 1)
        _q=$(sed -n 's/^[[:space:]]*quiet:[[:space:]]*//p' "$_conf" | head -n 1)
        if is_done boot && { [ "$_t" != 1 ] || [ "$_q" != yes ]; }; then
            _bad "limine.conf" "timeout ${_t:-unset}, quiet ${_q:-unset} (expected 1, yes)"
        else
            _ok "limine.conf" "timeout ${_t:-unset}, quiet ${_q:-no}"
        fi
    else
        _none "limine.conf" "not found"
    fi

    # ---- 9. Steam Link at 1080p
    echo
    item 9 "Steam Link at 1080p" "$(status streamres)"
    _w=no; is_done streamres && _w=yes
    _file_line "bc250-stream-res" "$STREAMRES_BIN" "$_w"
    _file_line "user unit" "$STREAMRES_UNIT" "$_w"

    # ---- c. Claude Code auto-update
    echo
    item c "Claude Code auto-update" "$(status claude)"
    _w=no; is_done claude && _w=yes
    if [ -x "$REAL_HOME/.local/bin/claude" ]; then
        _ok "claude" "$(runuser -u "$REAL_USER" -- env HOME="$REAL_HOME" \
            "$REAL_HOME/.local/bin/claude" --version 2>/dev/null | head -n 1)"
    elif [ "$_w" = yes ]; then _bad "claude" "missing: $REAL_HOME/.local/bin/claude"
    else _none "claude" "no native install"; fi
    # Not a pipe: _bad has to count in this shell.
    _old=$(claude_unmanaged)
    if [ -n "$_old" ]; then
        while read -r _how _what; do
            _bad "old copy" "$_how $_what (never updates; option c removes it)"
        done << OLD
$_old
OLD
    fi
    _file_line "update timer" "$CLAUDE_UPD_TIMER" "$_w"

    # ---- x. Experiments
    echo
    item x "TV 4K fix (experiment)" "$(status cecfix)"
    if is_done cecfix; then
        _file_line "patched daemon" "$CECFIX_TARGET" yes
        _file_line "service override" "$CECFIX_DROPIN" yes
        if [ -f "$CECFIX_SRC" ] &&
           [ "$(sha256sum "$CECFIX_SRC" | cut -d' ' -f1)" != "$CECFIX_SRC_SHA" ]; then
            _bad "bc250-cec" "package updated since the fix; remove it in Experiments"
        fi
    else
        _none "service override" "not installed"
    fi

    echo
    if [ "$_PROBLEMS" -eq 0 ]; then
        say "Nothing looks broken."
    else
        warn "$_PROBLEMS item(s) marked [!] above need attention."
        warn "Re-running that component's install option usually fixes it."
    fi
}

# ================================================================= UPDATE ===

# Fetch the newest copy of this script and replace the running one. Works from
# a git checkout, from `gh` (which can see the repo while it is private), or
# from a plain raw.githubusercontent.com download once the repo is public.
self_update() {
    say "Update this script"

    _self=$(readlink -f "$0" 2>/dev/null) || _self="$0"
    if [ ! -f "$_self" ]; then
        warn "Can't work out where this script lives (\$0 = $0)."
        warn "Run it by path, e.g.  sudo sh ~/bc250-setup.sh"
        return 1
    fi
    say "Installed at: $_self"

    _dir=$(dirname "$_self")
    _new=$(mktemp)

    # 1. A git checkout updates itself.
    if git -C "$_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        say "This is a git checkout — pulling"
        # Pull as whoever owns the checkout: git refuses to touch a tree owned
        # by someone else, and pulling as root would leave root-owned objects.
        _owner=$(stat -c %U "$_dir" 2>/dev/null) || _owner=root
        if runuser -u "$_owner" -- git -C "$_dir" pull --ff-only; then
            say "Checkout updated."
            rm -f "$_new"
            : > "$REFRESH_FLAG" 2>/dev/null || true
            _offer_restart "$_self"
            return 0
        fi
        warn "git pull failed — falling back to a direct download."
    fi

    # 2. gh can read the repo even while it is private.
    _got=0
    if command -v gh >/dev/null 2>&1; then
        _owner=$(stat -c %U "$_self" 2>/dev/null) || _owner="$REAL_USER"
        say "Trying gh (works while the repo is private)"
        if runuser -u "$_owner" -- gh api \
               "repos/$SELF_OWNER/$SELF_REPO/contents/$SELF_FILE?ref=$SELF_BRANCH" \
               --jq .content 2>/dev/null | base64 -d > "$_new" 2>/dev/null \
           && [ -s "$_new" ]; then
            _got=1
        else
            warn "gh could not fetch it (not signed in? try: gh auth login)"
        fi
    fi

    # 3. Plain download — only works once the repo is public.
    if [ "$_got" -eq 0 ]; then
        say "Trying a direct download"
        # raw.githubusercontent.com caches a branch URL for up to 5 minutes, so
        # right after a merge it can hand back the old copy and this reports
        # "already the latest". Ask the API for the newest commit and download
        # that exact commit's file, which is never stale. The branch URL is
        # only the fallback if the API can't be reached.
        _sha=$(curl -fsSL -H 'Accept: application/vnd.github.sha' \
                 "https://api.github.com/repos/$SELF_OWNER/$SELF_REPO/commits/$SELF_BRANCH" \
                 2>/dev/null) || _sha=""
        case "$_sha" in
            *[!0-9a-f]*|"") _ref="$SELF_BRANCH" ;;
            *) _ref="$_sha" ;;
        esac
        if curl -fsSL \
             "https://raw.githubusercontent.com/$SELF_OWNER/$SELF_REPO/$_ref/$SELF_FILE" \
             -o "$_new" 2>/dev/null && [ -s "$_new" ]; then
            _got=1
        fi
    fi

    if [ "$_got" -eq 0 ]; then
        rm -f "$_new"
        warn "Could not download the script."
        warn "The repo is private, so a plain download needs it to be public,"
        warn "or gh signed in on this box:  sudo pacman -S github-cli && gh auth login"
        return 1
    fi

    # Validate before letting it anywhere near the real path: a login page or a
    # truncated transfer would otherwise overwrite a working installer.
    if ! sh -n "$_new" 2>/dev/null; then
        rm -f "$_new"
        warn "The downloaded file is not valid shell — keeping the current one."
        return 1
    fi
    if ! grep -q 'BC-250 setup' "$_new"; then
        rm -f "$_new"
        warn "The downloaded file doesn't look like this installer — keeping the current one."
        return 1
    fi

    if cmp -s "$_new" "$_self"; then
        rm -f "$_new"
        say "Already the latest version."
        return 0
    fi

    cp -p "$_self" "$_self.bak" 2>/dev/null || true
    # mv is a rename, so the copy this shell is still reading stays intact.
    if ! mv "$_new" "$_self"; then
        rm -f "$_new"
        warn "Could not write $_self — is it on a read-only filesystem?"
        return 1
    fi
    chmod +x "$_self" 2>/dev/null || true
    : > "$REFRESH_FLAG" 2>/dev/null || true
    say "Updated. Previous version saved as $(basename "$_self").bak"
    _offer_restart "$_self"
}

# Updating the script does not touch the helper scripts and units already
# written to disk by an install, so a newer version can sit there doing
# nothing while the old files keep running. Flag it and re-apply on next start.
REFRESH_FLAG="$STATE_DIR/.refresh-needed"

refresh_installed() {
    say "Re-applying installed components so their files match this version"
    _did=0
    if is_done cec;   then cec_install   || warn "cec refresh failed";   _did=1; fi
    if is_done power; then power_install || warn "power refresh failed"; _did=1; fi
    if is_done guide; then guide_install || warn "guide refresh failed"; _did=1; fi
    if is_done atv;   then atv_write_files || warn "android tv refresh failed"; _did=1; fi
    if is_done xcloud; then xcloud_write_files; _did=1; fi
    if is_done gfn;   then write_edge_launcher "$REAL_HOME/geforce-now.sh" https://play.geforcenow.com; _did=1; fi
    if is_done jd;    then jd_write_launcher; _did=1; fi
    # Boot loader updates can rewrite limine.conf.
    if is_done boot;  then boot_install  || warn "boot menu refresh failed"; _did=1; fi
    if is_done streamres; then streamres_write_files; _did=1; fi
    if is_done claude; then claude_write_files; _did=1; fi
    if is_done cecfix; then cecfix_install || warn "TV 4K fix not re-applied"; _did=1; fi
    # Plugins updated outside this script may need packages they didn't before.
    for _p in $EMBEDDED_PLUGINS; do
        if [ -d "$DECKY_DIR/$_p" ]; then
            plugin_packages_install "$_p"
            _did=1
        fi
    done
    if [ "$_did" -eq 0 ]; then
        say "Nothing installed that this script writes directly."
    fi
    # Android TV only has its launcher files re-written, not Waydroid itself.
    # The others (LED, Decky, Control Center) install external
    # software rather than files this script owns, so an update never stales
    # them; re-run those options by hand if you want them rebuilt.
    rm -f "$REFRESH_FLAG"
    return 0
}

# The shell is still running the old copy, so offer to hand over to the new one.
_offer_restart() {
    if confirm "Restart the script on the new version now?"; then
        exec sh "$1"
    fi
    say "Run it again when you're ready — this session is still the old version."
}

# ================================================================== MENUS ===

# AUR packages build from unreviewed source, so they stay opt-in: option 7.
install_all() {
    cec_install   || warn "cec failed"
    led_install   || warn "led failed"
    power_install || warn "power failed"
    guide_install || warn "guide failed"
    boot_install  || warn "quick boot failed"
    streamres_install || warn "steam link 1080p failed"
    atv_install   || warn "android tv failed"
    xcloud_install || warn "xbox cloud gaming failed"
    gfn_install   || warn "geforce now skipped"
    decky_install || warn "decky skipped"
}

revert_menu() {
    while :; do
        header "revert / remove"
        item 1 "HDMI-CEC TV control"     "$(status cec)"
        item 2 "LED strip daemon"        "$(status led)"
        item 3 "Disable sleep / suspend" "$(status power)"
        item 4 "Guide button -> input"   "$(status guide)"
        item 5 "Decky plugins"           "$(status decky)"
        item 6 "Apps"                    "$(apps_status)"
        item 7 "AUR packages"            "$(status ctlcenter)"
        item 8 "Quick, quiet boot menu"  "$(status boot)"
        item 9 "Steam Link at 1080p"     "$(status streamres)"
        item c "Claude Code auto-update" "$(status claude)"
        echo
        item 0 "Revert everything"
        item b "Back"
        printf '\n  %sChoice:%s ' "$C_CYAN" "$C_RESET"
        read -r c
        case "$c" in
            1) cec_revert   || true; pause ;;
            2) led_revert   || true; pause ;;
            3) power_revert || true; pause ;;
            4) guide_revert || true; pause ;;
            5) decky_revert || true; pause ;;
            6) apps_menu ;;
            7) aur_menu ;;
            8) boot_revert  || true; pause ;;
            9) streamres_revert || true; pause ;;
            c|C) claude_revert || true; pause ;;
            0) if confirm "Revert everything?"; then
                   if is_done claude; then claude_revert || true; fi
                   if is_done streamres; then streamres_revert || true; fi
                   if is_done cecfix; then cecfix_revert || true; fi
                   boot_revert  || true
                   ctlcenter_revert || true
                   if is_done jd; then jd_revert || true; fi
                   if is_done gfn; then gfn_revert || true; fi
                   if is_done xcloud; then xcloud_revert || true; fi
                   atv_revert   || true
                   decky_revert || true
                   guide_revert || true
                   power_revert || true
                   led_revert   || true
                   cec_revert   || true
               fi
               pause ;;
            b|B) return ;;
            *) warn "no such option"; sleep 1 ;;
        esac
    done
}

main_menu() {
    ctrl_cleanup || true
    if [ -e "$REFRESH_FLAG" ]; then
        echo
        say "This script was updated after these components were installed, so"
        say "the helper scripts and units on disk are still the older ones."
        if confirm "Re-apply them now?"; then
            refresh_installed || true
        else
            rm -f "$REFRESH_FLAG"
            warn "Skipped — run each installed option again to pick up changes."
        fi
        pause
    fi
    while :; do
        header "game-mode console setup"
        item 1 "HDMI-CEC TV control"     "$(status cec)"
        item 2 "LED strip daemon"        "$(status led)"
        item 3 "Disable sleep / suspend" "$(status power)"
        item 4 "Guide button -> input"   "$(status guide)"
        item 5 "Decky plugins"           "$(status decky)"
        item 6 "Apps"                    "$(apps_status)"
        item 7 "AUR packages"            "$(status ctlcenter)"
        item 8 "Quick, quiet boot menu"  "$(status boot)"
        item 9 "Steam Link at 1080p"     "$(status streamres)"
        item c "Claude Code auto-update" "$(status claude)"
        item x "Experiments"             "$(status cecfix)"
        rule
        item a "Install all"
        item s "Status: what is actually installed"
        item t "Test HDMI-CEC"
        item u "Update this script"
        item r "Revert / remove"
        item q "Quit"
        printf '\n  %sChoice:%s ' "$C_CYAN" "$C_RESET"
        read -r c
        case "$c" in
            1) cec_install   || true; pause ;;
            2) led_install   || true; pause ;;
            3) power_install || true; pause ;;
            4) guide_install || true; pause ;;
            5) decky_menu ;;
            6) apps_menu ;;
            7) aur_menu ;;
            8) boot_install || true; pause ;;
            9) streamres_install || true; pause ;;
            c|C) claude_install || true; pause ;;
            x|X) experiments_menu ;;
            a|A) install_all; pause ;;
            s|S) show_status || true; pause ;;
            t|T) cec_test || true; pause ;;
            u|U) self_update || true; pause ;;
            r|R) revert_menu ;;
            q|Q) exit 0 ;;
            *) warn "no such option"; sleep 1 ;;
        esac
    done
}

# =============================================== EMBEDDED PLUGIN PAYLOAD ===
# Base64 of each plugin zip. Written out on demand by decky_install.
embed_payload() {
    case "$1" in
        bc250-lighting)
            base64 -d > "$2" <<'B64_BC250_LIGHTING'
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
bmcvcHlfbW9kdWxlcy9kb3dubG9hZHMucHlQSwECHgMUAAAACABysWVd1GRlKT4eAAD6VwAAJAAA
AAAAAAABAAAApIEUOgAAYmMyNTAtbGlnaHRpbmcvcHlfbW9kdWxlcy9lZmZlY3RzLnB5UEsBAh4D
FAAAAAgAcrFlXQRI5vtmCgAAaR0AACMAAAAAAAAAAQAAAKSBlFgAAGJjMjUwLWxpZ2h0aW5nL3B5
X21vZHVsZXMvbm9sbGllLnB5UEsBAh4DFAAAAAgAcrFlXaBHoD0lBgAAyBAAACYAAAAAAAAAAQAA
AKSBO2MAAGJjMjUwLWxpZ2h0aW5nL3B5X21vZHVsZXMvc3RyaXBfdGFwLnB5UEsBAh4DFAAAAAgA
crFlXbIlV25BHQAAkFwAACIAAAAAAAAAAQAAAKSBpGkAAGJjMjUwLWxpZ2h0aW5nL3B5X21vZHVs
ZXMvc3RyaXAucHlQSwECHgMUAAAACABysWVdMRFTeT8PAABaKQAAKgAAAAAAAAABAAAApIElhwAA
YmMyNTAtbGlnaHRpbmcvcHlfbW9kdWxlcy9lZmZlY3Rfc2NoZW1hLnB5UEsBAh4DCgAAAAAAcrFl
XQAAAAAAAAAAAAAAABMAAAAAAAAAAAAQAO1BrJYAAGJjMjUwLWxpZ2h0aW5nL3NyYy9QSwECHgMU
AAAACABysWVd3fTktwstAAA4sAAAHAAAAAAAAAABAAAApIHdlgAAYmMyNTAtbGlnaHRpbmcvc3Jj
L2luZGV4LnRzeFBLAQIeAwoAAAAAAHKxZV0AAAAAAAAAAAAAAAAUAAAAAAAAAAAAEADtQSLEAABi
YzI1MC1saWdodGluZy9kaXN0L1BLAQIeAxQAAAAIAHKxZV3Ib/JZGTAAAHO6AAAcAAAAAAAAAAEA
AACkgVTEAABiYzI1MC1saWdodGluZy9kaXN0L2luZGV4LmpzUEsBAh4DFAAAAAgAcrFlXdqa3cJJ
DAAAvCIAAB4AAAAAAAAAAQAAAKSBp/QAAGJjMjUwLWxpZ2h0aW5nL25vbGxpZS1wcm9iZS5weVBL
AQIeAxQAAAAIAHKxZV0SXe2R9x4AAPxIAAAYAAAAAAAAAAEAAACkgSwBAQBiYzI1MC1saWdodGlu
Zy9SRUFETUUubWRQSwECHgMUAAAACABysWVdlUhADJ8eAADtoAAAGwAAAAAAAAABAAAApIFZIAEA
YmMyNTAtbGlnaHRpbmcvZWZmZWN0cy5qc29uUEsBAh4DFAAAAAgAcrFlXRS9SV8hAQAADgIAABsA
AAAAAAAAAQAAAKSBMT8BAGJjMjUwLWxpZ2h0aW5nL3BhY2thZ2UuanNvblBLAQIeAxQAAAAIAHKx
ZV3WhbQzrwAAABgBAAAcAAAAAAAAAAEAAACkgYtAAQBiYzI1MC1saWdodGluZy90c2NvbmZpZy5q
c29uUEsBAh4DFAAAAAgAcrFlXeWAanK+AAAAGQEAABoAAAAAAAAAAQAAAKSBdEEBAGJjMjUwLWxp
Z2h0aW5nL3BsdWdpbi5qc29uUEsBAh4DFAAAAAgAcrFlXV9roNQ3AAAASAAAAB8AAAAAAAAAAQAA
AKSBakIBAGJjMjUwLWxpZ2h0aW5nL3JvbGx1cC5jb25maWcuanNQSwUGAAAAABUAFQAlBgAA3kIB
AAAA
B64_BC250_LIGHTING
            ;;
        system-updates)
            base64 -d > "$2" <<'B64_SYSTEM_UPDATES'
UEsDBAoAAAAAAJKqZV0AAAAAAAAAAAAAAAAPAAAAU3lzdGVtIFVwZGF0ZXMvUEsDBBQAAAAIADOK
ZV1rLT9/jmoAAP+IAQAWAAAAU3lzdGVtIFVwZGF0ZXMvbWFpbi5wedRbe3PbOJL/358Cx62pSI5E
P/KYrOZ8dbIsJ97ItlaWJ5fyuLgQCUmMKJJLkJI1Ln337W4AfEh0JrNXdVWnqpmQINDod//wsL+M
oyRlXG5C148OfPU64VK8f2vepuGSp+7cvM6CaGKev8koNM+RNE/x2jOPiTBPcp6lfpC/+bOQF2/Z
JE4iV8icRCqW8dQP8tGpv8yfsyQI/Ikd80Tmbb/7qvs0iZYs5ukcejD9bQivB6ajJ9zF5uDg/uZq
zM6YRa9tuZFZ7PFUWAcHf4Hh7pKHLBTCkyyJgGAasSyE5gWLQniJWTRl6VwwL1qHQcQ94eGgBZ8J
aR9cX904l6N+3zn/Ou7fwSRv2CE7OT59yw4P2RucYDz3gbCIo1eSxUE280PJeCJYGKXMD4nyBfLF
ZBolosVkpN9DsRIJTD4ViWSKYwn0plGCg5Y2UBZEmAW+TCVbzzlQRN37sUTSerYjICP9KJQ2GvAX
5kbLGBkAIkAOOqQ8CEAoN4p9AbzNOLbBZyDHQ09xQFohHmhyNhdAAfsJ7tkHw8H9R1DEqD+8RT1/
jbJw9jcxFadPRxP39N1xW4o0iy3T73zUvel9wp5LmCtvvu7eXF3278hUtbxbSp+CETlgKQpAYCmC
qVKGkSVh68QHbYFKiM0UNLSCV7An6nTDkgz0wIEYyLxRkq651BqHj+CxoSuKD9xDq0vwqmDDfBm+
SpVWBMg+vr0dOJdXgz6yXZLWlnNLfbwbd8d95+JqBD3QPRvW0YonR+C0Fe00Ve9hd/zJ0NsZfsQs
6SZ+nLbR6TX1UR/87w6GDLofa4fYiZgmQs7b6OPCIyV+QcnSqiZdCAOtwRabbOjzkicLUAlGG6lR
cNSjH6IdKhPZ7DqSqBXsBg6PI6SagTjWdtKGIS/noO81ENIdwOISe7F2WzPMJokfzqRyOOKSoQMq
Ww/6F/AmlmBTdFLlzL0oTBMQpSfCFNgGTxeMkgR89iGW1iHQkWki+JIiR9JYDAZ3DjEniE4itFF7
t9fD25v+zRjj+uGAwa9hucK1Wsz6dHF91e71e2z8K0xDs1rNlu4D0YR9kEWYzI81o0WHOFqLBLvc
BULEYCSZyVioWCt6zTLfE9jrIz6wSZamEZooziDI1z5k6aIvpTbsq3KHDp/iO09X+LUbeknke8h1
4wvf0Euz6OWmgUuqw77nvTY4545Oi76TKEqx298z31202D8zX0AtgUa2FGGG/R7BIneFf0VxipFM
TjGGBnjik7LXMchsCShqJcj/tO+FfAkG+QurCEY2C8QUPA6U0UCS9ypDEtEFaBUniiRYNksSYL3Z
IlvLCEjp7Mf6T7FIoNaEKXjkeu67c6oD0GkpolAwHSMg9tKHAmYf3PXH90Pndji+ur35f+AUP2b0
JzeIMuLtfybRE+vhG/vIQeRZadppSJOKyyiBzHhz+6Xke750o4QoXOjH/Ns3av7bhamdCTv9M+7G
Gt37UfPPOJ3qp2IckgjpM8V4H/jhAi16cvzhOC7xEPBMKbRHT8AA/I9nadTWKIE8WVneAIlS2m5/
iyaW/tztGcd4trRPI2Hl0/ikG9v6A7ykGbEIjpu2tRcpF2+XCOgWTWd7AD7k3I16RTmB0FKlRP3f
WcvTDyenE0c7YYBxS6Muv+RFOhagX2/x5uTlMWYIZfna2gJO3Z76yXINIUWFZcCzEHJpIneri67I
VFInIojCmUE/yjxQDROebDo67AmZ7EzYYuBpccA3lBNaeWVRZDIpEoBYc4hdVSFiHooASzeiJsEh
uCmmJRaeKGyraWdECTOD0i6WIOjninL5g3o2g7EQ/+N+99q5+3Q7GvfuK2VhL9Twba2DrZ2uEA38
UMRB4xM0tqlLe0aNlcE1kQivMzHF13YYrSu9a2ITHnVrpWddpELDtxz2Jrr7YwEgIrAwT0CzpMyP
ie9dnCNAbWnkRT4wByTuZinYBs3G1lEWeIigaJ1hdNodjZ27fndEsPDZaKhTp6Etzn8Fbkr0JHIR
RNGCgDFMGzIv4WvoaFwK0n1KBcVwAuVhU573qqeDljRBpuywh9x6qAWu7Go9Km0V/D1YfmTP/HSe
TewsXID6Q7kI7FkiRBj4s3maD0G7YX8AJXa48j2f29poMCjvZeyFPUu2w0H6lcexXTalWNkrEZI5
fxVyAQuWnNg3RSdKZnbZjCUb71gYR5J677SqdMDOIMtytowgxtoy3QQmaK+o7EBEYhXWq4F8uSSm
PAtSIIYxFuOHEAu7cDmQoS4gisGFc4TfESuSD1S/GNdwxlDXt/d3fWfQ/Xp7PyYXAeGI1V4xJN3E
GnQalqTB6egdNjv3Q48gJXki4D+fIAlQaUjoP2dT7pqa2mIJ2o9BrZ7NQGu23STYqiQHX1pLlVVA
NPBtxJazYBPPpeFY8eqMvw5pYYiWN5w6GOKgDmXaSuub98c7rbF8aymD7v+q/d7tjXznCG9WN40I
IB3/EFkFKhxYsu+QmYkQ0JNrQT6oCFxZCznkNM4zmmZrr7wpVIkDcA3mTMAWjcOJtkgLTAZl4cyC
SQCZC56eXfJAimZHubJl3ULyvsyCwBlCWYck7qb+isOS+Re9ptOUYOWRUFIAn4UcZBYHirxKdWg7
hEzKlGA77S0rX6ybkOnVSlENwjUNZH6Yn8amKNhvqQWL/J+pIfBD6A6Nlv0t8sPG9NVzurU0L9AT
+j5PttZv4SvKTxOc1sj80GmfPDZLZF6fsdrxpj9037bYM4kCD2AOoEvjodCm5NjICbX4U63HTm7j
Uifik+bfWqYZiJm252d83lrzKPAcRUYqZk7yKXd/inPV2UkQONEAcOeC7nYLo5XECUCDJGSNV9iL
euYWRU5M63PxCF0K+1vl9uddnkrSGeXtSkca35YZezaK2FaJvSom2hazKkm0L8+SKIsbM99rQZL0
IMsRHsdlriZ5dgNepH15Enmbisdo4Z4xKW1zwYhL0Inc6gm3xokU+sFP6E1qKhvCeSkbTaVc8ZQm
vHaOxVY71apwSgDSK6TUyB0EGp+3zSpNYzCkZZHAxOqztpAF1VFRBjUYKSzUhm7Gx+2e9yjOLCWE
HkWSo5a2Rm7qU/LTvBcJWuq2LZtFpR4V3A0XM1CRTbpQn6hYvljPOjr/yxSWGkxhQ8wJMSgUkLNK
nbo4SOYGtCChJakaAegU8qTMUwepTOaQEX/ab44hkKdRljiq8OCC4LmiJEt9cDiUc5U3LSWbXv0N
+pdjK8+gPWTF4LpdEpOCBKAgyOqYS/t3ve6wX1A45y8TeKojgAw4gKLGo9sBVoniy68F1SEkU4GZ
biFfIr4piJcKDSYGkBJg9xfnc//r+W13dFGQ/Sw2k4gXa078bUvPWskniJWgVO8rF1udEKDGvE40
XNaNRgSy9YT3cVGjxkkmdmUhegQn6uhd3H652aWIeOwHaApQYB3J0dXHT+NdmiMCn39MdC3qiZJJ
d2gOwLtfJFmj89M/pXPl0oDgYdV21wNPGjj3w2LyO4onlv0b2q+hjGbYo+39oR0ozF+Iwuuri4tB
KYqufc+DzOLuhmONot4gDI82lDgUYtpX2fem/oMEUDPjW9x0UMkLp/oudfKvHc8yYtWQfvcnSNcy
XkPzPe6WEBAVL6dHIV0ei9oI6Y/vRyV798tbmbtkaCephsi4e15QGPPJ3nhM/iDYMgbaNeOH3Y/9
ikcP+UygP+/SobrzR4SqDkykyH1rzP6oICJUGJew6vP7jtEmUDju5JLDmnQZhRiuJ508ck87hW/u
LxjedAy/RR/2tqOVUbjBu7yfadsSKZRIpLVQZWagikzcrcL7IscsM8BWiYuoRctVD1ZelevIEtab
BgoiWLD04ZKa5g3hCgCwK79o3Ie7iH5SPw00rLlGb6ZFxkLXIdZQO5nN2qGAOmjXKp9h9F2Q8UMA
ow5TleVG5KNVSShoH4XhgCByeeD/zhVrYQ69LRHOAl/ODeyqGUvd/n2l0Jj/C8W8yjH8dvfT69wB
FU5r7nxFDSlfrejGgN5jA3gRm6umC7X/Uc+EAtCO8l2ntEYxKoYpdWi8/h7br3Zx8bPupnEwbuAC
Lru8+lhsFovUPcJ928JDjuBx6s/UGWvzoDce9Po34/7IGX7+WGx36/5ttWXfnvmpVep6P7wbj/rd
a+w/T9NYdo6O9L6YGy2PwILcNafBVUo2UTo4cIbd3mdMbSPcPkgEjov9QDQS64G3fz9u//W/ndeP
5tF2XrcfD618CaaP5B08C2+seJCVwP5QfdP7hXQgWDlXbjEviSg3gNNu0jk+0L6XPuotbQDAspoO
7iVtz4euUHO16Ay+Way1dQJ6eCyno4eYcleMaYuGIbkSqbiFR0NNipySNuwpLHtpt7QRNx+NwEtf
wsiZEVw2zEMh9xc60lL7cVKYqw5qqy0tnfw39Jf2WF8lwBPX5q7Mhv5LQrq08gXk1WIOGNBJsrDx
YCnSuChoY6U/NFQeW3TNA7qfvT9umnmQBjs7g6L045oEEraMAz9tNJEEteWz5Ct0HypqEE0cOecN
j6e8wyabFJTF2v+FSi/pDPc7/ZQ1zM7RRz/9lE0g4QjBusOrJoM8iYeXc33M/QqW4V6hLHXzBJSM
t1LKPOsmGzg4aUws5Ib95P12bLGfIHuFxFUTwp3+tefiyfNBApDKyOCHJAYdVeOSFi8BdCiqSYpJ
FAVKDFINx1NPpYt0bqvXku1AUw3dB+8IYAw2bfGE5m+U/LjEP+Lhsjy0P2d40/HkQMJv6GdNBSZJ
adn7WPDmCxdva2CQK8tBiNu/tV8/WhQBhgLuQ0BqbZb4IWo2FHIBmAhKQYNoKcPjk+1LUBv5ggD2
2HEFD9Dog4OL/mX3fjB2vnTHvU+DK3XjpKXzv1qeW7BOzZ7aLnfnm0geov9SS/7QDlJZvORnYHrn
HfIMV18nb07b5m2VBQsethPuiSgsPu81q+OBQ0NMArASS9rt149tGEizQ2WeuKYf7rNLN4rFoTpc
FHyZP7RDjvipDUGJYUenikkEoM+IaIjEfizWfqJ66Od2nAW0JLHwLQ6y5QRBnRqgx7fnEC9zEXg0
uWnMa5OhHnC55G2996LONqllHSULCVFLsyzWPunhKUpmQCJZqYOKwF/6IQp38NjMjVg6uImhmDlz
KKkSUPN7PSNkLn+6cdaYPjG5wSd05OrXJf8WJbVfVhFIK6qfVJuTzvGSShTgIcuH4+owzKw7o6jJ
8fgGuTt5u9MfhPQBxdby4C2WOx/80A0yTzg8q+f6O+2OJ1Yi2CVHlUAPo7iujgvFepc1aHHcCLwJ
2t/pRkhpsH6FLEAYbQW5BdFcZRztKGMi47taNTJNA57GfLGrPPDhWQIr6gmmGDwY1C6lLoTl90kg
Gcu9Kye/sDmMFGFxsIuHij51hQWYreeYR2uHBjs4eEfgsgPt5Q8TCjAMF2G5E/58Sudpo/757e3Y
ue6OPvdHxamxdZRJdQ1Mh/VRHuk73zHKbRnZ72u/JJs4jeCzRWezKh+7geCwIg5XjQIO0A0aUNBw
c5VflJtAocQ7JuIJy5ZkgwtncHU+6o6+0kU0hbcJGNEVLjzmInJH6TI+cq77V4dskoVeIGzWm/uB
BwUFEvtcJD7dRcQaGiMmR4uA3tdJpA5mpQz0lRtVNfX1RchJXoar1H/cDvs3d3cD54391j4m/DEF
b/P+Ye5z0T514C8EU0pz0yCvwSA2KNnz3bQRSRvefJi2mZcfcCDa7rZ2hKXrORfOcNQf3HZxh9Ea
fh1/ur35dHvdL95MTxR+2L27O7VK5QnmsuMobsAULUZ7/oahB4sGPmKpUdbD9daRBOzfKb3nr8UH
elCvE7wtmRMc9JzuYKBI9qxynYPPxhEQhfEED9gM3DqBZAVVFlYcmAtCwJaVo7Y02ZTKbRK5QL64
smsjvQo6IOKVFpj9rOyA1a8uj4FH4QArcaZ22aodUvFU26zZ1/9WP5I4ZyU2L/q/3twPBogLKqIq
VICWKQgUaz0DE4CIrZ4VqKUGoEPg1ryIJNGHLa6IU3YJUPAmSi/RS/tJEiV7EPbk9OcW5i02tZ5R
aw/Hj9tO4dpWmVpJlLESuP8UQ/H1aqi+raGKWvLochyf4j2qZ622raxM06d/EGrBogDaOphQw+if
AI/PB/3j45O92dRcCNKgew5N6UabI+II1igavHXUWqYMrzUN3UFDP6uD+03Nh5NHNBa80epIA0Cy
ln7JD465FA4huepUHb0KSQSuPmo4apoZ22rG4xeXFBVc6hAsRboKZuY51pcKONBWXQNSP/HRwmut
+skD5QJEhxQKLJ3soHTeYhPktCQP0Gi2Ki1Aq4Jg+UOHiD6y/zhjE/OSB7vgHu4m8ASQizdVS4rS
MjiRIj/0Vt3YZ7H5FZeiks7F1aUPPKdvItcRyALJ1aNcWhxl4cVZWKMd0AtO7KI/lNJgGIWUzrBn
KTd6mJWBJdsPPfEEa6Dfno7xtgP0KmIQw1/3e4APHRj2aHsCA7FhZem0/UHdqQPgCGixGKeYwkle
sz23RaIFu4ATAvGH/GLwALbc5g1QrgK6NcL+s1iwVZdKCz8XEpl/rHzEka/PSszhDzxKDQKFPh1/
qJIrSQDcVGcSeIisFP8dgsf7BIHSA4zGsqEVUc3eQZXCyXcp1DCwS+D0uwTAy2ws6Q4txxu52UlZ
7O0j4f4UtxZb9HckwlMHM3s0tXbffpeXn/8XvHwo8fLi9B92ppeixqLchzikqKNC0Zha+uoYg8Cj
W0zsGZneWnulCd2gnA+MBVUCIJjs5HHs0J6+XDTwUiTeGCDA7vhe+ToCBPVNfh0yH0o76+V8gAXi
GTfQvZa+gCCexNZm91LtzBKtGSwx9bUaM9srtUnSUqkcMSCkNKGv1VAhVpf2ACy6HHfbJmaTgXus
EZr7Vni7k20ElF/I0Vz9QcIajzxwCBRPyPApgM3mL+zhURE0PGk+zA2zQiiTzZA0mtrskKKymrQp
oiHaHBb2R8TGkembb4wVOi3vUaRzIJbTPaJyWfQk4mrL9aiiY6u8O6O23NK5DWUGxX1hV+aBymbj
5cmaSMDzE7Mjgio/2HdO9QcbAPWAH+Hl9Gz8A7CGdXhUy+8OtCv9IKLOAr6ceGCrDpvaeNW5AQU4
dZaIRPCQFauy2AlmLTcxUytuzn1J0dTbVPMKfE3wZvjZfl0kvapGivT82syfBEX0VxfgJnRBUFAs
g2GzwCMpyIV/kh34D4sczIlB4+7FdC6TqjiljTJYQSdqrYKS2DMB4CW3gNU093RoL7mybbe/TU2k
WlTIdxwJd+P9MBMlVxCBRweFC5BtLbC0s9W/qvv29TauI8//9RSdth0CEgFSFzsJHdpDS7Stz9Zl
RGmzGYrBNIEGiQgEEDQgmqa43z7EPuE+ydavqs7pc2sAlJyZLGYig+g+9zp1v3iuQtybMbnVFJLx
A58IepD58m95dMTO1BSrEPblFeEp/7RmmtD7qiLwWkfZ0xn8nnD99/pJg6gYaphNawWz5Sdgc9sN
4J0T5ks0xa/SrMvMZ8v8dyvfat94XBxj8Tv9cQFrLjv371nmpNcbTUaLXq8Fv1jnqDjMzXHhY/HW
KMHawWsLBOp5zAv/zhqyRVG9o2feTeKnQxq4Om9+Dm9IyJPJh2ZmQDUGk3q7V0visl1PDh//RHK3
hP4dHb5+/fT5D0dw88cmsnqBlYgahVE5EBQsVlWaHzfwqzfPXz99dqjj4kij1bQbR2aitN8wwJuj
w1fioA2fhuAc+Mx7urT6zocvMEpJbre+QLQp+RgKLO0++RymNfpxskgNXj/EaU+g/dlXbb957zMF
WyUb1SUu4oCu8HZ2WYxYYQR0cTVdwj1/TvSepBkJ4er6gzEK7ekbPdxmGS+cVE9XLDa8BGhLYFhP
Uf4twcAFOxN6+osLcmpAuaM6x479ZDMIl8R4QbVY/ywv/hvJ8PR8cVXfbgtZTNODO67oIb5QiPzU
v00kbEP/xWRClL9fDm49gG25ZgSx06/t3r2W1Dv9qVeZA2ObOidaetuetVdquaJbRV237VtQ4poN
IeBdjm+9IZgSzDFrOu+DRI5v27m06szLfyxZgM/vuFtMfA8G5f4MYzIsxmMog53+PVbKGRBtu+il
chgpSNgtB1WGvFQzE+X0bCbhzLYq3pfxbAPRO5qpY/PsXrwD96sGUFEsZmzo7E3fJWRJbsrRarIm
Xu1geTETgRB8yoB62n+wYrFrGUdZ3irmkWeQ5B5jFORF0Dky3CboyMqKt8ZHbFas5QEHjDnBRBYL
pITDC3OOaWEUH5LLnPCjKSL4slZ+WUzge3o5IpZfY4eI0ZPAfA7TAPizRDa5qg+G8xdMJEhsUbwr
2d4hMcM5fD6Ih3YCkkYcMi60rw76M30dItgH0ygHEkk4rqa1v4Sz7Sr/jnEvrljuJIiAHF5z2EQb
4WKQi+JXAosWNmYRMdHFYDpbyDg2OFFTNHxdbxWGp9vNEfcg0CL6GhWfDXjDa1nfBN6dliyaWAE4
eYMgBRMdnV0OQC5nl0R3W5bpIXJ4CTgIL8BP5VWg+na6GuY7+LZzbbu5qceXg9xXWu+jqG4ApdsQ
emoxQHQcaLuh9qNui9MU5x/mOLZdrkMtRdtRsGkQBOqvlYQA4QgZjbBDgQwv7SNVXSuKqaUxa0cM
AWDtbVTxHaUh2rFSiSHJ55vclVTsK2n2in44Pon74O1czlkN0D9mgeYEijP6knyX5s+vc//HIlKd
GJERDTl234iQTaoCmXosyqFL+Q7Fm1pU8Z+bWPuGg6x7EAsxH56R8+QQVXKjfxsVF/LJhR0lEKfX
5QBrEROgyjwkjmpdR3LD92SR2/bG7tmzGIk3FpBgYmFQX4q5Mg6DTO+o3BgOe+x5ETCyDGxESl8r
g/Da4n41NQxBl3MoTXDFNrcAfGKgxKXb5MS8XWdF7bodl8lSE/lyE+lbroWY7On1F0KwxzO6cTiP
xBYK6XI20qNaz0BgOGzcCZTV2EInIlYz+Iwc/AxLV6GmcNlvL6a1qyQFWLtSZz4RvBjdF+779HVS
9hcOkSjMHCCNsTH+CrcIUbeaS0gCcW3+GzGt+PSBcesGGtIVFGV22UxPvBeRDmqsgrGMu+MFnsI8
tmNfyr22WBE7OddXxo3DjUF7AF30vjPmThZFs3ap14ti0UK/+xJIFvWjZqtEzFnqTtvhauUsMH0L
mAAzqgkArYd/cJhsmP7wrQGl8usOA8uvpnF91e0jFraFJsRjXoKsL6GLk69nLq3ER/SR7JwrwRat
4ZbELRosf5NvtaMDMSp4jjE0B8pfCPCqHeK5LqYTgR83nPsxq5yrvK1K6OPdzp9OjCY6T9LAWx4+
Pv0h1A1mijvEpsgAxO/21F/e180nTp368A4Inqz0kz1EVrx7sQi6CI5EiLy6HUCBJZpTLLTmw/xv
bxfXfAQ3b6u7nxM3jOGgSu8+Y0DBn925Kh+PO/f32Eqc3+TNtDfSqrof9ueSaGETn1qfsxf8aeCZ
Xd/Ti6lPiUBmkysmQzghw9Hcl3JznUV352Jazm8SJjpuQ8cS3I3jPeroJLuny71HG/Z20tDc3hjq
Z92FUZ649eKIeeJtyx23jXh4C3EQnmrA1A6mV6wOoLdiorHMGTFRZLwz8ZpzyJdPuP5K9IATGLhp
PA5ePgVB3jOJXFipx7lWiFKwnFLb9GqmGXa5/7XTNdai2m2vg6QbxO6ahC86ipvVaau2vZ8uR+NF
h0ZjvoTGmyM0vGQxjv3ERPsInGnpFiHeAeel67ZdygUm2xNg1YwSeBTyBcpzq7tPaj68fo6jPk5M
47UqFCajw/waZ3HTtF00GQepmL4xT0+hq3CmYNZsNQsAwmT9MPL4bNRj/guemT0NMScWGDyuByyv
p7MOwvsH8OSqlhDHLpGJyv5FRzDdzgiQp3I+yNTCVIC7tl1hiD2xc+9lrdOvHgFuF+0by5Sw3C5i
DSf4QkfbYsynd0c1sEBFNGBNgcCfCMxYOP1MV61llCeLdttjasBIuPEql5eXXecMOHCF9mXn/QNH
UF2yzfE47/zIPlcH9Pd0rnFTe9l3hKzhbqXbeYPsGPUNHyKTigi2mFMIZP04fKK/nHMKqM6wOuLQ
6k7novilY3y4H8B95i7mtC2ruceaIie44uFuJHPO+yALCc+QlI01CcXOy44ykIZry+ViE3nAOgiU
1l4Pq4d3xHCRa+3G5TtCEHeQowvqmnG5KHdyWrmbKrT7j+V0UbYsMDvKOmNjRsfJ2+KYFs7EnIlX
j3dPZHGeNVPzUSKdDMHewiS+clGc4iqWKCtWYFl1z3BEhMvpSzTJmlyzql9hPRCn9pxeVrVGCmDa
YzGDE38UGH9CV3P78hwUDldwezKV/56OkQdvsE1EtpyPinEN0arS2g+ianf3oLHBENUOtnGHEzt8
O0C+PA6d2v9qd/eXP+3ubj989OCXR398sP3VV/T3w93fy4z2r53p3QSRow/Xdv6IOntw/8vtPz3Y
/eXRZp3e506BfsqmXu+ju68e0Jz/+Gj3l/sPHu1u38cyvvrSjlDvYrRl/nAPeDhsrjeadkPS46hP
jeQsqK+i/267v6wW04ugn0fcD7Cb24/zUg2OCh+e9Yv1VCPoFtgdgiBNDtRY530Q5x/d68R4KMQQ
bKDHmylVQIJhpJsH9ym0sNdEEVee7JweduVC4D60LAZOcfXJEYXvRjdzdersilNn577VQIUDo41m
3W3lM8m19veZ/qfk/16Wp7ON57C4mKnkCLLTfU5nN3hdIv6rmF/BHZjkKiAnda8O23b742kVet+l
US0Rht5tyMJDziHVQcYmDCTUnJo4dOHRblIwJdoATzmmobvZn63ukY60Gv1atkx3bXr2x97u7i7+
lxYv5Ih4h83u7+/rVgvnCKfMVEvHZ+9Rs+iiknvaljlf5CzLXSsPc9PBBesiYcxNWpQzXX6k2cj9
SPbrLpILs8a2PgMM0NxOrvcx1g53xBbcEbiFMC/pXU66GJoPm0ums3LizCGfn+Ysggyb26VmI3nC
u8SplewW3xoye9oipkrdc1PzHCJz6jgB1ARZywmywdQwFSrqZAZpmxKrZ30W1mrrfYb15zoNoASP
OMTZMqDXOa0rZw3xIr+5oYVczBZXrF+rmXlDlydTIx2pvxJHDCNRtKiy/6UMK8KIWtOKFQZZDAyZ
In17HVuEjLjUY5i60SjFQy3zGbtkFPAMMcnnu4spB9Dp4XV9mcQRRzAUH22sxsX1eNcm4eE653zY
e9mpHuBeVt4wFmEUIshGTth/J75S6uTWorfg7j/B3Gs/t0ZIlED+Gg4DkUlUrJolkAWi1riYI7o3
e/n8B4GaNo+dyF1Zd2WBlJd7s21EQVEDE1Ry16OqDu3+lwJFuOawEaEWfF39sQb+7Wgomv7KfFEq
UWGdRH1lQ422cn+rjRGnrPfEvz1QN3WV2s46taXeJFyrVYo2ZWgN7scnAc+AVuyJhGASLDutrDQc
G/SbouSkrcH7NzvnNNfxdL5zd4d1pJIcrguupUHtm+QczEdXh4BpVj0w19flEJPjzsMTExjzS46o
mAZCs16AM5+VSkVYhzCbb+p9b+4pPiCR5fFHyN7hLQA/jnD1dtMuO0AxG/1yUfhbvN2wxzB4+sbY
hBgfzl8nnZpu3PCUUOK7ECvHr6Yk9QgAauIv27iK8KsDvCHpt1YuOTOucxl8kz1Ks4ipltY4p2g6
5DYkLULNaVicT2trwMzW72ReIj+uyyawWdE5uI/3P4DLSeytXJsrQfnwvN7SiGMTi3IibhQfnYHn
BhXPiLuISCSnbOAfPX8hziABKhM6CInHGZ723o+KHkSb3uA09AoyWTL4RePDOpiirMOAFRVg60ro
OCT5h+R7QYkWTqcCp7QwklHqPRTZXfDMd00KYT7OJ9+xYZrlrAzsPUSTwWg49CqVQKXiMmqwlY65
rVEPL6ZLmvCAm1+WGmwirj8FJ4YgYT1bzs6QhsEnmyzmMdq0sh4JB/jemtHUR7/sa2UZ3ZBO3l6h
AR4g6A99kpgyOPVlkRY9hGmM1p23byuBCA+SRTVG5BB2pNMQC0kja4VM403wP3WqLbBD84a3tVc0
aIpb8aZcC0oPWmi0nTk7QF+4o9hlQfeJuQeo7K8uIEj0FtN42frOHa+9k6qmnM+NWB1N08tec3Ql
cvbglBGPOIsPTtv843h6hrUyuzEo3+8g1DhPeCrUWtld/2F0MJwJZ62aljhVLIDOCKYg+s8wN7l8
jq4ALNDsXfc59aq1IGyyF97S/32ZXrqjTrj/INAnEML59yXPoMru24gskZ+0kI4RnLi0kNy75C4Y
nc0uFDwfux06mdR2JDrj7UhZWW7n4ulNzcZMm6dJ0VivxPwC+YYgGm9no7PJdF5KMEClFz9E17LM
EFPjgkt/nGqhlbsoO2QkmwDBa+NZFqIj9yiCnP2D4Ow/4tAf3PrQo3msOvaYHps94NgLobcxUYzV
i2utGtppff9Mmirfbw8olymom9yK81VH2txhlh8LeAxOOHAer22ovuSMYuLMIcnF5vnfWm+P7rXf
VvfMfzvfmD/gboDOzfZFy+c+4qFtqTTj65UkBsbpS2pCaMbepvArSbnjvvqg6dVJeRm8+jDxauwi
Zma9HZpOBQ5U4kxcN7bVe1fO5LNpCt90NDWzABBSGdW8To5t71pmZlF2xpUga3Nj+Y8+UhZNqn0a
YzzqS47HEy8liO3X42wT+djsVO/RXMfWKs1Am4JYFgnMa7daG/0EDQKvABTI6hR4SaFOYNVWmF42
2RSvVzdnyn/1DhmfAwnIrcoFAiWrdoz7kYspwaMfzLme1WXFDhTLUyTxRO1CEoZG9PaVOg9ODB7W
GohFdr4kUiIl2mrl53LC4axb9GhZYBl1hqctZRArY7bPnBSKJKjAh6VCIUWvu2KxIHxAE+p0JlN2
gJhfoPaeb6GXJBX7wZ2C/deWZ2L3Y5/KOYGDceSp9LnuNoo7mKhMEu4jTv6r7exLBxsmsyDKkAC6
iXJP3DRgoMKsPFFodMQN0f8/3G1ELI4IWU56XF6yUcL1w8YCCVdths7uIPSwlLTsYWjg5tSLIX7G
YrdLWSIKx4D8nDZccsOYZjGt8WZl0xW6nyQhNAbPurVGITeP1NSPaeEZNzvfpHR2vqYHnxRBfju4
BzIMKty9921b/f7MMEnbagMhTpswkbQXbqse3fV7xek3U2/N+7snXcW0NQ9ywSH/TSxp4eO4OuYJ
LPNB9QbVt5kUBIBxk8dEy6ex0jJB6HPcBDjj8/3du+b2NwJV9o74zWLegDckQsImg18CETvYKutU
GjJk3kfO4vE4M4G2RqchluOB2gFGpeP18XSBLDccVMS1E2mLJDk2MlNdzFgVIpgEKJmNzOwddQH3
9NGCg+xq1LCYF1Lm6JwO/+xc00XN5pr2javg0IT/ZbDySuzqySf/BIxqd80c3kfy7cmbXt11Ljux
3G+7rW/3dKQP1bT/rlx8wNrmbYMG0PemfLiZsrnJ/o2PgNy8HsE5klGmmI3syU/PjlD9ZjnWwrnD
YjQWyJuX8OccmPKxIqtuiWQmR0CvOwwWF4c9nU/flZjIhDggjjEazEdQ5OkYXEcum0KwvBxxduMK
moUxYYvxVTfwAI3Zck6qufag0zmNuW1dvzGRytgFr1iJE4+ji/14MRALdInohvifPWVqCtzgOJNb
e6LImNoIDrPsqOv+ujmtLCZXrcvpfOB2yTX89LdWztIyNlpACd9ko/CNNd5ebmB/Mw2gp4VWPQJ5
NQLyYjlPwPj/eHxUS+wtJEBnZfKQ0DPh43ZWjC+LK6n1jSrrmUlmsCU4byvUUV9tzQW50sJPlwvV
U9M+02bwvdEc91ywcjEaqoziwfZ5OZ6VUYoIDoSguY2Y5oi/UzFnLd5VcRWCfaglsi0Te2vHsy+t
YWwUNqXdWk71N5AKdSjRWxZW0hNA4i1uEvIipWxMPFYJgSvUlImVJpjqT6Mfn6C6uS3XKH5E0/GA
cx367GMVoI/3fawyzfW5HF+nRffpQ/V+8uH87MPpr/MP/ffVhwlYk/EVryC2AojLPodRLToIIhoJ
JkJZ8XCFsOCTlO6XNsDtxfy4MLSj5rN1iVswh4OLYhEn3h3x/tU7IRalRUncXJExdhCqByZMalB/
7cVK1J2EZcsxCY5EL+al1ESX1YlFV/LRdzc7Kp97D2IrRZHG56iaMvoXecr7CJ+kf9czv0BfDejy
kMsy1lUGFHUKcyC1PoejsyXQPlAmuNf3o0FZ7WUHb17VlBF7WEmJXlucoe70FAH2jISnF+r/7+HH
tUUJ/v1iHf3e6F57+/2x19qkypfLKiUNQkiGdZ3f4wDrRG7F9ImLq8cuIqlN1Rvz4/2TzWUcAuTR
4mojvSdLA8VygMICa7FhIno9fXJOr4YA5J0h/v1i8uGLkP+PD7PhIDc/I+0s/7BC3Y6PZg0AvaEd
8w+VGmMKyXZBMLxzYQ36BuOp3SJKXr+ap75nQnOQAz+pD+Cz7HDE9VLZUEO8+Vk5WdKMazMde5tx
8Fd9Bmz1B9bTYr1OdyICcFAfqysmZ93sFdcfYCwGU01nKPnBOS0tZ7+Yk6z6NV1jYeOd3sQbk9NY
sCFJmP/BqEL6S6t2nFvZw6SSRB3YM+CJ6XDYvS1orYOlFYjBC+a7LOaQ7d0rYYSjFotAX1RtzjA8
CAhcjF4+ikWwNFbr4ChfAG3SPRzncFj2mQe9apIpb8sgOGCfv5HUpr6jw1wydriTe3vaekxtiMkd
f/iR6P6HZ+VgtLz48PP0sv32lKaKNjrBlMoHzuv0RkrytZPBC1bm7faL2WiBmlehE376Dga2qeQt
jDGpc8/qTFSqce8tIlFaU1q6LhzTM/Vl4BRXkeKEvdFWFm7ZwEuMO2FXMeskBrI6TiA3+Z3OrXwH
yJ9W3aPDw596h8+fxAhNffa0CVijVvyS2+FF8Qs65Xad7JH4jrXjNgu6PnXH4rMWJYlWg3kuBlJn
5z4qN5WfRG9RsFdQJHWZy4kJrjHcsoqYM+UhL71UMTC2mBXEJak7Om4d/+3tyQkx/ifJO6xjNtxh
d0UNmmBD4vHWRwAZVwMQBzv00NUcE638P4Br7+3u7u3uBs5JzNFBwJTETlJWyfydmoF5ximcR9VU
I8p16HYXz3j02L3xIyDB4Y2QxnM0vLIJyozp2LBL21abti9eANAf6Vfooff9cgT1h/jqMDmWLUOS
uYWE8Zl5hsaZWkp829WxU8bkxKbD384lsX1kgHEVnrKUOv0iOEST8sd3EtNX3ai1oppOQgsSH2gx
0Yy33iWavTtzi3gFrNq4OAv6wkckPDQ1s7oT3jgonIYTAXD9b0vYtBmMkfNJ23gJ4w+JpNPdSjnG
YR6GSDj7GrhXcYJ+mtgDI4Z6piGpKaUJIqLE8EGFAV4bZDZiTGSdJLOdaJWBtTOUGkftaFeMc7t/
xOt6M2+HHfK8+FWuS8LfwhH5xwRXbSDCDEJ9tf3o6d55UbXQvEGimHkQyXeghjMdmSHLztHVyAzt
HuxFoOWkxt4A9EM2juF/hQ0NMUioaWR3NWG6WkjQSn6k75Cs+0smKeYwBwRAA5dKzjGe8vHeowZf
fnzuwQ0+u3cNgZJfb4Pi3mQXoJVG0tQH35ggmjxM+X3TDjbQwzZR8a2T9M7yuXp3yAMMAdIEyKzd
WW936/4bvIXMFr8RW90nbO5vt8Ebb7Lc75UbbFDAP2Nzpe81G/u8vMz4RVvgZTr8/2JztQxcsLu2
AlzKT+Q4rhN30qDN0bqd2Tf7dZefeh4649UHMsyvvRncZMZp0mRx/r//+//AFid2iFNmPUnAnmTL
ahkFxK/bTfWcqUvUbbOThqS+or8DucSkJaAna7vSqnamQz7t42hyheYhQTyBdMoxj8es8PTZiZPw
pGQ68amYG1ZDcOHRhqKOyD/ee5iA6tsdK2/bmjM9ePNKz9FBYRzdFKVMuNWRcRVA98zYicLrT73E
iDuTnC8T1cdXZrMnx+KDceJvMKdeKjnzpNtSu0PbY9+R5CQ6INNF88UZTYgPX0C+XLPJstDVqOw1
NGG6y8ZxTr1WSJCb7TFaM3M63j05VkeZRFBAwC5wPkZZ+acigQ0WoihAxiMEwLq+FiGjS+J2zhmA
gAdOyyHcx5BCUD04PgGQ1H5eAxJ+CDm6TXkm6ayZXzowfgOD0UDCj8QsA8zmOBcMCalpci06xyvo
Do1iLN+c5fGWaYt6uks1P37scutOG5esR2reNIcKxW0ZuhtNYP4x1HjFQqV6aTWa9KOCAo1EU4qg
nqiSNyXLceJm65IYaMZiYlmkIiZRURXpCVj0xz8tsAJ4Fykq//jVo93dqI2/mjlUdC30k9TK08g8
xjcQZ6ZFROadwq5hGLD5bHRr+QjtMfPeNac6rc/6r3QlzwvCiyiExFeTvSeuwZBgUnT8PLd0X+4Z
G9uPkZi2zby33Q1z84ixb6/1HY0UILZ5QpHB9UgHy1kp3j7GV4KwJTJgK2I15oV52VlMASsl2xRR
xiTl4aPjJWVDqWrrQ651ev0ot9jJFKZvB+zsE1MHNmuAmKBO7Ek7u5s9/Gp319GCcDxkZEZcqRiR
LA90+SGDb4Hcb53c/Jv+VV7SH74OHnQY7JUt+2BSGof3jl/UwGqgyhZW3uGfwVyb1SRUBliFI80b
xii+Y3YSJmSWhnCNU0/A3k1nF0jMbl1wrKMNovpZxA+cAdgTEtuCevbZdOJ0CJORkUGu9AY5ZuWO
mpGI1T0zaXZr2udWrpXuRnBmK/oL41U/Qt0zoaAXwrFY586ud6JGdQB+NJGVe4EsEQvNraTKHxNg
qWyrMLuqk4BCKAkUYK9FcVFDhnT+3wsVri7ltmDBFd+KMcYn/G8lHos8XWKZWac95onqoVRIm07G
2Cg6/db8WLDwiahQ7Ric00GqgzKa8ZTjTjfpW9nrXWs7MINbGIEOodf7xN03qcNN+uD6CP68v+IM
ViDFxn2PzhDr4v8CcHMWDl2t62fZS2IzytprgybDBmZiOh7uCk21efDGJiL7bE5rAK9Jt7ObxNTX
78JqZPV2aaYWTvopm/EemapouLvCCgRVg6K4+hDh279j10G4NPH629uyD2ESAo3OmV6aFJvalzjB
m8AJNwkBZ8iRGkwS1SmliFqm5b75Us+mprYmYHF1nh03XNSD4ET4ol9LLOY3uS/aqmKR77mEMMGa
iivnnoySeG5Kye8mnpkl0uPjhPiUW4al6QW9eE2P64rzycdWKdv4XJFMw3NGPA3PGBk1PIOo3/yo
V/vkNrzEwifdu54OIpc9MX/LvwqDR6/GBqkbHz8wiImTQ3kBGxI795uCZjsMM8Y3k/9IOjbUj91Y
JVVvbwbI5nU3X0bKN/9Wglp4C2yHm81IxS7bCQDgFrNxpePAq0Q62mQWeNVhVaGB2XwGrqIn0CdL
R5vMAK86hXiWc38CHghvMjcCzfGSJENHcRiEXC43xX70Zjts6k1mdSfG59GJ5BcMsnoZx3YJBuEE
zF7dyyaL0LddZcRqwa2OZTcGa2/0VXZrMVmLtZqlOduy3gODbpLevonz5PdRo8fT6+nJBtzIIK1P
DHWCopRMaxldXUYzWduQpFlyFiNKS8k8xXrwjkPR7Lb7b7g0rT5X/52arJnj9p/XdE2/Bc8dwmaP
PHzDkjYLCv4bStwYPPwnSnUYZPwnQtjo3/h3j6p5fwfvhsTN/B0uIKZtzo1Ipdj9GNLmXnnL5Pnw
z5oScTe0CZw83Ultp2YXhJQKJRYCuI9UkEYxYEek/cyROURlFFfioV/nnPsrz1pN5qDFlHatzYY1
K36rSS0W2tbsoBCZvFELbwJK1QxbiRGjSY19Oh0AgO2S78l6NknyELIfNeeO7Mj8oKEgnj/zu3fr
ngL4M3Un+QI5JXRDfODVgzUv+7+mmxhEFFWNDV53CsKat52fIhRmCsCad+tfGl81tWLjJuZJiDpS
lV9N6+RD977yVy+rGRRuKjClE5sNS3j8iCy2nI8lG6/6YTkBAI48NhdPozXpluFmpe05GxQKA+SP
CebLjkZ2EBqcdnALytzjDwZRYj8e8h7XF5iaREvIAJz0i3fS9Ei77NhP8qz/pQf3N4yFTQQrFoiu
fCX1RTkLINLtuNUohrw/Es1psuyEN4YrXtuTEDUdqhcn4kZewn1S9AKE3EuuXAh1HpG54rJ7Nlqc
L08R7wVrDfSBoExlxRGjxaR/zo6D9RFmvO3MPFyMJktcJNYYcjyNRNydTTkMuwhCRyInRinPLuhb
YCnWbdlM5sVspHPlMhLQVVY716bq9OHLFzc7Mon61+9eHTx//GPKRGvO88HKrGFSDDpZkIEepZOx
z8su3E+NJylKLBWd4cn1o90bgN95kbBoGPR5XthHptaNCybbTq7Q7exggRSAtP9SAicMfKmqEGK8
TXFgh4BA7zBNQJLexwi6PockzPCR+IdxTb3Rv+juxq2WaxmQnqqLdfAha7NW1aCt02/GBap3tD2y
2ClBlQKqTfk5w2obraGerDHdrag7VB/DCv/wesW+6im4nwJjxmBnb3E9+kUxGQ0l66kDie6lke98
jDhAPYVnB8+ffn949LrtlS6p+03WSsetlppkhDPMyLIvOv88mZyXt35fmmrFklHoGCWr89+KNxsf
W1CEu9XcIdoczmM77M1dP5Zvnh9od+OiA66YKjsZQ6jCZjjJumljllwzpLhBL5wmCLvZ9rO3RdG/
Tjqznn5nYbnlbKEVfQKvfqB6pma6CM5RLpsIc4L3s51VmH/uwBRbOeVkFjCIYqpsS6yQoZrTBWSX
xVXWooM4vVIDONdNnF0FvXEWUuRO4j7bXJZXzOenJRETkqFh07FxjaAn00txBvGjM827+1odU9bK
/HNPn5n9qmruO4IxbsV0jJvEp6d3ZI1ziBQ1FRhpSpsmES/OsfEv7Rp6Gxq64luD6GbflcOFpMxf
Gt76dTTzZ4IfmtK9rZWrozfZYgMxFVoDbHDD+7rnCAOSbxsJGMBveigRggX7XRMynwV6WpmqawzA
07GpIE2Qd47KGJLhdjb9NnssYcIcCcsxx+PpaTZy9rya2ls7QppeybBPDUCqx05STrof9nLr2a3m
h9xYJS5j/PLg9Y9SzS9Rt8yHZ803XdePP71alNWnJZ4mTNijLZD9Rf3NRHJu4AjzvHZ2BKXG5s2I
FeIgbd50zdf/n8v/ZEcENgl3104EeTubiZ9PiG7DLdLjHfRdCauSbye5Qi/FBZLgwXiHc2iVNSco
cQ4Sp0Q9ygN8E2rJ1iCDrRfnOUca8wHjbNthgmrrfMHDwUiqAxMyx3EAIplJ4Aze60/SJgLXBN+Q
gfgkt1ntc8r6LowQZf2OOZcNjG4RWLu3dlNzmgwZsOOOSM59poT6WHDntEr1DH6LNLSpMYb5Y1tc
UhIOoCqwEaD3smvqNXANSAa1Rn0nLT2OZbPWrTiKs4WcTXij10onWrQxcJpIVULQETY5TbwqSNnr
5aO2vnHfcge5y/5LSLAW8vQSBYfqGrgd0V8rQNhXwGy4bkfJw/03h8lttPT1yzbjrd2ARr2qA1dW
leqso5Xsgs0EmEHQ1yd5g+FjfD2472v8e7wFjBW5Xo2k4LoGkNtuY6iNHDFS7mbeqX+MR4O/m7+B
5vaoPuRGb2Fuodrb/IATyThBIaf9B1/udgRYiDlBrHv2grja7EjiZN9YxXTNq6z1SPYAQBf1W8OA
9dxbMpFdshu7ThYRaCqY7l0vj7eIEyfQ4K/CAwNQIqiIPN15iEQkQqM/op2bmVBDD94OHK+fasoz
CJ9PBsQ4qGLpBVXUi/gnAvFLESU3AuAhhzY58KvhFh8JtObrBtTTVVIpH9IjEclVkcEpyiGR9LSn
rDuXV6ilKqGmMWPnEWHlEHaODzr/UXR+JZLc7WWdk3tvu+hj23YfcnqxGnmYnxYDvC+SBEepeC6K
jp7lcjp/l62rwiFT0xSTq6twIOkEUmbuS887xqDCi4hpaVp1ZZZah7MzxH7xYJfGVvOCDrSiUsJy
AmGUUY6Zi/nJnwmLKTQmr/0/RjMuMan9s97w14Ti0K1f9euQa2mwSqa5eEcUpLyjkNHtsiKLz4Cz
cUkBqXRHjWe+nFTFsLS1mK7NJt7syaVJVW6nibNVrw8ob5ndaSh/YvdzR71iofCIkCggu6Vt6tMX
Heyq0iXJNdWLyM4Lrg+ogCxoc8fr3Q+Y/iw7WhRn5YClNGP3MGYs1bUYVRzKbMMOIkXTOZy1rILe
NO8O67S41A1z+aBiyOxdjIed/nQ2QjouQW8jrYQsioBuODctbFxKegpbuLi6LGbZaTkmkoO035fI
8ckYz++gwtIMKXUV4FpkEzuvv3fwLjQscQdaCGdF6RvrJp3StDcBgcRtyhS5VKh7ZF24WgdioVuY
g5OmpQpzRLNfNQj8tVcMIu03GKcuoyPtGKy3M9Ne6+OkmppCddsorUR8P581ZxeqiGcfv9M5NBQG
YnccNMzuScs0LqC+xv3z6eWkZaqnMU2XcSeEKXfp//151U3MIuJ36BbLwTekv9F+BDJb8iqnLYyG
0lfMUPJqco83Pf4NarsA2a8o7uLZti9xqwOVoBOtkLJ2i46kd17a+qjL+djZoXQSrDPJfjWuOtI+
V1N5/uPhwRM/U95qg7IYimyOKs2k6NRLYOzkPI/8SWol6maGSukgacwal4OGnHWtnw+f9I5ePWZM
hMW3G2pheWVc8ueIG2aVoVEmMmocOZnH1JOsXg/ehmFft7jTp3+HOYhhl8Yr+4vp/Gr/Wudzw688
VhcA/THyAuDiVs75YYh7yJFavu9wWrU8cXIPnWuEbh7oESd6UQjI6TZ01AViOh8Rcm3qz+oclVNy
YFBKfosq2ADCA4GE+uCc07HuCMaiJp2tOhXWaEm8GLH8nDiTM0sSVeXTyJ3rOb+4LNx6CCyWyI+9
wbL0NQe8z9bl4Xf7q+Yij7ZtFonifTEaI00dAoKJQ2wxGwdxl8685MhUM7A4WNm5mZwF7kzMw1Cr
/VN5JTYAsQyMywKBHUqt3ezB4u3AlZIgCSNxqb6eVG0Pczvitfl2w4D7PLWCzHkpvMgabEL7Ymxy
rp09OoDYMeR17RESD6yLkOAorTTIWBNlmeF2VZ89/XUONG/Brpsd1D1K1RI6JDBXvH0vj97UZQS1
te2tLmRiMIC8x26gFbhyWsxqO0p/eOYbDHDdH794/v3TH1xDSkT8WtRQ1fRIn92TSQuzfn2j/gFE
2U5hj1tdQyvU9G3gPOD5bERrMsexmSGEj2WNMQSb8v1f1Bii3Vc7akRMG0PwaTdrMW+f9o34A/ap
lPsiZpPirKfGUYBexVQZDp32Eg5G/UU7jeOA1qiDj0iopmBIs9F9OXp98DppdwuXn7So1d3FBJjD
yyR5kryzz/vAC6IvEbGtsycHV3h9Ll7618vQ3EBl1mbWd6h0zSUVVW2srxdpdDY+r9K5X5PazzIv
8ftsKZyYupCNuLbdyGa02cvm9x887BanffrPI7qKTj/3u7vd+ZfdM31YI9yLIBdm69u9OYpBdM++
/XDcvdc7OWu3LMfzh23iedr0SodeaX+L3Ng69kZ0uN7gNy+PXr86PHgWmfIuPoLkqgofyjn1YnV7
lY5crcJFXXtiVby2Ry2CV5opbQyTtUlAeGG2b9QDJ/IPc4ChqWWPY2YL6OMXz16+eE77dxQldGR2
kl/iu9h78vQVcZUI3lwhnzQm7UZoQj6CHwVPIsjcbT15zTYpryYRCTfh1NgwQXebHTMSdED2ceKC
TM04J7KTmP7sVb9dr05+9aDvVJJ1C8tRmCo+2r11FmfuypeUmKtikUk4qhRIuVt/bLb3xMSy+NYw
3dTU5Yi72Na/9YDQpVTylR+ic+fsGaWq1oPnXl5a1uqGV8LJNlubxZOWsQA3JxIOfJothEtQSFI8
zxYZXZu+0FHdn8QVMVY128fedf94azRgewR9k5aRjU2738zO5q13E1ub3TNzHP04ij1tqvkk48gn
GDduZ52rDRuKXFk7v7WdbYnuRowvt7Zv3LhWC7ZoQx0UAmOTp9F6J6ONmJ0VTieilR7Kf6GgYGU3
mzNqpXBS0UDMjOvShSbbWZCqcoOy08fEsL9n+erozZMXvTdHh6/2r22JE9YKPH9BVOjnF6/273OK
A9Rjrkdrrl+Z1Nek6pmMp2ByWxI3QPOMN9ez7I8mw6ln1v/Cltz9otp7O2FrPqa2bZUWZ8edR7u7
u3snEf6yb4Q4TAB1BQIjCes7ZJmXFDGmAGWDwqx2C90WgsGS4mjhrHCmNdb2pJc+7YCU+9FXs8s5
kzc8JRacOiM0NJE6FW6Vj6C2R4sLJklyYzQ9ePNqmxUVMmI56Y/oAtnHLPu0w1w3DfE1SSi/zqfv
HD7hoqwq8L+wuY8lOxxvLfLz52HKXus3IjjqdFkhJAdPfPWI/Ha74aVNPeJn2YEpn9RRXnI0rxZ7
CNbgPy9QolTTkHFVOnGwni2JbrGRw+mqrgqmZ+5x7I7Fw8nG0ph8IfDDifc9C4pNDpg11gz/IKnb
LlmNkJs5UMfBJ+G+lPJpqqfd5NhjDMPq0pT0SHPGTdO5hPtRkhX7aAepTeDF9VfTafjX27is3UTd
W6Sy1g/KIHHdGYdCcWBXZ14y3UtYKEeNlYDNB1Bh0yfXJDjRFz6N540P08FXh9+/OjwiUvjzwQ/d
5QQGngY+ZRUtdD+eRsc2TvLk+AiAr1+SEu9oRwPWdhN2kd8csxLmWoSZuqhzRyvEOTKJ87D+9Yb5
TWLXRlFCVnxMMAdGUSl4LYeKT1KQczrEmjfZxwQfudEwHwPkDpMS9dcaqNqnNtgw2yOzba+Ybtr0
1Yg6/erB+CRh/9NdGlcju9spB/Hxrgt4fXFfvBUVNOz1wOWtsfOsxN1Sx/2tm6+zWLjhvc5dnlyO
5sZAFLwUQh6I2J6qLImJufLJvTtNkU83n2XNcW3doNeaKXbJzwqPJGu+Z25bpGB2/nagSn0RrKXM
d0VAGRt1QZBswll/XhBjoBVHS1vbyGUSiJpw4imua8SmhUxrMkCBD18JeHLBlOTkbIN5mAtlOF5I
leeF1HV8F0n+wZT3OURYbNXi+eCopadVl4v0toaOsCdjiLvTxWyFI9MK9yTXZZ99kainFX5IGpKx
4PIciYgMBfOETz8UsXJq7J9/ktDhxF4zuQlFkeAKW2LI8r0ckhWH2p3m3z3u0AYLVFt3SUzkI8aF
6nI8nb7LxqN3IUcRjC0YtufJbscif9V13XFYDVprnX+D5rphtsN6uprt7X0xHg3oGpVjZnnqUOzQ
cYqDFxXo4DIYHCXAjh0sGCoqvNNbjgbm69kodpPon19MB+77F1jL77Pd6R/o0+iT8sD6XuhsIHL1
HKcM9kpDFvjuafEuDAx0PDgYfAPfjCS1gb6PwLhZ7YqnEc+kKKaowgggZcq10GNlpT8WIhGVJQbI
DtHE8ah0BRHBK3Ds4iI2CyTedXykotscc3aL6bJ/vqFigymSo5IQbjVUS/hC849IfGnQn4q5tJTL
+Ug5bF30dracQE51k/kSerRdQSxmvDlybC7bNismXy+0vygnS7nxUmm8MNvbVLbxn6EpcVj5BoXJ
n/7r9CU6k1hp8unqEnvymyQZjMxAq6XSNTwDW+td5QsduFU4GO3Lf6/KIXYK/ufI0p8ePVMK5apC
xe2KkJlNNgQEC43qLXFlNWcthh3zNSErVAK3kEYcJKX4yT3nBmqpicNpAK/IGuy24q+j9ulh7mYl
SW5OrPp2dit+mOCKt7l6t+L/Kw60RclezR1sKj1eY8437Zor17jePpMRImOj6jxSlzuk5HWthkRJ
s7kUBgZ5YllVsanBJl8TM0UYt1qqtgxo1+nMsD4FiBeyEkvldeMv8/dltRCFxW1IVURQ19Kq8Cya
cIkRP5i1FyLbJYATLa84IhBCmVrhI0KEDdksNsCF/yy0pKnaJXmnrXBPf9l6kxqAwkmLTZonRWEn
NWCYgsPs1J+IMI2wOjfYAJU3TvDEh0qbICHTKAgGTJoIX1IrprFKVkoQGM0Ce1rBHc3pj/iqyVnX
X10XhbeQBXl/XFycDopsuZct1aMbmgmWkohNJH5gRM1FW/Pk8PFPf+1pBPWTp68k/U2765cRX5ob
3KStdXN0J3YuqapwNtrPeSHJBhoUSJsRnzrCJ0GCfJOw+ThZOeIpibfYcZwVzsn0lp7vZ9lfmp2S
QezpIDlioQ5oiGuW4xPxek070ai45IxqmedKdCRZupCMQ9SC9H3KFcfnF/TnXbM2Om1m9Xzmzv2k
9XCrBTnzGZRaqBQps7DRnJFJ2UOPcjV2kZAJG9/FRyNZ1JF/6VIoPRvgzC8ql3VY2eEXcFrVKLw6
n6UuzRBcXWiC5javLH6is12fG/63CcVWrmrmxvkFO7PtRo8kOCx8fP2tRd/u7B0MbnkuV+6EL60c
GPAjKjwAkfKhSazPu7KcVbZqC+PT8QDaqkrSeDh9QciUtHlVl9AzjJVVNi6HHFyEGgYtk1WPN6Md
uK0uFy46Hk0WqM5hi9Oq3UU6lVw4Z9ORi7FJjOzJUlAk1C+TaJGoRZFJ/HjjYV/jfqXAEbtd6fN6
YM4Ci19VNdScULBBzZx81xywT0ASFDcI/k29gQJPdmt0lrq+GhP7VJmNEgxpHm22F7wm0PIllSHR
zSfD96bKWq/prypbFKftKIzk32bzKYn+i6tapcA99Oj+NCTG5MXOBVkhigJhFdym8/fpKdevXtP1
BSGSj+qbY+vuhN0V/cXofeRL3ou9UAXC+wuOcRhVHWlIfxwdvn7zsvfm+dPXdIv9UAeT2NAGBqAY
fM4t2aCOrmw/+byEFg8/t0MmVeaqR5JwbDhENIM8Nu4KJSu02dPdVbcQnFVqHScOHvuSxw69Qcrj
2m1ScqS0IktdmL5YZwpmMLpAK5wW3eRQaxwlYyNu5I4pB/Pi5eunL54fea8HKp3875wzxuHfZb/p
ZzevcyQ61G+J7owpNdJaQfJ85OYJBdA2OsnVcB0mzqltYKt5PxeUQ7XTqrgCuEbV+YbNzXXcphoL
pDv9v50o7UeLQNiWHTn5GIGvn8j2wttoUngnfVqS7Db3hWpXrdUYYt7P2+sTU20eAJFeh5OErvY3
0qRI7+kru/YI0uWgCBXchcxbwp3cFgxmAufwoxBPwAUnTifxxgvb1rjavG33tG4E19IoJoSQQAlm
1XnNZn2rf5PLH9tlpDWGkm//FOLLXftDY2bHuiDjXXsn6jVyuHSvJf6NEPt1Xic0NgmMoZRYFEgC
x+1yAil62EfA5BTv0b8RGpH1NCgggNy5pJmcvwJOmPttOGQFPKN+KH04AYSH2df6WDR6IaS1EyZ7
pgr/zWrd86KSeMdygl1CnjrOmXg6/SW7KheugvfjPRRIeDMTqldkYuQjp31OA067GCoHQ3Q0X4je
ZFJq2Ef+NlF5WhKi07tcnvcPav+gvxHPCh94UTEkHOCJy5jBnibUT7KDc52xbTlRiRjTpAXS5d4f
YkFc17kmqSMTXR4uILqSr34vS2Qnrxs7hFkmmOsM6Qc711wmi74kvjzq7Cbgi422wqRzuZ6J181e
lijUruu8cUG2jgE1KMzkJ/skGLZBK1CauQkX1vpE1H3qN7/jWP8oaAY8pqaj64tzCdGebWXp+A8m
5T5ieMXXqYy5do05yk5JbDrj4pXbxmjJ1jX2hvR9Rge8/fCFt3xUL2KivK2XiRosLu8dPOb3buln
+mbybgI1tfTobnE9DHPOCoa5hrO8L5V06ap1KrSWj5yA9JOcQJpwJkN85mXXBKH/rc6Bk3V7O52T
ewjG0ummMtPdarqqM8ujaB7dMyAfnapul7tbeCpCTceWFbj9XALHfglul9FUy+vO77emQr8J2fnN
/KVjg6b1nCb0cKV2FGbn/nvtmvM+K0LMSaxiiD3COeRrGIgL26a7MIm2MfeYBMZRYhYW1PY5/LXl
4RmJTBY4ZbYVdyUmGN5b8t+Qvqxi6kIpV9jkPb0920aKBYUzM4ko51yULMk6QG6sk7ikDolPuZbu
HVtjE6tjlNae5oHY3nLRUVXOCuXDxjpzHcXfCxly0EFhkm2eNnw79q/r4ST9RKc/Ja6gvzD68w5X
2QlslGDOVJmz//pqVu5DK3k+Xax6TZwsjrDBR2V/fzSB+XMR1njJd05Hkx11sOoHD7fKyfus9vzI
P7+fZ7W/R1adZ/nnD3L652GefX791d69/POv8pvszzuD8v0O/Dmyb/LPH+XZg29+f//rrOyfT7PP
v8VvX+ZbYRGhc1PvB54lrtus+HwFN6Ytv5prY2C37pTO8qvbRDM3XnzHqiB1OJyDNe4kRg1vvcRW
Mzgu7hf4TxhVPfQVSzR/Ob/K2G0Jyg0RbKY2syynKZSkVCixniEF3GhQ0oWldzgZQxDscgvdSHL3
EnhbFNfIv8PI++dSgkLYBC9hJ11vCi0HdatBGez0koSK9rEVE0/Swx8E2vOR1ePfcmSul6a5/2jY
MfSKTWNOJNH9rYeMKkLUh+5ZDcJTh9ajKvtTCEf0IiomgwJJbdd5ZU0S9e6bgt/6wPOaE5hZXI76
LMgVGWrCtrjk7YPdB1917u92dv/Ylliro0VZXGxVcI3A8z6IDhhjpzuNpoJvA/F3uCxPOrOCtTI0
l/47QvjvR2eSHUWSonOn9dQ8dQwTg4sp7fB0MupzsXkiVMVCEQHdoZ6vwiiAPzv3yz+hEu1XK694
fAllKxznKe31XyBe66h/Xg6WUG/RjUS5BQX0gRqUaKMBo5VyZsjJB0mFS2cHrtgGOqrFdFZ9TQc+
hDMiwxNsVwvto5hUl5yvplA34VmBYvECxAFt7N3KmhzX5DoOqCTRr+lEzQL7DwPy6DPWEUnH2nIr
PbKGuJyHnocPd1POhc3EIWXK7NsQqUoPx1csGkexeTpLdzPvW8demaPifrvZq/IUWfYcD6awwnJ4
GUxgtXOF/BZJBaCv5tn41vi35Y5Am2MRsx5byRRq7ATbE6erEOORDI1w04T+afbuTC1B8/45scjL
Xzr6MocnIV57WtmfAqJlgTedIeVoBB/Wd2deIra0i3k6Es1M26iTqC8nISVdalRJefnTD9+9efrz
k4qV9tnn9BKEh+XkH0uoWbPWaDJbLiB1opd55wzl7p1O4F4LqNCGedt6ASH6dSBy4gV8zDi8ajpZ
sOSUVbRSjn33Xaith5G6Y3Oggqa4bAUiKgkT8G1b4bd2PmWxRAK7L7nC+uySWP6W5fDa3dklpKXI
rvFTeZUwbLgd5jv4iyaxUzOM9mVePIth+9IIOeekKhy+MmRYYR2/cIOaONOKe24fKekuaILxzZve
XNSTEEJLnn/2O+a0T4vq/M7PL37Yz6+NKeuMeViSZl4dHr35+bV9QvdqOV6Yh48Pnj8+/Nk+7CP/
0dg8fHnw+KeDHw6Pek9ePD/c371T/lL2s2+yb1qLssw6BXHoNCTtGBjxO3cEixBVvYb8Nu/vf/4t
/Vd6JFJD7Qk1Z52SmsmoeXaS/f73zhtw+pgRjC+G2db1Navovxhs5/YF+dO6HMAZTX6SoeWFm5u3
bydb2du3vGH559QL/Vv3QX9468IPLea17n1RtXNaX/65bFl+5+bmzmJezAzLdfg/n76+c4cZJqJ2
hKH+sUQcc8sSDf59mwMoEPvR1pvC7hkLOHUW1nIomOHOZ1zWxaQ+GVV6unsZTpRDDnD54CVJ80BQ
+/hKHU8RFb2ccypWREfj5n3GKWxFetjW6jGlBuXIVMF28dydaGwOcqAFzNjqRfS1K4veYkGgPq2t
7PXhq2fZ0+evsx/fvLxzB/30RsOe3Vpz9ITGwnPmyiwTPhGW1/L9/X2eyAwmtomdn55E52mFyiX7
chvYJ+n+Q8DPcIQzuVP3oWyycntx+zsyGWKsr7dM+JtBpO0bd2bSJyiL+uHilCypoN8xGTm1rHN0
lRkPtcxxT8tSg2QfPmjn+psNGzBOIRoZyil0aYXRxpoFY3L1DJYyKf+HeiqdzmBUwTegY8KQOkp3
7sjdPNbL0Sn/ke3KVfQv/P3ETHg7td2kRLtgA3/3u9+ZOapjJsM2nyETN2qb/d///X/k9LEbnLw4
9zr4Xu4bX4ipmISelNU7AO4z6uNrujTK0bC8fEqkejC+kk4wEE8QW2nm++QF/Jxfvzz4KYe6/r5B
PXJxss57W8H7G6tlSECGeUlvfNuAhfldobHD0EEMEqKWhe+sgUBFyqCJ6o3uZFm858kZMLUz4y9H
g33CYiNayTLL3VAaws12Qe3cXk66D59TI/9m0lYy0Yn6oHGhssn/55Mfeq/ePH/99Bl7fuzvUIsd
vLMjnSnO3Wg/Oh0eyzax+8M/N+4OnWn6htQHffDmlXfIulz6GXnpjtJ3np6azWT+iSiipdesEcSN
mg9pYzxSLo/cfau3jFNfZ50Zjc1d4lVM4vuDpz8fPmFy6PCcdn4Abt6TFCAEU95jPs1MPMtwKDra
Dp7Ir3LkA+zO01c7nCrXO/fGFSCbbOextMszDlQFWiF+6jy7n0k62eyiqBbuQWbY8406ZI0p/Xxe
zAfa207cGwHG9bUuW6ageAWbx4v82t3W+1/bQPuvsxuRaMo6TN0cI89g/er7Y6Cfes3OvOqcl8t5
18oL3en8jLdetllX2rAc6f3WywFeEwb7qaZIYXi8p/wk8tFw9lJm5FnCZmYAUSWAFmFHuNZhVi0H
U2G4nxy+PNr/vNWwF8yNdPo05UG2hTVt4ZRNj9AP092u5n1EyDnL/UAi/Lus8/0W3UeijDt/e/t2
0UKr9reapmeHdoMbZ58/uLnZcptWtClb1c7xn7/ZP+ne3dnZwm9Tkl9pbh+IH8q2mNGj/2s7YI6r
jrWEIC47jq2hS8Mv6ANLP12KXlS8iS495UYOGp+anV5OnOyF7vkA1gyo7dztAiiITenetbLsZCrz
kQMjdsxois6JKHHey9MpTPp6ll2zzN81gaw5JruLDec1DDgFmQh/mc2nZ1ADnhbzPLGBoM4iCQZg
KzT93Yhp+rZW67TxCwaGzaa7EK4/eekxzBbyYs0JvfFmHe9rw3RNHqHwnjVNhcaWlC+YggRvSSAt
SSocHpF1uOCg1g4lhkoinET/aCK75mV/CrQ2VH3ZZ0TLqsUcyklNZnQhRSCgMzMHIzsrF9Q4HLP2
U3rDNeauOG2DJldSJw/xPIIK1W46WzW7tGlndNNORXYoBoPKvsF9mQqnTuIqM1Y2mBPHNVIkIg5i
ooM+xWt1PizuiEPQ7CKlmMZlNzsCTACWNcoNx7BEQVrRJoo9wWZ9kikV83eqJJQ9lsoYcn7Ur8o9
XcPOCHGXQ2TSv+vf/jc/vnh2SBQdkvuNpYkO8zcr5ssU5+feYu5kR4T+HTTA6+W4u5hejPMVz9m7
OXPohnmTM5PvsFVgRX8Nb4nP9Er6xYsyh2/xVt9RB4oUgve2kMWM+tXDV7lr7O/SVXF1q02i93fe
96tN5oquO3/dZLb0ZnKyfGstoXdwNDg7eyUEhnjqVxAar9iPqByokutK0wEs5iOX3YzlTaNwiAVO
1wSmdi6W6FmnohlEtCqK/CGVIxCgkqyREvchqk12hJWfV70seR92p3/48svId502pTcpL+NC4Yup
m17/FplDm+uYucF44sjNjpDiqkpz0PKlHNAWZEnBbI6H/Nae1mDhfJipMmabZejkLleV6pKIUuq4
ZZruS+3RcAsdw15sTD3I3o3Yh1gJGIpQc1abbOd9Md8Zj0535MnO4LQ77psKwdDMX0zfSzCy7U+s
ctoTG5UgRRH8z5ezhXiQPfmOkXadzrnI+CUi6X2i6J51FhOvNZ/J6eSR8w8aNWTmsGp9vMOeF8YU
wcbO+k8UFr8YwXdjN/QvtYEd6/wuZsShzFip/gvbZkTJHvhZjKVGmF+0hIMknLiPVWXGuPwRO6c7
AJ11ZBckKwsnUsEDaI1dbf4qb3rpeDe2iNitU6uI7tyYa5A5G0ff4vq5iCvvoYeoWgqx5L510bVG
h0eMt4/NTNIm6kbTzfO6wjxPJ3Dl0q6bbd8fH8+fH0wcg7lYqdNm8+Yw/QgAVt+NdN6+dVv0GPuC
CHh4nRkfNGXUnN3ywceESK4YaVWCCG7GRjGkuRqPzs4jixhcVtlIXNVJXdRjkOvazdEIiDbt6hGX
xbgYsCu3RTBAQTv6qx/KsdGVqftzRv0s+3lEF6KEB8GkmMFxiYvNIwsrWzaRUaEYdJjvtW+wNtIk
eBhNnN6KrLqAnPDq4FlGYtd8XFztOdtBpGOM+HjxXSAwO4PwzrrrUyuc4UOgnu90zYDVDlfe0xUk
z7CVvxYHyOlCsqGZtozO6xkoq4zlnHFlHMw0HQGcM7IrCVdVC5kja8it0ZeDQ6W+zJwWzft2ZVxK
ViDFoVRI1wxRSKDUWwLguNJgF083Os+GKvDc+5+zZ0+f975/dXjY++6vrw/TLsutYf4C+3DNTXay
+7sPHmV372YP97r3hzfZD99JX1MNyBCV62BOuKfbtGPfo8FyljHTyObMeD9W+NiIyVtOKrxeBP2n
Y64LsNojyt5PDy1r602uv4lU1iaxJ63DdbFDILw/mf1qIOe3xMhmfDqc0kCtKJog406WxVgMTbKx
BIzwIFtwJuaJSH0cAl0MmtG0eG/5BC1w7PJWzb+t8/Rq2EafrFg3HiUsgTP6J/q6NU3h41zg6qkp
o7cB+cfvTaS/fpwg3xttZOjVtmI3fwsAPIAz2/vRdGkSKUgcfSH7YRjtFekT8jdVmTG55pYgCNIW
5UQQAxiDaDPa9G3ya92v6yaOsf4WrRwr/tpWt0ueWqepw2c1zLsuOPV4qaDtwHVanabdRIwOmWa8
zxoy0ZbZ+oocNy3CD120JVILcjJK3w2wWBKbPOIUVDY3hs+em/gmn/CxOGWd7B08Sh2aTCyJOiOp
gJN/6/buacBJESfJcBZbzMVJyevWd27zJ2ndwdUR3G+4mbf3Z9mWcere4gqxyFiBPX+PaFrrKAgt
nxRJm0xJRLkYLb4mGesMXoNBd+gAs6L9+7WcTzvqbHq6HCBzLDNTC/hhVkZcNlR75nJV0Qo2dERP
NZnOVrRASg9A19HTH356+vPPkcsGSYBajRcAvignVkv55Dvs17CYB/0Rqq5YhwlHKd4J1mdaJ8tC
XWCaF/sTbQwM3/sqyq9YJF49Gp1NivE+rQAeG/HLDeEAAB+6iOXk/X5tL9+/3rq/VfMP5QISS3VM
MNIfLwdlTy21WyeSQWZrdyuEO7/bgzev0l3ybdoyyZLoVm21N+nSmE33r83NjuDeekgFD5wAgFpj
5oSJhCU7N47ZwL39tEABQ8d+6zCBpiRryjoFfOuGahlvPcnYGDcrhw2JcTCe+aa+Aftuao56NXXO
BXlt45wd9X6AmjZqNh1iG+Z7+MzV4enFFcQmzAXf6lYhvlVsScF77OZoqtQ5CVc9z0hhTCBL6gLb
thKJwy5BN8M8iLEy0Y+h3/Rvqz9LZxyJA+v953oAe3pGwVN1ZfA6EJ+0iG8xasagB2OehIZDZSb5
ocVFHE2ftsxP2JyX2lPN2hrdYNAW/EWP0waYsooKT3Q8/AsPKr9p2YF+Hnbi+DLKgNoHJ4lwmtbv
RfMI/B9XduO/G3VlzBgIdNh8WdbbclUKFnrTJhsKErB85SZgWZ36xLLMG2Q+uR0n+zG4DR9zh/4+
pdtRjBXBdZaK2dyE4rzotgnAm9E5zPndqTiTL3KOJvNGaKe2Asg/rubg6t8kU10izQvU1zKNvcgF
38kPQ+3bnp5Q71SsJvxxegkORwzFetkUS8HiewalFTZOkCCM4cjlkP1Fo3eKes7l/AL5vw1iFQ8S
4oXyl8ZY13rezrNqeXFRoGYAQNFmVIfE2HWCn1g7OKs9DiScGi1ao53nbZri2ZxbZWgWvb5am8kb
eBuQTKcHvK1CjDUlnsbTZmKbQ33ZQn4LOVziSe8jUAn/i0Pf+Z3j0YkXKQ8PslSMu47qtAEyzPFy
RJHDDdJG2b3s/l6cDeOUNqyO7WLdTDnz5qS8ZJMyKucUMjapLNOO2YyTrNJZokZMHhbRTI0C/8B1
Iwzz7yBcYohrdHD8aO/E5gpD4QzXqrx1s8EUOKo/4Vmcr1vrK6/NJqsFl5k7bsFrh/hBWHC+uFep
Aeq7MSXuHJHheg8572qNwrjH7UybA3gfQx5n9xKnvOy208RL+8JUwpuslte1UrRFDm9bLdTQfdvO
hbpEsvdFDNs8+21/8sCQTkFbd2reqjje4kmNflDcfphdc5eJ8pXp4rBD3UD2pEH2mrlJKApfOAHP
AMUlrqg3/wuu52J/uAdEwIMkrml4Ov6Crutubty1bWePvszuuqPu7MgQG69aMvU4d3BvL3spoqwK
1oy01SyTWnMMWU9tSlSa4Zfxqd1mLq+MhD+tFp0FYddKE3WcT6fvNpyP+KwLPaQZ/emPm80oBPC3
rbfVXQbtHQXwrPX28l4jmNuiz2Yq3+zT2PGEk4NLuTuud8+VqE9TF8L94QF+MH88jCbDXbBYZglu
XmcP1L/mpf83AMt5ea7OD427zoBbnz7glnAUQyyvJHEb62P6cpeuyKM/MjwT0iFIvih+aekO3A/y
yY29JfUVleWcM0xly00g43+U89GQQxXNHQIKxLj6Et2wrxJJzAx+1h4drKzfXNsuJNCeqofKFOfW
ukCkHueZOm7xf4xrF6dFPWkzKnZKcGqqIkfCbarzYQMevc0IdADV+fSS2V+WPJ/RZF4+fVL/oMU2
fwBkpXTACW3BWqXKrpcPHCqyymQ1cXOH7ec4eo8S2YLyysSxUXc/N0RqhYUUu9yj7dWbxIOK2GSW
zAxE7CtSJyts7LDehD7fQGSndgbwtrCtWYwipk1xhvSQ3DYz4uralzPJTKUGfjrqnWG1I73mdMfk
GwQd/tIFaFZhFkfe/1txyMm5cd+JaF7aNAH5TVK/cycmtrbFZzcaELbjBQ7VheGafrvZwcVpSEj5
KRkpDYpmZwQ1j50lKh3Xe8BzdgU3UW+IgzFYumSKj9JUVLMBhOAatyrHu2xWcBWJmjkAnmDyTH/U
MGFt693se3Ufhhc7koKRfAfPNFPGreA0eaNirKJYmbWQw+HdaFZ53aUpsM10DRlzMeW8UerAQKf1
ryK9QcGKsxPHmUU5HosT9ZQzb6HYlOPP918hy32MXGacISdXPjZfw7IZzOi1AQZyuat5mWCuNmqZ
5suSTSOBwqEc9U0R/VqcC8Ut1QJ6b1JglItL5CjBRalsFC19W9QhtF7NlVihGVYDC26xhdCAkDtZ
M+V2EpoDYlMEVydVll5MVvX9/Vqv66J++S0CK9WlRuhjRRK86AFDSe33ln7u+MJZUQ4+16elsBw2
HbbZ45lkzS/Y/WyVwV4HEI9xhmkPPz1dmCOr6FJK3QF4fG9pVZPQnI+P75LwWfZdHTTtAqMejFpE
j57+gBBprpr2eDEf33uMggIcSpGyjBokC7UZ4cpKarCIqwH2AEaeSrzWtKSo3rlBNwJ7Q/ASZ4xP
Y2HiadWF6VW4woqNh11ZRixEblKROKpGvD5flRx0XRkIJe3YJmxBwvUQ+Sz7XlRF2xylx1mVNYQG
wFQVQy4rVOL30aBzWVzBT8aUy5P77XSmRW+M1QXZDSTnEDwYzHmcfe2Wk5djQfpLiffpeog9vpjR
jWOObr/m7ky5BFxcmkAi42NSgkueacN5whic5E8aD/NWlZ7sIcZZxxQPpr3jlCH9lExdzdlvnk8T
mbTiVLFrChLz9NuJJDTi+xmloIlTb1Xl/P2or4KZwEa1x8EnoRuuyXqjhGXBDrj0I3z6Wac+4dI8
6ttfgR4TGDJ6QY2Q2vmA4GVSasZEDm+ZVqUUcSLB9rSc06bAk+YXtuMPOH6vMAuSAETGkBcee7Wc
8OXaD+2Cz2Wiz4oJzBxdXS4Eu8tZ0auWqPxF27ion/jtjV2bpvJ+4Da3Bu+ymo7fl4OmDgany8pt
h787p/PpO382o8tUDzU8iEakkpi1qLZUVF/KVjDhNMmJ6BWnyolsXULjLoOli5Q4hxlf/o9Jl4VP
U/5KTXaFGXBxJa+hP6cNa4zHi1ldfSmVGcukrQrL+0iuTy8hVp3/3eR/IxwgR5rrNsNwbE63ofBK
fXvZd7UndyJEW8JGgkcMuaQkTuZrtZ/QLrv8qustD+SXkpeTKdGd3Y30m6ccFN5Uu8yZmzEWGrn8
+H6ikr1iazRJd2jPQAt41WhZ8tDFRgXb0jp4EAFbct1grJ+5oqZ5GOl8WUmUxsUUqdOqnWvtDH4x
owqpGpq2LJ6vkjY73dw1dhI+mZSoLqwjMUaFlJ4nVoSzhVsz6r1MsleH37148br37ODVT4evjppY
J87DzMuSlo1FzPCqdZPQ5Pb0SxCZlH2z4qw2W/8wv+aecSI3XGTSFDFKLPmz7CfeIVQY1ijw4bh4
TxJ21vq1JLQzXlQodgNlpCZUa2MPEx1JHDRmTygYmgWJh7B57ETO5jxwQqgS6ISwzTlydcgcWoMG
IGhkjZ0dag2QpYt4zFOCx7T6J9nFJhyzM0wdXOB+ZP6IZ3OXswH0x3MygGt1d0HrRN03mNPk4ZrL
BIDnGQLebZNFOV/RRgdgpSSa2iEy01nXcMbJ7N/hJ0kq3Y/6EHN40FgvtBhBCDL/DrdUEiCvmLMf
XRA7s+elvIx703x2KkXAZRaivnQyKGe0DXw7n/z07Eh8lqsVnUmYvAT4A/RFEj4vkXdSQplkuIrL
PcD5lueYrs/IW3shAYdyLATB7y+QqeTXZlHahAJyv3QYUF84p2GAj/9og5DLD594KogQ5BFvi8Dw
2QCJF5Apy7k5b7f4VhB7kO6wgYq5jX7T2obKiWs078pi0bea8Kaij/A2UcTzYNrAD90yWTq6aHI5
jPxVw1J4C5OTrUHqgvOZeW1VSTrzTqL0h9+eM4f3z/fYeOR0ZktyiHM87IT8Ii7L9U27yyUTQ8RH
kI5yHkhqdvj9wZufXyd4Ad/bml5HpDsPEqgYE3n0uY0JdXf7CRMF2ESt0/G4FR3Dyh3ikI3eJdZq
yxe7KQS86ef2PQ7Y11X3/nLw+vGPPz89ev2bLKl51h701JVXMiw7nT3W25hYXSF1IacoKF9U7xKh
PvZZV/XMYdVJ8xxSm96YPtSHJf9qwgHx1ng65Tj1YP+dh8H84kB272JW47Kctf6028a+IJuLVKwS
LQL2bVwqDcIN9TqSFAS4lrfQLa7OqhBHMOHz0XhUDjBRJ3Zq8/+swqHn0+UcfBFM8/e7uygUMC20
NLcXpsAd9vh16uur0OzXtOvS/93s4Ve7sf3XvPrYeP42FeILIWE66RmPXMVVojeLShJVtvgkNBfT
hZOHG3kWSWDPOvzbm6fIPjuAChWpjGAB0XQ99S1AZ+ChbCYUP8wOlLUUpgpaUknx7mmSNAOpiJ1h
UBU3hJ9YaCxvgO41WTs+CbDSAFUtOiZOfg2Fltv0qetUdsCL5PTUEx/rCG07vg3rgNqJAmWyDuMb
75Q5MWBMb0ppUud117vdtvB81eEVpTUTp/O4g9Cv3UevMpvlJFZT1omCvem7fvB8EsmyMdyDqRvo
/8oMi054hce//b7Gpd/7O3jXrfgGREVoSq9SR0Ct7RaAl81k1Vw4sWJBzMlMdGTSQ7jUEtYJCdbg
nqPnzMTtmQwImsxHy7bL1Us26Vm4clvqj+2UWjbNGJhzdhkD85sTRomQhn4iqbpgp32/3bGzwSe2
ulH9tN4135J+Oh1csWeaOqEpPrzeqrZE54mxSFa6r0FtWzeuaSvkDxM7mpCeecx7CGRVs4GbzN9X
SSJhEnzRTDmwepE12uB0XwZC91a1N6mb89QW2LzuNuvWZcml0XXErzXLXLVgXZJRf6fl0TQo566Z
EJ04W+ngQXp19TIGI64lKFuWXEz+AmQxqKVGu1yVpUQen7Omm+cfiEJCN8qLESO8/vmVqSG+Y7FQ
BLOb9kDUezSEq/Z1zmviSlcLXIIcE+eooMHVTcw2ytDCuJfzmG0vgTTN9Qri44LrRvKNEXOCsCDb
Hx1Nr9bqMkZopnCr2MsUN/VlzHQ1cqG3yRphwedWZNR8GvUc65NRpHctKoq7+UiWVtqYtwYVnOt5
FkQaWp+wWCVpOL/9Zlqa0OoejpgFLTLJ56fBZuNiMoBJhgDqkm4WgycHhgPTxMot1Fey40NBZv/4
3T5DMYOms5ENYCHwbhpvcBo+DLsft3yPx5ILM/5p7L4nwhKeLvtX/XG5QgPSA+mOTVYOJ4t0XGEJ
jr3MWJ/zgKWyMvhgNL91+kKn0MWt2iJN36AxXDdQC7h5CGO1jPT1z9fHOKznRkg0DDM+sNYNuDoa
4pJVI6n5wBlWB1yOWBwikXxhOjnDhareVbxwzw8twohJO+RvZoO8vf1xU9sj9SxJvUy0sN1p/NLy
fgrpkchW2Z8bFMkBh2d0k9Ft39yb1/ObWalr44dKlNcqhALindAKLdmX7DdWWY2GYZk0Z8K5wnCi
S+etuNMNcNFS440IF/0/UEsDBAoAAAAAAEKMZV0AAAAAAAAAAAAAAAATAAAAU3lzdGVtIFVwZGF0
ZXMvc3JjL1BLAwQUAAAACACKqmVdVhXia/9FAAA0GAEAHAAAAFN5c3RlbSBVcGRhdGVzL3NyYy9p
bmRleC50c3isW/1227aS/z9Pgeh2b6lUpmUndhLbia/z0Sa7bpJjp82e43oVioQk1hTJww8ruo7O
2afZB9sn2d8MABKgZKftXSc+JoHBYDDfA4DxPM+KStzcE+JFXVVZ+raS8wHeXsVBkk1VG73/GMsk
4ocsrMtgnEh6+SmYyzyIWrAPQSqTcxlW8fr7WbagprOsrmRBT+dJHMmiwfxRfqnal2w6TWTzWlZB
FYcvk6AsZTm4txKTIpuL3j8iGV4tt+u4d3gvbpcSRNHra5lWp3FZyVRNVsh5di3XmsMgScxqIjmJ
U/khqacxE19lQcmkdqYLcns+UZfy9WSCNQ7o8RyUyoGolrkUZzIIq3dZJIXBUFALBt+LU2CeBKEU
H66mTHQKXh5goUWcTg/xniWR/ZrKhf06SYJpeWxaLi4P761spJi5zFLGexWnDqIKbG7fnVHv5KIk
BeBxVVwlDkEMR/yDLA/EOMsSGaTUUUppNzgomR2ML5yBeTIaBZg9redjWdBYWRRZYWYRX9GTJNQe
ZnXqAOZBeBVMZXlADKP1giCWQEBwTVvBCweU4oBqBLOqPLiyuUVUh3URV8sDiNDhPXquperRZK3M
iOI6DqXLdqjN1bzbBGFRk+Gnagzq4nh9MlvMjpDFdVg2XDUkAMcoTmENSSKjDdhAeMnicSkfJ1kI
PZiONGGW8GBS1aioU7Se4vGsTi0p0ERyFAXLclTGaSiPjUQsmJztZVTnESRNyJUB/cLvanoNwrI+
3iDsCuRoBLymPKhm7ZpA/LhdkDWMrXFUSFBZVKNcphEgbrcJmy7WyCguHAvrGGDDZ7sxoUVWdotR
zFGWJkuXt/O4LO8k6WUGFU5hUkxPHN1FTppVzrvilzMf+ThmYYfDzpxGyjQj/F1czmiFraEV4QYh
Z1fORGEAZdAqaDU3rIiwKLfLYmY7VVDBOPKqM7+cByArnbqNwFV1FktNI2Xwdy/5XFYVOktec54l
yWiW1UVpTwDuxpPlaBFU4SyJS3cq3TkPfidftd5xnSX13BWFahpVM6jnjG18bS42LteRNua2CVx7
n00EkAvqsDtM6kiO4C82wd/ePIrg/JJNorttELkUtx0NozX/zS4INjK6NYwQm9A7mgYdXprFNG7c
YZkM5tMijqLx6EoubQMB3xfgWlXnI3IwLpGWoNsRIfqjbJF21cNRJuVAKK7VSqHgPJW6WugR5eNr
x1y1ySh3YEFub4tcFiH5gLhk5RWLWZxIUc1kIb9HUwZil/CRiNzoxKLEJCgE0jOoe0yjfNLqIptC
1Ur2n8hoSIbGgWr8HbN2XClREYRzBBoQESSgfQAyJNEgsoJEDXrQpTw5qFLeR7DrlRHo8JX9A8WI
hm8KMpscy5/3JMZnWYmEbfUhon+lko13YNWzJsM7utBILgcqK3nu9RhslGaLXv9Qj1QLU7GitIdj
6otLSgtvHG+oB0SWj4d8YvZ03ejsJjuIzWJ1D1QoDCPF27IlRUe2VxTmnIVgBR0i5hA9+NXiBloT
GDlMdhfYRJ7yL2DWBIcNjhb7VFYq5etgNRxHPzm+SrZDmEodlu+mpZNAEClqiYqgFqXSqj+Ec9P6
1PA1rLVt+R2stldoOVTyu8Od02zqjFUaDAxqfs0i1F4uT00E67JVtxvO6leLubeM/QC2ocQ7ahC4
yMqNyKBRsvpkPOcdtDBgG0xbDKmUUXnGkXtdLtRJZtPIZmNsZwkxnpFKAVrsUXYbakvkPD7K1gZr
cznXYbZr+sa6tQvQ0K7dl1dxnm92BaZFWbwxTRPTWyrg96hquM18AnJX6G8HUFjdaHE33OXwM+GY
1LxC7UfzOG28KDGGo3THQEOAF6fo+CumRGNHhJXw2TnZDLVbWEOddPbbid7d9Fd+cV61a3Mz+CDP
42hDkJkgGWF37ACg9uIo3ymxSGFtriGoGD+FVMOQ/SHBiI6KOPNqPVlweWovlrQiKrKc6LHX3IkV
HVLDLI9lk5KQHhldYrJGpZ4BUSRIbd9q0Xwmw6yIHCGq2QaiQ7pZ/Dr6gnF0JjhBkELalGTBZuzq
L9AqCo5M+40Y7z86thIV1H3Wq7VRAV1qaGHB6+nWCTmHUEO5gYxLPZ873Vph6UxTMrJ2kpOzj6OX
70/fn50fdNei3TcmJmWm2ub6QPT+tisfRw93ewNu+xImWR1R887wcbgz1M3TSUptj/fHT4emLYpL
Qk/te0/29yaEYnV4b1KnvJcmaPFv57A2z1pSH8V3kaHqlEdvPv58yv2vEzlHiH6uySqQDxcp5egG
1PPgjbKEMr5C/i7Dqi+eGWj6USuP5xS2aJiatX/YAKDLz4zwPR6tMXroWgPkIG5B0pQeIX5NHV4v
xoRikdVJxGmnknIHS1mEwNBDjA0OYqJnO4dAx0Ep9x8NeuIHkrMaseqTASO9PY3HRVAsBcQK8wsW
qdqRQ4ZLpoaMFholaO4DEYhpEUQxp+SpBRFmEF8xIGzUyIQGacQvZLy+3msbQvfysk7A0R2BDDob
iF2sY4q/D8UijqTp91t5EknQXk9hUOYIpYr/KVubHzAFjccbOB5joInvCr7faLgSqRLnxaeBeHMJ
HtIMh1YH8TXKwpqG+iECcGUQcVp0HXDoYXgfS6lmgP9kGmYyns4o+r6xUXK+4yM9eZmltPno9XYh
0fsKJJ4IXrO4/+yZ2O2v6d2YRk81JadximjykxaONxwI/KeVWOoxnvpBFL0kRp1XWU5AzLU7QHYG
sLLheCh3dnsW2NSfxElyXi0TcifjabfnjBR3jYaVtXKuw0jV8y+tTK3HZfuImmsK6b1kFtNO+Ak1
dEwR84KFQPh5fzgU393kX1b5F1EGabmFTCKefLZJrAwSwDP2bucLmAvqUVpcb44COpG92xbf+9uE
fxyAchbADTMbCaSYjgOwg//5e3v9DbAvkppAQfO22O/ORYv2SKPBIrAGTBUPxNB/2r8Vz1BzvKNJ
z6BJw3VNopxKodzftVGS5SmfRgY0EN4nsSXKPkjchVR5AB5K/LcoYcl6Ct3w6R4Ra8PDA5X4faP7
oV9UgMui5yiJTErpkv1wM9kKz97+XWRrWp5gAW+sBWykW+HbedSO0gTr10e0EB7eS+Sk+hbVO31H
R6dJNg6SkySfBSQk/+He4S1r2vH37l4S1sEUPdm7e1ndSXfWCL6drU/uImH4x9kJprUy39m9i4U6
CId+lb1CCPvl7BRhz4SxXt8v8ySGmxz0+hc7lzp+/YTcHZHJJGJiIcXvNTls9owR0tY2vlFQClQ0
88W5KkpoO4eDGSFDPBOzgPeWOIo1u7OHzQQlYAOgSoA/WiIX47QY6KWgBfH+EwJYUC7TUDRhDIiT
JcUxPCBbDVLYsZPJDuyc141gRosqrKIVF6j9mOVbRaBmr1TYPqcU7acijl69oIWBqJirfjGWYiJR
dtJSMHs1A2Ibl96Sp22uO7MAv6MvSHCUqwwWQbye9npYlVpN3w+p7PWa8fSjch3vZtUX4Pq/kgUP
Grz9NavipMilT2XDRN0aOAv+GY861qPapBKtPqjqi4OmiLLHhtrpt/nwBaa4FMfHCBUPHz96/MgO
FZo8ZBpQiQujByarubygPOTiAqZ2gbA2EEiCUWWLi4f4fbqLhkcPVcMO/XLL/q5q2SWQfTTsPkLD
ZTvlBOR5OtUhP6VSqUuRTRQdtsdqSZzy1oES9cU5s5y9XN/CTD/k/QB7rFjkYqIfxU0yAf8caQ/M
NCNhLLLi6sesOMlzj21iQBMSDvUAQQ84g+y7s62ct8b9kvz+pcntlFPxR6dKSpFVQtmHAyOn9A3K
2icizUxuCs+3pGp//7vwNGt7j3qXxz7pufj6lTSw33fwbhpvqF5HAaUDivv84iZhZIjCk92gitLW
l6rYuDhflnTgrbbvykvHjaq9GyxdNmhX98h9nsktdjIKCqpGB8ZL9qqNfzaOU1cQBq9HLzndivi+
JFS9HxmRNW1PjPk6Rd/HPKjmaS9qAVdMc/CE1SyDCrR+ehZcrzviQk7o5Inka1WFyuZUSqlUnnbI
F5BstiDPBI952HSRFKjXZ2f7MqGc+9iHApV8KAM53yeQ41vUrG/C3LBFmatdE8tH2fspnvJaIZ8d
vY08VfUlshKpyfYsuy7JmAmhT3ssRsZEVumzrpDGLegRSX4hj/2fZAWy3l/TnptcvFji5e2rY9+A
91s1aUyojWUwEF9rYOmzsy99dvfGItIffmh1j35NpX2oleYjBF8iDZfRFnSCeSoCtVbEHUK8mMVQ
BcKKdwi2RlJPJS5WnUSysKrFLqO6Rzu0kDaMan/P5bkj6z5J89ifj17WRQHp/oIJj33EGqbu7atD
O1vB+GPxjqfxXsTTtyjAwDTkRo/39/Z3dp4+hiPe3d97vPsktcPGSpuhu/1gOjVvPtRULGF1COUl
2wuf2/HFgDY5Ed5JGhUZCPn4K1wV7aWIaTCnwEgi6htbU7zVJsXlOlfpwRUfqs3FOAivREY5lE6J
7NnUPSEmYu6Lk9agl1nNqLRdzwPU8YsY/ocRQGgsOT4/izI61BbIWej8DHkU6vsaOV1IScyAqCFM
8PdFoDf2SJeRT1FWx4gpzVKURL5aD3SkIYV332nTIC6vMCEh07drSLALOiYMStvtGN2iDKmsUGxR
nkTRnnk3QWVCO36Vf4+MzUxzDodyps42oTmTAIHnsOtm6M2YcOkpC2ITXMdh/IE+mt0wRVXUvBfR
aq52FPYk79NQ7z6t6CgQimGA76Rb69pd5CvM/8++8SSKzAQ2A/66O1QjOR0nCry1DW9ONe/f9/64
AyTf16IeL9+RHgO1k5x3XUyzMWGn61DEd1m6pQywjVBRln5PETHhM3kBU4OlkrobRVbxM2Q2tqj0
ZSa42gzKml1Bo4usns6EDKDLHBpJyZc68Tcpu957IQZxBXKhM8wmB1j4SHMSdSlRs4bOSF/J8qrK
8hOWG4ilh8FdgzTMy6Z947CW/53OS9r2gOl5J0URLP245L9NQLFCnWLTRK1pfYtgFlPaSp3AmEae
F/C6Vc0R+PAS4NVyxO6JMnRUmFV2mi1k8TIoSeWpiOcNTKfZ3nOFQmOWYx0pjRtHk2oxkCYN7Lj5
bhTYBHBPb+R8M8JDMf5Dypzdm3aZ6lCCXCtnx9SaZ3FasXer6JiniS4tiEEGv36bM/fFe/bglo+2
UCFp9634SodJVE/5fNpkZOtNWAwTn7r7/jzI2ybFTLV+crybjq9o071hUie58ZQXaBIYTqb19GU2
l52ZWMxNstMXutE0Hbq7O0Svn8h0iqS6AaXGi+FlB9TM2YXW7RiwNoMBUc7Gc3IpSwNUiFR8txSf
JlVdtGusF99aBZcPZxw9jT9V4J0amOqAJJt6n9eqAB1626gtvrtRNK7aKPzdDSNdfe676r9qZNWh
rGlishupbXD/aofA05mmrSdMORS7lnalw36X9zqatABMdEsPX7yd6HcrewjpoIW887gxCMpvuM5a
0kVqPCg329QotHFEuQPZGzxzIMoETp0PZFUuYRDxUXyUyZLwswNP4ivaxDKbMIaVfsOx+9A5tdEE
/b7vbfCex1rNxHMxhBK73DBqZdXAVgDWakapu/yCP70e/fZb27qvJbKG1KlGWWObWsBS3C7g6y8N
3L+fv3/nq0gaT5YeE9C/Zdg5X/qJi1vHNmffDYY/o0Ebi5s7Sht9C97nv96NuRfeA2MhpiojB1oY
5ejR0XFEG3ya1VGNLJhv+u0Ph0M+jlNKa1l51Ph5Ohe3Kznt4KKmQttk2pHjSC28cNtLQh35yoH3
GSe3kgFGjQFuQEpQ3+RupNjFWVdbzjx4IPQlElGnGKkKujldMUi1kYJr84wSQJnlCVL+ONqacrx5
sK1Pms9fn/369uXr0enJi9en3zpt7r2TXHj/HKTBFKLS10p6B01PTFs4BLnIg1FZ5+zW0sqG/BRv
/RgroJLdYbSlj3EjG+zVu3O25TovXeA6ktcupGQeRLJS2ZEGL2cO1BnfWabj0VhD1OSYyl0HVUG7
33NKhJuV1DmlKjbUC7pPTJsoqPa4UwHGaV5XW3StOM/dAXQgWVD2VgjV3SAfJ7VEOVjNHPymUcGE
YIHd/aGIDXnIZLQcJwVy2ihZGo1AWk1KYaXVemv32XPgdKV+QZC8qUoPfqF2g7zt33xPT/u1pCs+
1dcqnsui/9229meshPfEA95zaI+pyXC5smRGSu3ax0uhbhgSDN0QotK4pFPqIz6wTavn5OcJHSfb
dPWKnuKCN8ux4iXWkFHBatW7zd1A/nSHcnOodnv750UQTfVnId2LwiTE7uVgmBUlSGMadaAHQ/XN
4OHAHsUVHyWTup4h6PN6XOr7C/C0R95YY+H86DqLo+dUU1obLLLifi/l7XcNa6pbavR5bs6peAb9
jrDFvQ09FkTTZleCY70YGtW8E7lInorXKHSQxalz4EnqcWefrzS0tHLjj0U252tgHooedR9Ml4MH
FrNViFV5Iu+ANqn8t3jZFL7tutg53kfEdr4uAXLuQOhpvs9pYjZUedinyG1BNV/V3AXE39isARy2
22wN/aUWBAFZS6E12EyrS6kE7PBHnxiMB6wAVDWaL7qOGOi5lgBN3Hz25XnWMX0rPuROHmHpO7to
nnOk30JHEgou7QHM9NVAXFz2rXWO3WUwVR/iJPE0A5wlrymuYs0Rn493SjBDH899VOZBqmks6Q7A
s5s2vZ4HBXz1qZyA2739/EuvrXZzLJqvwveGwu0ZU4FWnAVRXENBeztDp5euNZzzXZfe0H8s552u
T3yv5EA8Hg7bDjoGeKM7ejv+njNK17wH5P0JcIt11AKYx+knur7CY3ecsc3FiYPm2N5aRxBeTQt1
n7DlNB17yWEwfBj0BF3ZehTujffH1jB9cccdsRPQPzVC368wI1Yqr3+uX2+U4J6Lp09p5NOnP9Ao
blSAR9skMQLvOAeKDCfTzKvK5tst90YQuwTaVdAK0KNLV0tZ9Vqbn6ub8D/DvfsTxH5Uta/Ip6fZ
wqNz8R3K7LZExYfk+8O+2QLjcUd0PcDg5hNrum7fAdlv9fHzdzfUuKJZRTDNPrd0zHSJbRHC451J
FdCR2H1ko+TW1axB2PZYyNTQbRq6ijSoTug+EnQRLMxXEgiRSCrok8hMb2SlVNggv6DPLmk/iqoo
2nwIxDSh6+Sc2zViyVFEsc8+Rf2J3Gc9H2jdEeGmZQPMR9/cay4I/Jb2+kgLaJ9M74k6m0YgiTeN
0va8kzhEDb7+pqb0evqrGuQl8MT9Xr+VFpfDZnf9f//7f3qH38ShksE/imX7v34rH+jtfUB8LaT1
Uud8Cy+dbsc+fXPHc1p43zagHaS8FU4T0rF3+VV/SsKfr07ps86vxKQJfWIDRk2QCENx3TncTare
r3S3akkYzbXTTeswfWohEBTSXwwxX7LcsopX7ag7OazP8wgjVlWoe/ktmjOn+25haRXeOl/WNgou
Oy0yrDOs3idVQqgudWTzim9PjGk7gHyhOaP4oL9DehEUn+Jq9jadZKKkw6xsMtkib0pXNVL9MREd
g1qnWmr7xWDw9HdMg+b7qNWf+LbJ3se/SilRfdbguf/slqgXxddNuBMLEx6Gw3/jsvYLIpQKbiqY
baEJHW3Me5R/QdLyBJEN/tu47iNG+Pzm8z8gmEnBtWCItG65pb+Y3SrpM3hr+4pvpKDOLoK0hKrO
D9QjfXn6n94WkdM/FCuqIW8DerinYVafV4gMTIAhB2tsZloL7XbgnCTSDtGCrxvBDnRRAAiEnBCR
FRWmlKkD6sTzJ050FSLDMP66Gl12u8orXmRV9X/VfdlyG0mS4Lu+IonRWgHVYJLUVSVKFE1XqdRD
HSuyWtMmk5FJIklmCURiMgFSWjTM5mk/YGxsf2XN9mEf9lP6S9avuCNxUKRKxW4rkZkRkREeHu4e
fpZngWQxVarlR/oRCSmPJoQQU8MAhWPypoM4Ls1k86f/TVqq8R6uAUQWhY6LE9aLUyWIuLMO5J7b
/mtLnGAPylt373YT85/1dONuxwUfkHvgVxfQ4bTo9RzIx6BkLym6KGv2wbrmLsBbAsg09205xgEb
b8k2cl29Gwco/dwOvkrIXPAdRHVrsb/xRp3kwDxXgQWjEATfpbQNPXeAbFCcZW5/3RI/GTuCG+kd
GbsY4PBAqDDYcJQ7k5saX5e1RyES6V87Vjji3uMn+7+9ffZ47/kuusrKZ1sPrNd7b97s0EuKVYVX
ZOcYjiQalE1q1XhQk9JVe5EABSuHOQhBJSt7R9khWTTIR69APS8bdTECcw/ebdlz0VqKnTcv9nf3
/r7zXBRKzvm9p0RrT+K+pZ7DDEf5LhIDeD6s8tWLKhvyG0CeJyAJfUKiif+uAsemN2fZZz3UrVvq
NqBw++9IXY5QNSONkTLg3fTGFE2xNOkHxIZ20VaDiz7EmNg6efJ09dbd9WQHh2ZNGQNrdFEywOrk
OAewZaiKtngPwAZYFqo3s0NUfu/hP3w3J7YDj62cDfh6M2kbNY5SIzxQOgoVUmXzIRij1obICYX7
W5vRVaytJWYI4CJdrykhiWm4R6jCzT6G7EynavFuchaRx8hp4GH4z15+NuxTZGh/fIYZNEDmGObZ
qH2rm2wcg2QIzbIhszmH7a0bpicfwi1cPQK87VX5YKt1WlbF/wCMyvot91aDAGGTGAedGKfJh3b+
GevwAQ/dmozSomc7xZWDpyDFfdqa8OWadqeNjTrTeZTPXAPXXfphlncPubpHnpzzcd/jby5JxHmQ
DgiRdNtQyGbSJXfFoKNcEZs6WnTpkfUYoMUc0n0mY9uECXglIzyqXtC86MzKVgnMBCmBtVlFEALY
VxVoKLqc5+doo5mShmkS1SDoD83aLgN1fcUPR2jaMrPX+rbvd5667p2PvNcTtSXOzZ8euh19AQgY
kGnwcM0+T6pRp6OUB5pSRDQIu+PDX+EuiwomOdFMEdVfm3aaIyZ3LhnyckAtKmvN0Am5e3rP3VPg
dqO8QnYk6JWu+3iBGp49IzkDP0Z5BBh/k5x6z35uMPdnEvhvzRNUJwpUEZnz4VoEPB11yXoDV3gK
s4B7vMr3kiVDvB4lzPZV7FmNbnIgxFgs7QWg9LA9rEr0xCePQD+jUz0+g5PqhN066ni4TVn5qIa5
m68D6Cwl6doUpSbxPxwiRAx8jJblElOFaDRCU4S3+lp7YYh5gX1hKcUF9nZTQfTKkXGUvxFFPo1t
DVgIb0ziM2CsIDuNtlpAL8uLlmEsBMRULXhqnzL30uhfnzjyCseuLW2iMFKiaO6dwro4Cu7wp2Gl
IUkWohxeWXlgLdXznx45vcu3Wov06S91E5z8JqoCBzlOyQi6/NPxSI8DAu670XV4q6NUpYCYYKU8
ziNZMOHq1LmcNXzOIRMkkronN3Zhoum8Mc8xMcuwLupW1xVm4eaAomxkrnpn5AxN/UmGM489cvfP
ZWbBWn66G5mITMNYo1otZBTIJfCeZV5Ok4OpQmQ4ytjon//r/xJv+ud//J/WPG7izf7hmjk25hbU
cMjszwIW8194nM1fPon0uqy4fSxBsfFcowCM6QMBqsLcQHKsxvkUTgKqGHbzYVZlo7LaEjxXU9hx
iMCjWagewb2IWQJ3beItM0AGYMI4WxvCDUvTXNuwCifV1Xj41/KwMTPRWT7KKBXC0chKFAd3mqH7
t5cSTyW7UPcaK7tCNK+PpdPGGXoTfEMf4/RJ2XlWUKC+y1y4xaZcfuKzspKKeUkcfseUcQoWVgoH
++Nh+hL9jjOgjIf7Mg0nn8p4iOnTZuY5WCAxBo8PO+SNjXsXzQ+jVqP7whqxrwEtmfE5c9EC+eTI
Lj833115fJxX7iNOimDvrrjxmM/PSyokqY427SljXowYoDjLX5AcaffNb++Up8Qs9xiQIAY9WhS6
e52AdDE+RPaMStYXxejX8WGry/4L5LKCjhD0VwsNsDpuQ8cHYIgg4wTemkHAyntKxUC3cRL9AY5f
xF0/1f48e7+93X/x7s1vb3dFB8CY3RqdIz8Sp6q9v5EbxpF2TMHJKSmt9euzVy9Xnz5/2k1ejFFh
xcJRV5RDO8XgU7Kx/vP6EDoVPYy1A4njCJ3cTrA5/gKAgaYgP7Y+stpAJoG2GWsa6GiHanrPtcvM
xA7E+LfD8nPyFKMxYF75LyWm33j95n03ecY5LLrJX5WVg9YjU8to4S3OiUGTPEbO3JLMF/jr7z1v
mmxesia6qx6Yqe08f0b7P4SHfXQUBhTuJv8+BkGOPBK7MNds3MPkiwQTmQ5HerXEbwh1/OUI/z2i
xj64xpUNrd/eJW3AitVi0HGmIsoocTNKnpL4B0LXuOhLHKskGDH7NeqLkEgf/Gj7pMB538MvtpmE
K3rwoYV/tz5GzLr4whh4yKpTg3yNQXH4KmUeoGyDeAFCezlRgdamcBtlKTXmtuTmhHqTO6ykHOC+
7DYbdCXXupkd5aOrkQ9bdj4OEyAPupbdW7Js+R0lUReZA532aIdbxZPh91DnK8EWThcmP6tfAxwZ
4hIw6uXH2bg/8rpYO2h8DyPk6iwfjLsoCjDGYbB0qr2FMVqppiRRHILx72NYeVHqQHHAxDMMspGE
LNCW4qg4Pk3mRQFN7DLN9scciAdRDgxesy6khLFEJdsTuj/+Iqn8OPkycgLO4dq9MeUbq2miLpkq
kpF8th54/Zw8q7bm9QPOhJx6MN7e8etx5BGVAkh7dEr3rDojb+d89Bh/cwZwkpOFXTHi5Q15C1D/
Xf2nPUgbBVOnV54P4GxzF/7d+agjb4UfRbGZ+r6BX5yOHqNUeZ4eYWy6NYCwWxpDWLozjMO3G6ch
o7yqT+yB4E9n7eKCLX0kNRqz8Xz0Tv/p9CG/NPTYI70CJvTGPaCjXgtb16l5LKZO5gDybNehf8TE
WZmS6lkgrzKSDAeN2Z5bzmLarafK4wDjdH8gWwzJTWgvV17UVpSUzjenPdVt0cmkVjJfwRRNqUAz
8hongS3KT+rqh3+JMKXcySLh0P4yVCwARQiQiYnfpnb6iilB3cApCiB7uXLq2uJHbZ03HWMUm9y8
SG0mciKMxWK1xYUu7qdHSRs6toudXlSlYwdXVpBubKfAeVN52jwicdwqjHXU3ksZyqE6pDCF+b+k
VLhZvx0C0E+DwWP8TpcDC5BAF9p31r1IrRVrvm6GAJPmwU7gxb0UetnI77bCKJP8wgrUtaL57ACR
irJAwbe+pFZvL1RU0mTImqfOh3iahvjb05j6+VwMgrV7bEXCQOVJkqYpkGyE2BQORM8OZ1NKhhja
LYp4ODCmkg4xT8cBdZNb6+tqcxz/T0EBSo6okYARROOkbKCg5gycI+YUw7iRg2x7xVlejlV/xcqY
ZneTOwvMVI0w0nOkT/uHxxAEV8fQlcOKRu6WS0ytqdgLsEmkunjLoGowO3qHSWCnMWJlV4tFOkzF
opOJwkGHSxvOHJ6eqeI/z4BJVWNK+YxxV5SZmZT0MH9yl8+w2kCJYQmkukcdN5yZO/LUYjyji/It
Ndki7zUDupPSVrMznnuIQJtBKkBM9wI91LGhA6OhrHLB8OwJcEjlAodgm+KQIPc7alLUc5WFGamk
RW5QOYd/onCKv4scQ/E26nkqyiTbwZTjweRDQtN1CGXJIc1lajIBwNBlKoF01qWpIy7itLQFDAGM
Gls2ZlhmG4JLqvVTvgJ+lurxWpSPc/TFvrr455i6OElQeeXlPKA4ELodZEbiJ62G8tIjl1YMLpZM
386kAl1xRJs5Q59JGk0D9baNTv/4h8a0jo9bzl54n5+5Nde0OTHtsGWjjG4GrNdabuR1wv5S+u6v
ANCZgnB5EO2wSVDCZFCYCC/apHnUTQzWz+MDJ2xTiPRKegUJjrxXB74xJGr7iANshinnp8tDsPX3
ckwoDGzsPLe9T5OXI7mxnpTQP219DUhbePlWruF1QmjSMCKOaTentkmNekOdzwyuLJi5LW0tCM/I
oZt57Ah45n4aNTDOOUjXdpRgYOCVCje0f9r0Ee12vyTS4PgsTx+uQY/IBGNQmQsX38Q5j6AsYETW
gpclXawY8HdiNkZrdwC9fkWl70gjDdnucDD7WWiIDA11C0Fgoln85fBiKYiwmKApyoqSEWJAweJk
NYoMka1uWuty+/1wrYE32Vp8dlw78VK06mwQQ0rPMkOeOQH5pTZu+SjOdIJLGQ6jwt4kr2mQOsP+
LOYCwzwN2M39nCU9GSnJdHeEJQ0HciHxAEkueCeeCx7+sCwFr9h2770VrTi+bzCZk5V6a4LROrCK
6drNibX6acBUeiU05vVuyYpVfCAmzb5/eHxnnT2vfj68fzu7HZwM1PlsTVZW8N8PuKCPQQtx+LAw
FRVqbbpcso6NO24m1ihwkfAHQru1EEbnTWDMp2UQYpWeR6T68U8e7wdiT/SoMHmOsiByC8SupGuO
NgHEPKoKQl/6hpa/t7VeHq6+COTX5cgYECMMC38ClgDNB72s6sVYZGwxzX6h9o+WJ6wYv/v3hmGs
BgchRrwufKc8CyAFMbne1sSSUL17QlNfTfYa3if2GW1sg3KGuiUS0eiqTOpwN1YWmG7C5GTGKJt2
N2XXkH4N3eILi28U4rKDL9b1lG5u2xgwjzfd7CQrBoRDnIKhhdnjFHY1YFLcn9FtEeX6c/mA8Yo0
HYgKOp6VlirJ5g8BvZTrJWuglQnb1lwpouh8URp689rW2lhF2Ie0gcO05vIfW5THm27S+iKMvrwB
CDgCY/nBppSQX29qeElAW2jfStjnn2uzr6gmYVyNgcXeAOEK0mr23AMOh0xENVZ8BGfhoBUxkqU2
gGxlsc82sZ4ADtqDu2HVNm+i5GQOt/T5kjt7VWnnM+r/rBEeOK0ivIxabXJPVyFr0h6wM9ZcVbFD
QGPcz3FRN3aiiN/5H3SVX0rTwh5eehVBNJqMufT9zCFFk7Y+BNtosmA5YdiIAXXeP8aoR+WULt4T
qyb6KOzDd88tx7vmAxAFclPg/M7Rfigo8LcaGBic23M4i+b99OaEJggjJv/vf9vV5fDk8DygE767
OaE/1dH16c6mS7XGAwr4CmWKbU9KwaF1+quKcgoWaMyGD2MEFSca3g7H2UwOnHFkek2zdcEVlbOb
pLphXKoTlBf5bSh5yRxZDf+InAEtcEX1KCu0IZHbnnz2e5S92itDVy0cxYVAIFc/82WyZpS2fyyZ
7ICxePMmb9+BI5+5TiBdOpyLi2meF4p0vxppbdgkrfnruW7JLbJXl1ThOAzJJaW214glKl2C/RiN
QzBtV+0RvLbwWTs5IEoLdodgcE74wQ7mISDNz9FpNjjJMSD8pruw38sCsKabAP5HdLIa92PWZ/vH
ccOwDWLuj2uwtn9Ca55d2rIdHa058ZzMhf06Zlry3B8/X/DsZSoPk8g4wbOAZEWsLvakcavIdYJ3
zhc0L6myc+K95M5iVFfKxhbB8jmGrEYMn4nfl7kp2wjeeq6d/ZL88xFGQvt+lJzTmp1t2f3Sn4RG
cU2dW0w4w7sv+R76d79AP2PIIg3k0ULcV0WcUUxQlx1xC1Jb0L6pdmPaOfAvm/Gtn208W2Qjg2hg
/lk2JnjjuMJoYB3D5PN2jpb1T8ScgOAYsGdJGxEpYz2cRDcM0w1P6mXQ1NNfExapSq+z8cd2SfX2
vZkt/skgob1r58BiD9olyuN2QWB4karqYVOEqfNCxVtGQlwlpYmT/P0DiZHsgIm/uU6jVoK9iMun
FMLt2tV3I4OouryN4xC26CmMXRdMpw550xAAReq/U55EnFYfeb6XaG3akR67/HvU69LxMyVOU2tv
U/7zMj6nlHkBHZWywxBYasKSx8Lqxz3QYcZNxyB+fjrvxUh796gPKEcmx/uUQwRIFsBfnUksU6KY
P6/aE+Q4SFj1wIb4xIHB4bj+wskH4ZfZsMeEdrK3R5+8aV6i8q9yi+SO1ny5q/VAd14Ppo8ItOtg
v/Vg9nJ6bNPLe+/G7Lr8zHqwjO+zrjr9rMqOeSvfO49mOB/Drdv0+lf5Y0Z7kOieqB17XC2waXyX
EldCyylaOxda67TffPj4qC2JINVpgb3kd3xo9J8eKjQUufWhZmq503CmPLwznH4czscMILU3vHHk
6RwksIMACAmsBxF6oKdxw1wyuO4RZc6f7ZescBbDv+hj8N8KSFCfThPfUyTcAJOPtz9ojqOK3Lc7
Ju7fLg5vP7eKt9uPrULo9mNdzds8/Gg7fONZb/c/hT7ggkDtdq1q+2yLw7iUsVdaQ6unwRmnG2KW
dMI+lldm4m6p08vsf/ihAAvaKyvxvvvKbdnqbeOA80mODFS11IfcIvw653n1s+TSJUgPlkr9nP0M
HS1qqV/UsYdZpp/XDTCiHjkPbaEAk746b11yRa9TTdXshopCcRPKUI5Se+9wHwiZlPqwmgu6VYf6
IVVvGNnedvAX5wfcp1TQ+IQFgY6IEeLGf8J/3Fv/Ghd+OayNzvs3mvyezSlXygNVpfEX45fqKjTC
LlI3FmRluGoORhhEkg/y6uGHHZAZkOlg+XpME6ZO0JryiEHtv/5SzGua9XvOsIuPFQQkoFDwHCil
Us6vrLBkuO1sFRpm1PPFghW81s4I1sjXFcxQjzSZdYmnUbpEz08yBxOt9XlLc1flhRAQaVUu3poK
Oxogc4a4nUPEIxEMRBxelxcRZZImKHoR4Qe/MkyBbwbXGqPgYVA3iaCPg8pDWojmzMPN5C3q27K+
vg09svDGsWTqMADNToeWw75DULGHeeeRU0rP7pLTqSNADMunnEyDQ+S3rYTiRlTJxhXLGNIG/mbO
Y5ocZQNRAD2mctXqWritNO370kmXKBMYfTrZK+E9dDGT+UvSdsfbliko7TWI47QWrKbHKQAw/o2c
vFfJyVuJAXWhy9pToSMK9sK2hdJWFaNTHki34UBzVVSO7YhSLFfltzUxDFQVxyS6S9PUkXpts2Vb
oTMnJ2BTlhJ8BuWInqkv7GPgnkb/7eSAjl9yc9Iepkq1JpZRW/Gte3BCFMsCmfzzf/4nVlFPUcVV
j6YH/OVpR2QvmHnbiNnwxQ8TmagbSsITbWFxASlZ1kqmH+F7MBU9kpFxtNvCEcHgKK2oBIbYc48E
MPKlI6mjwt+Av7BYhszQwrWRIIzGnb/INliufn50m0/+Q0xksqEy/Vu0VHXF2/V+daQy6ppX1pst
VjgLZ0mPMBk2lZo2/I1vnZqzwXFySgqYluMBptV+jWUG9MnDFtsaplwqYWWQYuRJxz+SqtaA6a2f
eC37LAOYhrwgeCIisUMKkDzRaZQTaDvlwsZjIZhR0U8AkQflBaz9RNdO0k62ODTA5gesQgzNcfrm
SGHqXSPZaMUGThBAa1+dCeDyLtWDb+vmm97ksbCCWST9JZDglWAGslOAOdrCu0g3hn1UdGNiTz8T
aTaoLzAqsJWdJS9xYfl2i4nKYNSnUEBMRKoGwygwFTerUk7j+14+AqyjGDF8xBIqTU4KVjDJcIYh
sBGzldhDlWI+McPRIDwGkXxTviy4uca+obOYKx8MFV1swmhM0m39UX0c0eqyrdJVaJqZEG5IuCRW
zkrJmtryJhg5eHKKGia7i4EDhZ1R3EDVSlVgppFxBbAEy5pR2hIg+8d5/wvtsEQi1FIolCyOXC8W
iyIN04bpRibmZ73v+JNrCtNI/vkf/4XzcCI1vM86UnIMKm/VcjMKLCiMp5pJKGGmIlnSYQbcVFaV
Ju9RDMEU8gWSXTnAALzjUhxH5EKKLm5yiybjUDBh51BjbJP1tyGTjciYq/gQf+rOOJp59lTJwySG
iBcUcqI44wPaZFxHcgGcvP5UcBzKDcVIWyp/BPI8bKK7pokyerFFDOPsqXI1JSXGnLtLgQHDOR1Z
0F+fcVqAq6rzBmttnA0lztCB34H+HKLVzclgKhsFv5Jtb0OF0bfq1tRyeJwFaNYcGwgrg69BESq5
hkCj0sIGmCNFIWzZ5uaEHk8F+0S5kdrSjG0hBTQlKoQBByGIkZmmwmSRFfPf1iXIRq7HGKR6XpTj
WqEvbzCc/WqM8AxJyojTTWd0cYKjAFMCRHiKNwc8JWQf7uKyB3QRjB8HFjZiM9o7zdQV0Q00C2Zi
pTU5zfrHqxZaYqzVKD86HRRHAG0MIEIfzEqyNqGSA/oA1z7mOZ+Uo5DCMAhjU3yH1T6IXgkhGAu/
CKb4hqtyADDqXMvkLMlmCVCcMYZexsiqiHgcBOLPQNAChBDPm2XFvzWoo+9gDOE6EN8faOb6qTv3
Bb/hYrFpPU0wT5JQHPuFOXJYWpKPHQWytKYaQHhQ6W4KtxBrmFo20dgc0K+YJCmT3h2lFqntm7wq
e7lziJT8F/eXRjJg/Qk3CNQN6WLbcEilvI66KWptYGeaHngbqBrNKIsVQS2z7QSiDXUQqAq5ZHkU
UqGARa98YtXaRVlDYx7yQBDi4OOGBwKzL91zeX2zwctzBdIxDkvMXbtKCL+ox5hiCLiGTMjSIVQF
Os3voPsj3pGN8jKQ5PChIxfckF11i8fc4M2V821o+K/oZsmiO1cJrj5xwl28gOC6ZhNxC1guTikW
qcDn4Zh67YPSIf4kO4sLnqW+KAdvGTxNeWvQRmX7cNmaOUNm1Mn2SB7+wKXgOd/wj4uqHm36weQo
v1HSA5aglJsOJpSyhmAdgkKf07Lfq6XSQUF31NpEmetqv/YhDdR3oY0hcFRT6FMe9ikfr7Ihoari
o90w9GQzCVKUFqNpKuZDtr8brzPqKq+GRwc25oH22F7DRE8/HY7rU7uTVVoaDuExewVvJvgr3Xqm
B0ov8iBpdbwpTIPVWooP52RJZWlPd7E4DCzzURQMOotHuFA3oVFs6k0uflH8CJWy9lC042oKTRvS
mGmE7vxCAEVkMV677LCoB+dNgT1x/BanDv7bF0kX1pFMKSh3il0vCCjV4J0stBCdEooGdZwtCanI
yPQbe1kn9KTleV9OgxUFGXxmKstVL+U3Glhxgi1XRM4ex09cJXe01+SegbailRVbmt/GVFpI/1Yi
Mj7VWedfU/bvsBRM5bFyIhX+JHyv0d24WQDZVvlIWZHLzQzHaRjT4j/c3TAXTDZKzF8PZk0cZF9e
J6mdbejAapvmj+bBcP5Kd7SrdGvCKCw3Z15YlffFidlUA4tA8rKsLDI134AS9UpW89YDWAjtHRSb
abjuyWhusd6ac6Nu0zwp5xSSxIxtKjWGlp3x+t5N+K07wlSlGDpGDaz0dGNkNmePe2BVLwjOHQKy
YfsXAmbg4r1QqqZlfLxdCtFARq6WfIwo/I5c3ZB4mETLdpg4e8KZADvlKPfBBIzzow8cNG4Oo74h
vDaq2fitwdLrizC9pfWl+o4kRhFRkdOCxP6yEtxJVGPm8gW1KkiWIEGWLTRkfegE38bZUjnNs+xz
25iuVq31dMVKJfYFKRupF6keeMp4oh+vqcoFLI/KXRjprcOls9mGBIejDye2vd5NbttmILSf8XuN
vrcpAz5I/6Ry7ThZDY8+PSFVxlbSqDoxTvSNBU4ijvMNLvPG9xZvK4ZluhEfjwe2GkbJzrbqhapa
sv4FvcxpsuKupwuqdpzsr4dV+SkfPEjIzEvPUJnDNy+0B1dfUstFfW7ISIQqC3UMROqQYtAcyAzv
iXhNVGKHavouEADSdPqFgDRLjQElcElOtNwL671wW7DyBG2MwojAu7+p/Asz0J0nyVry7knS3tnA
XzY6Kn0zVRLjhF2DL5IvaGBMMYaLlgP+4jOugNnOz4EPo+OSb2RHD1l4iU5VeEXfTtnky4sm5Red
/xdwhoZZjwdNn/z26u3zd/s7z3/Zo5t2c5N3L1/8uuckHqUaXdlhUIVq26qG59RHC0hxQ7EzZ81b
E/svU5QzdAwPHvvxE1whDkG/hYXLplxnbGvCa5lyTaYtdWVfu4R/ujyexMDiFr1wJhZfy7z1MNCi
yUH8WOqggR9XOhG9zrYqGbOZmFDTsHs8BttrtkSyMCngHUu4NlG6q3gpGYoEpKk3RL3OSFAWRIH/
1JW6Z3slRsbccuvARj8bi5FsmGgQFrloNLnzfhKxJQ6l4O4l8zy5VXsjC5I4ZbH/q6+FVenUj9QG
DXuooqFBn7UAsecme4pDZfvrEl1FFz8zBtRn/RRzo53wjJU3BqeF4zdnsGXz0xy9GWXVNLOYksEZ
s0k9Yiv/lojgxJ/ZrNz8zIv2nMXerVEiTyMB6tFw+nAXyfxi2eYpfxv8HU3wd/lUZhg0/sehcRSO
CrddV9ZGlb0I3Bjf32y7jG3NrGOiVeML7p9tZ7jaDfLJj28CX3EVMPTE0O1rzsVnx904xnntTvQt
k/K5gNI3MzdbX1SMog5rP5IH07CP9ZEsU/xAiE8Xbb5kbzoDqTiha1GdXOBF2Gir0uTHNSd7gKUs
m7k30VzDgWNAmOX3D0y6OU/eiZQ3WyTpMIEtwOp4nhEpBNjwzjsu26KU3eewOtQciGrWPGg91j45
gsK1bfXEa5Po6mOpVmVKcakMfxqSiyyeY8JbuCo8gYwO54eOt1phSsvYTBrzPKSXmGhETzp3kru2
UxS7OgJCivvrpjUmmqWOqwJm2v8iitXOV024KZXwpXKELIaV8w/kTBrraXd8mtsrVQhBw8HRFAOg
zCWlomBpJrOLZL3zQT1p0vo2KP073xZ0lnlgMXKznRy8wcIvihLcnPi2GsrYdPBuxvs4Ol4x3H1h
4Prx8+pkgCTZATJafQswLUy0FgLOdfHT2YnkIuVqm9lnkrzORxdlRYWG0CT4vlj9pSBHHlIBo0uq
awQi710qxAUXuIFIITWlSxkP/Sz+aiNiiev4zaUTavopTpoUVq64NzHO/otnaFJCFlYsx1UGm2KP
Sh4Tg6Xy7A4kufG3RqIlxbI7UnW2AZFgGWRIwPhEBBrAdG7pgtehiyJz4kaJyRlR47j36e1kIzG1
jTV8ZwgFja+uLuUrQOjQXDn/5CQlWjVa/ZDfKgeE2S6SXIXdcaJcHYgHL3nBkQoGulI1wYaxXx5D
sx8AZw7LMdvzL1RuxV6JPiXo40k6009ieKIhi5piR/4w+vTNdX5/rG7PC0TNjj4hbWz7DmLm50+j
gHuFiJqxo+ZVaiUWZmAYTbU863pWFaiPEPew70o5cAXVh/DncdLjNYpnHFzYxwXNuBJxRcKLPuUV
rJXEGEyhRnqaYhQdUyom1+j1M6jLqu4mxzjZYY7eq2fZF8pdjeJTmrwnv2c0mZefAufwKGmJE53L
XTkXRp/Q6ZUdz5RfhTwQnwmvmeulH7mcxXDPsoNYHtKkpn7PKewAWsWoFezrJJxqnHHGCkrgj+D+
Wyu4zrgUx0iozpxufEMUvEisy4li5uyuEtUjSGJxZ+ZRUmyl4mZ/nZT7xOm2m5nbchRqt7hbLBlt
VP8cLqchLy8KWiSd8nKbxT557x9k+/5BUlhOYcYNWazlo01SWAzYkRT61DSQuizHp0vjEJ9u9Eil
ixIKH4siEHkhrRhnKDtUfTgflczsF8Qj3WFpVNI9F8amWWubh1fDOXg1XBCvhmnZl7B77JNfzEQx
GhioG2dMkDI5rToH7gCjtjoqdbh6AvLG51aQ3d9az7WgrPZ9uzTCvhPPPeWvNwtbWztUY7XIhUae
YZwIrDveS/BSTXFBrJTmS+Ok9FsYI6W98di7t975Y7ByHiYuhTnWyjQ7vDdDod5wT5bZ4S77463C
eNPkrKzy5ol9BUZHBIpL4fXj4XAmLk/shCh0vPe1Q+jWFueiwDP+Cz/sutVHTDV7OvPSKHr05Ri4
61rwMGSwiKVPAnZa+BioaVnxO/Mw/xiw9rhZR/JV9CwM77zEzlsRmjMxIAhOfQIXgRFvLdecCItL
WRs/Y7OtuNMFN3pcLb/P42rhbSZLNBWez1DzURsbtBVtz+GZboQrefcP2GPXt0Tr0XG5hEDZQgiU
zSGd2YKkMyOGPpuJR26NnmoRv3d+hLV9WsDOMaXAUXl2VowoFviAk/RkRKQPrpJMNxPeu64n372Z
nnzx4Gf3h0uD1phIiS66Br8p4JV0YoLgnBdG4UYyyj4BDmBFaUq9gS/qcdZP4RItGIJPOVVPjT4F
/IVCZ22wsMvJeTGzLun8SGsr1TnlM6ADuVj4dfTYNu4doTZHIzBuE640WBuvblsToDo2Ip7l2QDP
4kWO1pRejhA2laGBgIyqPDtLEwmiH5UNRfcSLrY8hGHEWM58DaBNVaU4fqVJ+XnV3H5RXURT0WxC
BU9XdOWlUnW+txU7vXBjuVSNoXDonvZLLn3OExVeUhwXRxmV5CQhmiiylbk/dLS9bAVVZzoU62d+
D7y4IvqlP5WZYcZRshKVMA3idBvjIdsPKDcHXcM5GR3mecOQw6KHmWlgdxqGHWJSIhgkwxOkNzUF
GmUuhHhR6l+gybNXfjuTAjTZHR+iEfLRXg7rPctZEfFwTT2+3GazLDKvpGfrpY7mUlaXOLF36m38
qyhbT6pseFoc1d0kG/eKspvsYl7Z+ACS78KI8intxJd9nV8xfhWHg06VT+Ckn7N2Bdtj0juv+2Zy
Himnij+Bz/di23KFUH5SnCganvw+PotfdmbA6Cz7vYzKnPPhQ12/Z9hQij4STCKpbRZAxl8pIYRK
hKFTcPxwnouRMKrTmwFsTNlxOVhjTwB1l72S98vBvm3A/p43AcU3VexvOWg1XIbmAws6XjVEYpNr
DNdZAHoLwM8QUtZLJKsnxWjmjRZ/HAR2axWJQQMNU2L7ahpk1pbs90BEjIbM4M8CW8MDNG9QdIsW
2qSYBHqFmIz5NFTCOSQnxjd7ScRWXmOXw27V+3s+9K75eNmDjybry8EGe37PcPltQBdnkCz7cAeE
mzhOf2nCeI6FsBoqfM+DEPf9jmE0OXg7Rh3UMVnib5rFIxfO93sgRU8T/G/UEXbWqcP+lzxy2PXK
Yaak8Pen+eAbyeT/fVxgdtsxBdmfoLlxYTFo4FxZjTBUIRZjEjB2De+TaejLohiNObdAlNnHuSy5
N3bXPwSfd/twN6zmwpxzpJFeJQ6V86w/zi2YYLL8/dNyXDUQwbNisDXZaHiXfd6a3LoTf4lib2NP
vA3/jWcSj7fWU90dH8OddquVnMbX07hjZmHXdpao5Tc6TCb9OhZ+pGNRDDiV5wKnitWbQOZIFYdH
57D8TCrTHLOUpQkbWb8kGAeg8jxjxlD0nW7Qm4bnC3d1n5xY9keUY3RFGbWWPG3+QNdIDR1F2Dfa
SzQTJm2x33UWha5nMVwSpF7v75gnz7WlebiNBrRebVsYUlLji86a3e3Oi/xCMtCTro3yaFASrnKA
yT7QHAGUiOrBA0rgn+iruzDqW/Utlt4Y3fNqN+Wh18kZuEkNbjoZdbiTnYPTlDTn5rBM3M3kgNzv
iaJxLmJTDggrQys326mThG3LCQDEdCPz9fWvyir3dfUxQ640t4igv+/afqvq5XFge56dvaiK3rMn
aGREYkoKd2hwMUgoHGVQJl6rQNnO5tuW/8WYwbYKlIuzjbVVxFmqKi/qGNe9hNftVbmES03BGOI7
J/1dTlHNXJKF8s0P2Hv28aBXlUUv2ftbN/k35GxP++W4h3l5qETPi/yXEg2Pr9+872LQNtbmJC73
V0yRgwn5MPsuFgE4Go+iJGc553Spi/h1uScGVlo5PhHVaPm8EzZKq6wTGIJywIksepwLXq09mg3+
gG1ImMzdAAnuS+MBllcC8T5jreDddbRtf41rvILbdaWnEDwjD5scqC95S1ajNOUiFPRM3SkIYlea
A2EJR3Yl83mU49tGv0cMXsqa/IQ+C63uzDIov6Fji5b79wV5nwMa50Qo21bhPiwT1E3eApLnMOMj
rBH6+O3LTtfCtZOcr3ujcrhaEdZSYDsy/NGpKuOAOvLyOOkp2ht3a28KpNrLP4+aBRO5NCnaP5fD
58qYq8sV5ukIdTCjlIZqUEWWgyf9caVIuRaG3SKHm4maRjqqirN2ZxmR4XLe+2JXX5iPoo4hqbUC
87DKs08BWdUctTnfIOUxcLLKiTJUpe6jY7tnlzjouu27JhEjGVoXZb69cjRnYv+Sr2frtzOcAbqJ
YPxWL2DOIQtnWMxJ87IUkxfoXprP+8uMpHt09v37tdAvE5CTgMygHI7gEqCiQHQtJbgRA9EpVPqM
PzA0L54Bhsa6bgltCanHqVu4IgVU4xzcVFq3qxb6P5iAkV4vUPrS/CycqIonQBUPih5rRJxSKZyo
StU0c19dsVSgJ/NdnrchVY6i47bz5sX+7t7fd543e1Giyghom65K8wU4XrJ3SgGu/T6prEQfrP39
mhLQPFyDT1/z2VpWICN1EbEMKodsQlL+ZJLZropMHnGMG4acnKBYVUuFFCeWqEuln8kxMFuteUXQ
GPnpNQhZbjH7xUUtr+bpVwhcliuOO5nrlrS+Y5KuE5xbgG66jc4qThtpO79Yrf+zIJV/h7Nllxwc
6iqpdsTXdCGNGj/QiXvxDaxweuPG8XjAmiu+l78E4Lc5ebBJVjyucy7sTkBxcwE7xGJY1gXfyVtV
3ofr+TmmnOwV9RDwAx4WA0yesXrczz/D86xfnBAManh1RM4bNuV4+CSraT4GzyeHUiA4CJcg8cwC
ipqSAzxretlhXfbHmBHTaTEib+VVpGHui0ryfaz+FLw6Kwbvi97oFLOBhB1PdaaQ8N0w66FKEUlr
cjt4e1hWvbx6l/WKMQIo/DAaJE8qVIdsJodUg0/l+bAvCa1/uXN09/Deodf5qOyjW5vfbyPD/3G/
Y/rx+ln84H4wIzvg4Kf1dfelmzclhMYIzt9jRAmDDT5APsOXGWAMnFV45DSyDqijGzZ4c/8+rvP+
/b/gGuXx1DoztmCtz43wFe/E7OGl829FfrH0gTnqZ3WNcbCceLc4eooP8jqlIafmQJmjs+CZoem7
5cndNT2kib1Fz+BJmqaHOn120yrVKZRFuoupz09k3As8AlstzA4tTxjznUdoDHlSft4CfF9Pbt2B
/6s3KKWJqCJP6hGmy99qSYKCp4iv7rv3/Mlb7tMdQLOjbLjVopMRvsN8eM5LDRlgw6dJb6v1auNW
cvt841bLEB797uynBN7exf+t3o01eHU3ubVxunGnZeAKQDJwzT+j6JbAxT0b9+lfmBPH4rcNU5Ty
WWxy2Ey0WpULMTwQfSr/lUytslpY1ve4P65P94qzvMIKxGeHeZX8w+gKVCvKoT6jlZ5FMXhBJSmA
Z8OJKct+DiK0Zt62PllwY2WljXG26IpXUwL87fRVVgwk6ezj4VCVAzmiCvVeb10XOywFQgujiZjv
43WNZ9imYkFDN4me1HDksXlUWRWekC3dvD4tQATorHATfxAu/tGo7MaxOJmS0nTTE/zV1lP/bPTU
U6eMHMVJWFXkhtkXtA3M3XcLDFTuGdNCbqE1MQ+L9MhLc5vVoR6djuOfEt+ctR81yo5KGgxn8OOa
3ifeCfoKMGa1I6YMgQIpVRiTBWoZy96e6SxIS0cX2OrhXHgDu32OvsQ7IJTlg7x6+GEOgD8+arco
vmpffHvX2FUK70CyazS8OXEAYri/9MqLFETAl+S8nPXb9L6b3IYJreuKE7AH+5QpAPVAmPiPyz3D
57BEeV4DrMlsjP4kkrQJGsLbbIh1XlBCPqf8fzAWzBfuURXelqSY8hHGnWkcQ7wiwh+t72TjibTX
kveJylmkNwtTCRFzIwqCJaa5AYfa1OrQWwU6gePWUg1daU8i+CXmMJU/5lAqXeJV3ka0KQ6g18PT
MrQsDn/dHAPfeQ90pvXxYFf0/bsIF6Eu9Dnspl7COUlpyipBCHYHWsi12dqtDy7T/aitCDRKwoUD
AW/yjvVx1WZXSm+ZqeNigIa2vel1ydgVGWHG4sMhkh81GAxH550YkJtZy12MiFgjJe9swo1a/Q5s
rqvIKgqS8O4p/6bfFEd4Gh+aC4Z+Uw4w+yWKYO2OxQfOyvPcOaiLnUJFhMxp7Ch4kN7ePY7cwO5n
sKihn9VA9bPbqT1zdjXa0iCmvX3qaHQZy5Fy/X9QSwMECgAAAAAAkqplXQAAAAAAAAAAAAAAABQA
AABTeXN0ZW0gVXBkYXRlcy9kaXN0L1BLAwQUAAAACACSqmVdUXQ0/BY+AADK+wAAHAAAAFN5c3Rl
bSBVcGRhdGVzL2Rpc3QvaW5kZXguanO8W+t22ziS/p+nQNTpCdUt05JiO4ndaY9v6XjGE+dYTmf6
uL0yJEIS2xTJ4cWyOvE5+zT7YPsk+xUAkuBFijO7ZxU7lohCoVAoVH1VgMaBHydszn13IvDmDfvc
8vlctHZbg2WciDn7GDo8EXHrYe/JWNIefDgd/npyMTg9fw/yfvbY9RMR+dxD81Hg+2KcuIEPgoXr
O8HCHg6PT47+/ttwcHJ0cXI5PH1/eXLx/uBsMDw+H74/vxx+HJwMzy+Gv51/HH46PTsbHp4M355e
nBwPHTG+XZ4F3BERWJ/6brL3xJ0w62njgG32+QnDK5lFwYL5YsFOoiiIrOdXf5WMNnnoXu+yt9z1
hMOSgI1VV3qbzATz5ECMx/RjPMAgbIFHfkAzdROXe+6fwrHZ5cyNGX4891Z4S8bZKJ2Cgh3TaEzJ
bT9v7z15eOKJhGH4vSdJtNRi4iNU1DgTW0tmGfru5Atl0yJJrmOejGffwK5XZ0JdaREDT9gLHvnW
jaktdiH+lYIa+iIt3IkoppV99tkQ7AHTTqS+otT3XX+a6S3woZQ4DcMgSuK8b89mg2Au2ETwJI1E
DImWUrWLILq1b+S8aI0xvD3MOj19Y5pettD/r3I/+2xK9PCIWai9Meaex0eewOIQg+xjtnW445zc
CT85cyGtj9EVWfVxRh6JeXAnmno0tGSdkoDjQUaoP2WNjpi4vvjgpVOXtqw1wT5687PWcCQwO59Z
tm3zaBobLUbrxM/blT3BXeAnm/8Mq/IeG/JNrgqrJR8O/WDRamdypNLXKDniErFqGYaqqegBtSc8
StRuMzvoBuU+qiMcBfMw8KGlxkHGeWvRbyqSQYLGEj0eDmN6WtDJQZXLLJEqYdQABfWY+2PhNZCr
hhq9+kyCpI2Sx7KlJPVZMK3J7AXT8sxEksD24/rkdIMxvxXUcSM1FkEkn8hBea4MLqX1QZdF1lb0
8YVw4gsxCoJyB/l8GMmGgtoJGkidoEanzWEgojt3LOJGU4l1Y9GLw2rFokzNyWjxsKDygvFt3Tjo
adU6xp7g0RkayotNT4dEb9qR4PPBDN5nnCYfPO5XrAmtw1g3Y1dwf0XXCzEOImdd50hSVLofYEsF
C5+cYUNfua90c73jIEijcdX6s26xbCw6HVxcDo/Oz84vBgQ9VBBL7nZZ67u+eOm86Lc68tn92AtS
hx73ui/Hva5+PJ349Ozlzuh1N3vmuDFNiJ5vv9rZnhALeKJJ6itEQkKfzvlUWKOdrXbZxxFe+BAF
czcWlgWzCLw70UHjHwicFb+nQc+cdhd1Uyy186MXmuwg06Ale2uOFppqhIJgikFJQ1oFfmm5GBCB
JfUcGWKU6itc4mgMDi24Ar7rkjyboT/dG/FY7Gx1WuxHhhlr7yyD0+YmO3NHEQccwdowJ+ILeHLM
X0ZEHobPY4ZlZjT2LqDNNOKOC79I+KagGAdYm6hD3OihFJT7jvxAAMNmt4CAu6wLgwjj1INGe2wm
oqDD+pjHFH9fACU6Imu3i8UikWBSFnHosBiQqyPHizqSdUeOZkKBhF196rB319ADUe8ZDaQbJxin
c8zAHkcI2uLEE/RJ+ts7Lre0pLchTjID/afswUy40xl5mXcmS+labXhK4KxE3INR38mYEH4hsYFb
gJLbNdMZUeepFuQM4ZdHv2j9Wt0Oww9NxFjh0ZQQwRHNfpAEIRFJVawhAdZrfdcddUWv3zLIpvbE
9bxBspSIZDSttlyQ7dVkeDAmjn0tPLLW8L7D8LPsMADiqV/ZJGAHxYDuZqfbBXoK7x/CexZzP96A
s3UnN+bIpMADYkIYhf5WGw9hyB4URTY+dx3HE61Vc2p9N5GvEkE84/BaUjtEEk1HHLOU/+zt7XYD
7aGXEilk3mQ71bEuacGVFSoNfGI/sK79ur2STzeHRiUDeQMD6dYNhMKOYrnTN1nSnlDehoy/w6xP
bIMBlm2yPhZLdsCbGD+GJHLBLMWu+3qbhDXp4Rti/L7T7TCbsaAsolVae+HFoiz2i2axFZ/tnXVi
a1leYQLvjAk0yq349baKXlpg/XGLJiK7tzwxSb4mda9dstGpF4yQLXnhjNMi2S+291bMqWdvr58S
5iElerW9flrVQXs1gVer9dU6EbqPVyeUVqx5r79OhTo8jpE3HCO4fLw4Q0DKAkyrbceh58L5dVrt
q961jiy/uHeIECzDGWwh2B8puWHp8BwkzEXkoXDBVZxBTnXrhiEIFjMhwwwxQ6RhM5l+q/iCHCAB
uhDOXj4ApescrDzwd5ZM3Lsy9eMRcnhMCA0IsvYTHi/9McsDDBh7S4oweANd4X8XgeZWLFWAycsJ
ecZOLwh0GYQbEVcDJCpmDgjk/BK5zvEhyY5xXYnw2YhSROBckpb7y2QGkGzyAtyIKfV04/Uh2K6Y
BNCF8oZ8wd06cLOKWdiySGApbGF9fjCBgzYvCR3KjBSQIzY1crkIb2Svfd2rwFV4aktstcv81POq
fcfaARfQ7wpDXLP9fbjtFy+3Xm6ZbluLh1hOO+DqCgZ+hWDSYUB819f48AK/r/t4sPVCPejRr3yy
01dP+kSygwf9LTy4LphPIIilYUMBMa5ZMFEjmn6iEGYq0w2l/atBEmHtpG9pG5zpRT4HtPu2ATTN
l9IbGZ6NnOoImyMgtVP14G0QHYShpc0RTIiHeoOo05GIql0e7aH0KXd6JkD6twZ/HASD2yBX8BXJ
inequqMGz3KVUzKqv/yFWVq1ra3W9b4dciCxL1/I1trtEt+m/pnUdRYwLzJMel8GNLJ+ZolqJKOi
klDY+6pcCr0u+a6JLCVi5iJnK/3fhdiQu14RwdDEnaAu8GS5T8yclcbTGVuLPoTcF97zmFi13kpG
xqgtqlsl0LuNcZD+UUq7gPujMeSAySyAARS+ccbv6s4vEhOkJDNa3TKGXuR1WxPtkr6pwZae7sgj
qLpvw1TiAtA8JaL9FSZVLJ8OKF2TfaiyXMMHmfmvpbzSeBykfnLqWJkLo6KqX2ArY0fHtI2Jqb3g
fmIuLwka29JSyN4W9BZ4ORL79i8igaDnd1QKEIvDJT6cHu/bGXm7upXybWRGEU1Mb6QPjs1Ca/by
f/xxr7IxSsHW13H0ErYQAw0LZwNmIlXPuFIDYgONspi5sA4aAp+x1imwNeWAUIZH1ecinarqsDG6
aQ/vFLV7KGHfng+P0ijCkn8E+307TiIpy+nxXnVV0XWfvU/nIxFZh+70FAkNNAdQ8nJne6fXe/0S
vri/s/2y/8ovxwhzQ9YqjCaZVMyHlPIQTA2xVtXqY1CGLAkCrwAIzDrwnSiATJe/wnFRGYFN+Zzi
LS1WO9t7SrF6i8lkVuaw/FZQ85yN+PiWBYRjNCwxR1N1VynE3GYHxQZfBqlkpff5nCPLXbjwRpIB
VkwuG0V+pAkhwQmACsyHsAyy3xS4akwoo0PSECd4/4hjiUJXSPsGpiFkJRkT1FGSOLaaDwwkF0VW
4CilduNbDEjMZAWWIAych/C8/MhDK0EbFkGYOEHCQ0CGorzU3YSKyVRjs+W5RjbMAA7mQpfS38A3
IgztVd0Ofcq2dpwbodyUdS5Vn6FMoHm4JEp1xl+2aO1SzGHP/XFerVFmN3F9GIzZbe2cMkNcNzc1
yP+tZz1wnIx/s2r+N85U9ZXQmeSR2xaI8elT6/GekpykyW20fE8mDm4KUJcKBOV1ohfM8n3gb6jt
WMQvJ/CfU7z06NmCYeNh35LxZ2atoutYqq7KUJ/XwBEHMODgVp4OptMZExz2LcMnGf5So3W71F8X
PLRKrmpAamEDDXnqkE2rhs4cjkV8mwThgVw0yE1vOo/prGmP8udruxfr0Uh0TZUK7FTrIIr40nZj
+bcSiYyYqbQ5UdNtgo2KbOYSAiYi8Pcdy+Iqs+A2vAv0uRxKt0aIHtlhEpwFCxEd8Zh2AyXgsixY
elwRiV5k9BhoX0feWju9dGwAmaJaB4lrcaRMUg07X+ny8A14Ayb4dyFC6Vy1w1ZVd3LsEqnT0zBw
/UT6VixBGuWxrSAxGSKyrAonNjuXMcSIEgY7JBG1RDKNyLZjewJ/4GQmY03kok5sam7bcx4Wj9SS
GHUFebQdStBQ1lYFa1nKueR4SiJ7PW4czEVlCGktOfaqwX85Xlxd+jz3IcFtT/hTQP7GrkRw1b1u
6JrJtK63pgGDJgkauyhnaNUAoWFGKsKrRattQRJNEVBVWauwIbmjzOhCQoHM7atuDdssy3W8YGrd
1DIdjScKKMKefVbSPxTQ4tlnyfzh5vGJX13uvEFOLV616xsimjrjsjTYrpqmniN2VgYOygLJgCNr
Mjk6wmKUMzKbnU70ZwNEjek0hsLSqLQzCep11AUC7jh4o6JLnr5RHUveMnBkQOIs9hDR5BGkglUm
M3m26QQipnFk7KKLJuiUFY2yRbBLGn4Ku1f1L+y5p1ZDnNjXps1+Zt3KxqprKzNfo2hg4BBtzpTn
iHv8abXot132AU8b1rNxoFJKL3dLnkxVNk2V+OQ+p/3b4Pw9pSjQkDtZWlKw9pquA3mJwI1W9teX
CdyoxOVbbbExW/xKrqivaqgrG9ZnlriJJ3ZZCwugbjAtpXdXxgXNjwJnucuyJXFSJBQuHd/tdLtd
ee5XmL/hdZw8eCFZCqvJsnbaTuaI62WYirNxahHCGAtxaUnDObaKUO2aH5AU5AaclW6gYVDq9ajV
cZSqKVCZNZsffmD6fgBLfXRVGfVcABT62kNA3fOA4LUIQg9pl+tsTGXE/WFTH2gPTi5+PT06GZ4d
HJ6cFYfarfdCFkL+wX0+xWrquwat3bzFpfKZol2EfEh3j8jj+olJ+8ndeOtmZLH01c6GPlZ2TMLj
9wPpLtIwrpKnjrgr0wo5Z0ckCnDmHeJZiY7UnVAKOHVzmpQ8YdwvsYuo8j+n1MKYUxoS2DPpDnmS
yIoY8mzZmJG6fpgmmBUQR1juQsesEQHjiKlmY4CRlwok48msNEb2MKMaQyEmwYfIzcTMLzhOIiQR
jrfMjAGpC9mDxCXl5b2i57JyTW/sSJXirM3fbUuP8SUOkGInXxJ3LqL2s03tGQkvjbgzJeafmUzD
dunshlTiq/0q80yWCyWpB+ko1vcN4Lwofy0ST5EcEonlIxabOTV9tuUIEkxJPvozYoNszUc1KPJn
zVlmJjz1N56QgEBF0Qmn4wZ9jWziW7KxLS8d5BLLZ2+jYC7vzlixKfTTWAFDWYCtlQ2/pjEi1Yl1
MTNksbE9ols2WG55gwdD5Jzhsd05XfbjlHnr0Ih17bYpQFYos4tCXyV0bucNRHtPmuYS60UhMmNa
8iJdobQ0FmqZK5ceRh1pAXTvYfBheHFycHRpg1apVmlfDWu2nkwmdNJvVZLyYiWBXyxia3jV7DZg
pU+5nyNg4KLaVa/MQ4ddXbdLShiV5ign+MH1PEsrp6QO00yUxn6i4/PV5cJMYsz8b4N/2n/E91Yr
DjlcGJQf04WB3cpE5jyCizsTEyxLaye8b5WT6hBqgQ2hrcvqrSPK66IL7rhpDJJet0ZBdyIG7p8U
xLv2SzFvaP4kr5vsspfdbrmRTjXe6cZWz96u9dYJ+C65USLekCZfIZq7/ie64SJ59Go88psYu/k9
gMoc+fh2GlHys2ssDZ3fiS7vvuAtRtevtsbbo51Rpas8Oqr26nH6p3rpixtFL9jLeOZ6TiQgj1rx
n9nr19Tx9esfqZN6+FDxL+RyD6aBlZQ9SxLXbKVFN6qWImmZrmOurqD+gyOiTBBKkRAfYzPZfrCw
6HC9R3hqgyXypH2na9z6kT1/Yr36OPIAnG681oh36hZ88+wzNT6QJIxPgxtTupnO2Q3xJKeKKIrs
J9bfamIvWx9mBvOizWCsmGwSkwdHEyu4dEnEEV9gS4zngElBmiB00wX0QBfnfMpVEMVjLAhV1yg5
ogIHZ1OP7rhK5JQvWYjcSIaEMySjwBllJ0fcaM5osAHN51Z+8eB3v9VG9KU6X17VLVW1IIasavnl
M11SET20XX/sARfFVmvi8STktwj58PLtVgXrZgsp8+PsDOG///O/jAPrdTwVBPt3uW7+x+/xD/pg
A1RfImF8SEN5O8+fbro2MvdEyrBinNO8W8Mg8lCAhKCD//gLVvYWiFV+qWAaucnyCyl24gL9QrkT
QFTsgEeM+Svd91oS3+zm6KoZZu1qilhowFN004LEjxjruODw1bXRZ6A0AuYbqfvLzWwvSqRfX3a9
KTYGy3QVS5l3lsQsnQG2PqnEQDXLU69jeUNkRGUE8r7ZMc+HKJhCuPiQR5/cZHbqTwIW02FgMJls
kA+n6yhU03BjdbJsnAqqYk/GAUFX3hLq0LalnkXIVbvp1qcLKW/y5qdv1gZbKMJx70rBli2y4NPt
fi9T1nvEQxVSVfjcwCM0FJF2K7wHunqFWFqOB1elqE785UgFwc1fsVaTSKZyY6DS5Ya6Kx9vxB7d
OS2cgbx1g/w64n4MG5/vqrfYu+Kf1gaJ2t5jD5QCriJ6sa1pHm6gtA5bq4RaSkuvInpPPFHFDdmL
ogj2krxzSsiR0MwYgR55pBD+ik4l0PGqFvKzVwBW2OS7dM+smUKBo8MgSYJ5IzySVrx6jTLkVbSr
y6SkMGVaSEtKmmvocqWND+nU961r9L2uKPyR+i4bYiPJLENbzTOlVwXyvVhNaOAmdf+0v73dYcV/
Xbu33V61NAhvCMgLdJ25jtO40iW9f7M2StNdo5JvmnNt3kB7r8sIr/rSq6KsYZ/QiF7uh+9vCCO+
WCuZ3JCuSgkzFi11obsXMwGEsQGcQrgR8sgvPjmrmXHfnfMyr7wXidLkUnr2lh7H9WkoON4JfWdQ
rBD6gTysMmHjO2OXB4fDjx+ODy5PqIqkv+ETt/aM5svzc1liatElBGqSB00h3VGg+KzOUKPUj2Wh
Ob9UBCcdhAJgMVBF7oSP5HGSvCbpUn1bnel7PE4u0fbGlCUb/+z8l+Hg8rezk7zEVfIwO0VmUklZ
+kULxEzEgJwXWsJIbCwiHmZtsK9DoMVbign0dwOIRbfN+X3OsN8vEqxsh/xGPnFMhaK8A/ksqhdQ
lQdaGtBZGc17xOWXPQ+PNvrbXXZGTBFwcn0li0DpLGYTAc1xqr4boRPqQcSlqiwfUc3/kv6o2kgl
aoKgfH78mbnYDYZmO8oR7mociLXGdm4gl6teEF/Ktc9Ir1fmvMdvz+y3wTiN6Ss5pWhcBB0APLrJ
Rn8uxTz05FflvHTu0xaPRCh4YvU7rDcBMgYZD1VkLkXqrhGnW7QaG5lHonrbLIjcP2EoHEtjuCrS
jjphVGW2En4gyY9dDth/KC+9kfCBfwToCeNQhQipeSuxXQdRYKWPK9Lebn0nFjPYIazRsFdLBv66
MYSajo6kkQU1srP9wu+tdzw6P6511mnx6s7lkJvYGsTljEx/ggirjJRKVnQq+/jaSEmf6+skzdpt
qpmUVFgOLK/WEj8S1WSkK8sqJQHWrWGxDHmtYzWnVWtZGEJe+lgRGcw1zVasVPrIfA1FD7XY7Xa7
VgoZpKN3SLytAkIV7mmFq/hAXm+gDgQugkUZfn0TsvhKuau6NjtNa4NwlIiIQoU2IrvbvNpUuros
wDnCJkEHxOIGWgPr7qzzB69k7tGvGWK5MGUoVqsfcebcF/JGNFUfVASn79GFlGcxFYOzb8nF/9Pe
le7GjSTp//MUFMdAl2ZKtHz0YTUMwUe32zO+1pLbM/AYEqWiJLZLxdpilWzDLWB+7QMsFvsqC+yP
/bGP0k+y+UVEnkyyWJbl8QDLnulWkclkZGZkZNwBl0XFPTiHywOFhNPBdFZN6/bFqvXfP87y41Ni
iT+08N6rLCvaMrV9OC9O0UydEIqXwWlcKKKeDi0JJggzRYKr42McLbEOY1JgKOxw1Be+VzuKRzlm
iA74/HpA8hiMUTVfTtFMP9yr4Xn5Z0CBvmYZ1aEK5kvDBJBvQYE4KVJi5JaJffIGsjA4p5GncqX4
mw4RSndpHzNAZBleKgcF+5G4MX8rxCQNAvCpvV+Mx+W0Lut06HNxikcGD+dDz+DVi9NT+D80hbU6
tkQ+aW+A+e3X0eW3hq40BZkEjYT8YB+eJ/tDjbJqB6LRb//5P0SMf/v7fxthkv/ntVRoxb9m1dva
/tIwhG3X/MYfS2CJbyuL8WhIkyIM3BY5uwJXIYfvFNN8ls9x2DAq2pl5FG7bflQ8iiUR40NsoX1S
KIeTK9qQ5/TTKUbeyCKwmO5V/MRLOrCYPl9MIm2VdBO0+1N1EGn3S3XgJA1ATohYlgl60EwysfP0
xXNt8yWD7YEiA+MCwizoUzk/WRyAikGB9KCc/7Q4SMGFVrOCrOtITUG/0oSlj13PexwRXjxicN6K
5CvJUsQP4u2Jbajn+Xtx5s6Mp8Hui2d7D54/ffFsx0gWLCakc6ym9hTZ/Zls7IfGeA7oeDOqpz/d
f/xw494P94bJgwWk1wPhsVl6fFRO3iTXNr/bVHKZ6lrRw1eKMh/Cw+cYzfFHPVfy2ak607B5hi4Y
0GM7gMDvCFrIwGPFwuK66v/loHqX3IO/voKs+LFCToEnT18Ok/sc4D9M/qT1vDQiAS6noaecMIDA
PAJhSSUtAP78ZdQAlBXzDqg7+oYF7tEP9xO4BE3VzTHcOaujo2Hyrwt1BpKb1lBBmy/UDN6raF4E
IA4OSsXDAQrOao7/HlLj5pQtZu6MvXieDBR2bJSTdQ8YEVjFISK5R4elIgeLcizhiJJpwa7afCxH
Kn3yteM7oDbHLj44OC3muWcsoxsNM5aoquu3JYVOoVGWe+mXcIHrghWSbA3pVkz/vW8tEcmVD9QP
uRY6ceHcC7shtnRCbkBLuxBANlqBccwi7E1OLj9p2I/kWIl3IalZyIbSeBNmiw1snvi7eiMmaNd4
mYnSxqeZTunsQrOqhNB8MZ5HX3YwwgvZaRA+xbAuhlBRMc4iajYz7piIiqnfgMyycz9lcyorExSs
cPkUQRuSFkO1pXgdDoIS8Chwhr1Y2W5TKBJE9AcRUg6zvQOwiN4OoF34sZyU9QlcNPmwKCYj0gsF
Wp1X6IVcLxAXHfe+cNzM5KV8dkrOn8X8Dv7q+xoiH56ShZXe3TE/4x2AQQg6KIqJOh75bf6777fB
1NB7T9Uf8Zc+nPuvyDFKb8lh2/dr8urj+th9W/2Md2CcTeV1SejDirxi/tz8jL9OfkPSA6VEqckI
S5u4lgPdZDRxjnPSEpKfr4kJo/ObJbvMtVyrQ8ryGxwyFHrQeOMcpPe0GRZhnV+RrladN8UMpkDX
O7QRQGPyHRl/XZfdcTPU+F9FvptMJr61EUBDu+qNZq7xS0mvdX7sOq2GYRV+eG1suNqXmjysSVXN
T7O00a3n4SUJduJz2pwd2akDcQ51GFEvBmU5/MtChJnMCWPXDBJujKaHXxYF9WuHVceJSlbcRKit
rYEqbWfqWM/kbu9v0Kk/C0PvcLnef/arsEJTxhUJFVXDfggm4ywfD+JrEl8X2+MvxL8766Oo1ODm
ZoCSBlZnkLFICFw2P0GI/W5PGvVbtXnOJm7rB7EExVsnKtUJVnNDAGaUTEjB9T6L9hNESHrpGz4Y
J+74OO3ZFYPyvHEnyDbigSGbZcBhgAPE9X5IsixThxeW6Vzt/1EsdMv/iv+rbUPRs16bCp+eKkEm
vqv8L6p9cn1z08Uez4FRsJYysBm8ZZx2Nprgl95vfbcRHfN9NtHc2z+75WmhRHbpUzMJfEoOk5s9
R6N7mTvjIIAaVMNST+bYhkK1YFhMm4eUA004DvfQ0TJ70GkYFcKHiT9JbREPO4ZzNGEOzunjbQuP
PXI5IVxNenBuDv/7ileYLRTIZwXCgMYVPI+grlVDQwZChOsUarQjUeIi+k5t7pty1zv152+rZ9To
dsK5WI4r3kcRZKGlIb0V0q1403FcuRu5EVpmlsTmaXESTNFR0OEc69Jc4ojVn+6TI6ElOFYcUguF
Fn6C0cffwllSzIa+zzEzxch3quSoJfmYHI8m4pDnZ63KbPi+6rzKJCjMkWHXxau61dzZqRUPrYuu
Lg4toxjn6BppVrP8TNEfSuv6xav3lqlXQ+3qd4F2NYX2LUh6QIFtJLblVhQjxZX2MSOPTwQIK4ks
S606cJgMXFz69VeDZushYl26paO+xBWIau29FXCMXv6EO/PTypDELvKWMfocPZPr50ps2F+pIwHh
kLPTrfRqFxxbiOQvVgOFwYn3l4xKEhsYgUK3u9WtH99+qmVI/1otCP/VYXxWuI6XycO56CGOK9Vv
ln7edUmhhNGO2nVCWLsiDAyH2xH1ktTQUZvUZ0pGRh432vivtTnF6jC+fKKpTngXd4zHU4gg44po
mOfM6xK7z2CCNbyiw/Ws2bled0F2lkBhw0/Q+c/NSpIdDJ1492TxDDNwwaVbfVTMXgxC1sIbV3q/
rMFfpK7RaeiZSdjF6DgikepLEiJMKdlHB49yrHiS2vp6V1kZFYRwUSYC1aGOA+N0n60bLppzogki
EnohgwE69kFzuCefS2r5kruS5HLgcEDHbFR2LA/H2o471IFrCCRRwJxfvfLBGeb5/lCRevWYAb0t
oOpYOGRnvnVwdHOTvWC+O7h1I79BpBhLubaG/77CJL8mtzryLHAQAlrIAYmirJjkpupF+x5hLIyv
mixYTCFICBWq0Nvs48mQ+ONVOvC6qA9n5ZRdR12GdtsYGpToisE/oZIS+k6MfKlnk1FOxqtWOEIH
OXPgObFet76ZNr3qOUAtYm7HSTgqibKOthKHWQu4X2fDOuPsfaBsGzmJdtFQZ8BWoqM2+wwT3l+9
+9xyO9EmE+nFQwRvXRwhjESObYQHQ37Lj/NyQmvFEecp0pbpVTSkXkNJfx63EITQ8SHccGIu1iZo
Z+PJrdY52DYaU00OpjQH06zm3PS3KW0yyV9GfIIDYOessvf16h2fS6UUmd1uhg+GzrGTs62dG7HT
Dumc0cOZLKFIcqMb+AaRBAHTjTUNS9jET4Ss/wKQuSr2pTa61zFe6+3p0UbKMfW+SRvbnTV1dYV3
0DY5fcTPBlwROktvbHEvbWpIXDrwnP1glmlWcfXQrp630XPHXvTlc5Uri+KBi40dqitPG5Tfhl2A
D7fpEoywWFEX4yNEdGlHVfGH2LBBB8v7YL7/tucs80rRCHJD4Oy+vfrBwcmw9D5K1D4/U3vXvnF+
5QMNSX0z+d//EuGLZgjbjiFVL+HZlQ/0U7b6+XLJdMsnfIsJxYX0E6C2g9MeAJgsQjPKRlfCZK3A
Q0AGJ7Hd7te3YsS8vmVgbePsXooLOgXHGKNpjDHCj94czxqtaWSDf0beZ7A29ZWTUWRYd71jP4In
YlwxfNE+4+4W4fgInLXD3vi+HEPaxCuwSow6zf4s1zQNuaZpG9cUwrkCB6VZqGmHIIUL/JPrkeHw
MZcslTroYPwJgBGCHAFi76PyG3t3H57kk+MCcaNXPnig/1KVar6HSbqOJTUI0242bbs8H4fQ2tF1
xe2wbVfTyONW32o7taPfbbHwyCjYyWKpkafrato5Y1cz5+uyy59q13Pk4hAFGnd3LoA95OnAyOTp
OIbGqvJZN0GHPOjthPQH40uXFO8OEZ4Yei1ynmF2cWVnR1cLZMhgyvSoKdqRT9+6R6MsUaK3AkqE
6dQEDgenlinE10bP5wAZOOjP8/X9C6rz6osH4F07miH0zoREhCcax62tFHcXGk16nKSbzU8Om6Fx
H6E8cNZV17HzNoTnWxkq+r8g4I2bpw/+Lsqrah9PRyf+2okYMt6IEtsfZnkiVoPd9/BXb8dBKcw3
dMv3rdYDzb358qK3J59aEHrrUdXTdw/a6Ufy0g7/vdxrz3FSJIVKbVwV+Wc/h0WK4YUDRn7QMTkS
Fe29yi/Bzh+WibMx1HPPO0F/w/pnBB6M7FFOxw3+bBmB6RK+CUBWmhUbpqZkihpEGAvDd4MxHyzq
95w6TP3Re6KRUkqW9fDNMtDQOALauDwrGjfVEb93KpHaEWiBHDseMjs3ekM/YjtBMXq+YJ/W+86N
vohtKlfen+VHvFIvvVv90P1N8d528Gf50e9VxRzc1at3Z7baAjKjLn5Vjo+t8bSK9RM4HL6CFwC/
wNvG/Ow7h7bQKnVgq7L2+759/bnmwb1e5G5/vPA8vYEXzo1eIOmCKuPxCi6pGrcRMkSfVf+eKUo0
pp3FjLYUpUTy3sGrBiOpi9MO1pthrG7J2Nhzp/xr7LFTjTX22JQ+DR++DrhioRWD8Zs232JBvUG9
LV7IUv1W67Qar1l8wztARnkDLwT+afKKxQ28YvGn7RMNXBqsrXkv7mnX08arLu7gYxxapkvNTvlB
23c5xWOYIJMcrTIp2rGXw3xbS/2UUGTWHEL3S9F3FJrU88gjl21AZsdIG58AUqPM0Mlmc03uuCEl
6gXjOzrYU1RRigc0XhJcnB0Ejyhp+9z1KVK/OAPXHo4ausP8RFM5wgyKOIVz0eTBN5uf1iFcaMOn
cQW3hMYVu3VZuB+t015MjRB/+dxxkAwKjw84zY3ekFe1HwBJafpjbU6pkZrkq/TXdHQHy/KDIt5a
4ay2JKHttrfcMDzo+x/lBB+87HXofOgf4yRfz83R4BP4pi6iY1vL4yWoH8xKMCHeXLT7kRPx1463
5sxoUZ3Ybc5veIdQp/O7LjTfqZkxxNEMuh2cS/NkZ2H2s7qxBxg9TCLo7G+1KY3QsDKhQckzKRq3
b8NOTAOHbO8EoTTV3vPg9KDM1OHp4UlJs2Ja3eN4fxpKse2kUHYb5osZs2TSSv3mk9dtdJhPRA10
h4r1aqF5W2u79+Q1pwCUzNKb491KtVAvWZD+mAz8HrcFDK2xVjKOjTljFoiCzMjDdoM8bDUDVJem
5DYVeaEYKbQttd6qnJ/orkwrDuTWRb3YoifVRHUuTddbnUp4+CmqsizzBAXXrDjwcR62HWPj8Z9U
c3qiv7mHiLnGftlO9mmXJ1c+DKaZVsCJNdNVlDfe5PwOju0v+e3f/h21pjNoz+r5+b6TSnjdYVPV
6AZWhFEQvPogw/D9vnkAKZKuSyGpNDl/rb6rQPN6s2yhcTY4pLk6zGaUOl/ssocygfK1QzGM8XfU
LyTZN5B6ODoXNDMY90dZNs/PK4wHC0+yGA4zDcJp6pB3/SKUGHuzQ53p0z5yntxm3bMckdkhkvtS
gV735GZVgDmz1Vb0ErK7bRcTpAp+gjTtZt+izbaZW04uvzbJEHyw3tzQOku7fd/cabTFODjBhDTl
gak7IksE5AT0jnaz2cGuz6RCBJSQmJfjRCH9pHqr5uHYlHsxXpToXs3TV6goq5pjGO6GRJpPh5PT
IKpJdhUYNPXyLDNdb5vmWw3wkZTeDpR+OfMhSYtO1OTD+DwE4ZmOoTNHRr4wk2A+qd8izi3NT5OH
GFmxnTJVmszHEtyGVIK6O8QU6chWm/MWLUbFXKEgxRzZ6BWBkasAOAeP1x3NIB38EldnE2zjMh1T
Z9yXHCb0b1PyqaFOaPuiSdOsnS50bLANjvBzAxsQzL6FpWZbZ5kw5DghxJHgQFQCyshkmkbBjexT
2XQdoO/AJ7uRFtnOvZNAwAKVc42jBKWeKAOJOl+OivF7wgVx9K6lIiQZPLlOKEqvTLNO4FvAbKQB
j4Ha5l+f/Pb3/wBUnot9FAhPkGibsWd6GuCUwWUwbdbt6BxK2mcFDzeXsWbJSzBIyJ5dgpILHVAT
q26xv4doB+DaJpoMsla1gO/RB4TNOL8t/e1E4kI76ccG4vVnTu+RW4cOVwSN31IEgD6QvyekwNiS
t4rBqLm8exBywH6wZCTEQYuGpoMs0fY5Nt4h2p4KHVPSUiTk/IgJqt6EBZ+5jrDXyPo5/Pqr/wT1
C06nJrotmN1981kg45UPk3NZUPUnGSWv6fD5tE7PHTfJZcvAdoFw/rWp2CIVlZiigkWoSBtO9VzT
oBgbduUDPT4X7BVNVRZjvFzTrkJ3on1wmm9bEJz1mfAA4BX4dyA4ukh6B1GWZ2W1qPWGYMRQlGa2
wOzHidicU9nmJGqqDaYAVEh0D9IR9h4Zs4eYmgkJ2V2bjPmiNvh2T3ItgPuBSFG4nLwmJ/n4aMNB
cITSzIvDk0l5qFYGASXw+5xJAijordQ7isE44hGgDnwLTePpbQP4OcovEK0UsrOQsywK8FMum6Am
qi6MMMJsep4oGrdAwF87kRdulcIdovB4KKX4qcCZZy0UoDSh8XCNdpE6DL6i0Zi7zfGs9LX4zrBv
nSdIzSQUz31gtzcK/fEWpxiI9NxMIYgCSe9KPHO6qWXRrYULPs7EJNok0+DHpLZs8rgaFdGNqRnd
ZV7eIELRB3Bgyuu5qRCtiIJUU9GCtlEor59n+9Hl10076iq1oKlFHJrIa3qLURFtyegnREpPKT2K
kc90BzyVwWKc4oqRVUDYU1yxMVVs/18+bNBKzJTAgK6JbTF+KHLC1QvkMlLnnA+e6B1mJUIDHlH6
/Nuun0KDlcVNj90xwGyH5UDMky0tr4XHzU/FeCTiDVehnb3hNKYQ1jDYVc4bZz7bUFSf/nquW1FW
NwxXIHp2kRgijomueFRNnvG8dmXqgbE1dLRr6mstEdQ0JkKe9aUErx9YBXNUzur5VhhuDV6XMhAw
f6m9ppALK9IVq3s0cp5U41EtWeFLUg3UzcQjprasSzY6VLpN41iH56HG2OpgXJD4+ep1vGG3S6JN
1KJVUstB9UFw3Rd5dpZEHbifhicicwTudztfw6WHnU0X9YnbiVNTWZGNI86xtpXgT5JTz/e18uv7
JO10i+2cMUfL5REHqbgcKKk+dh4d42qPqYxm/ug3ec10U/2mI353uQ9oFNe7DAzxDxHu6sH0QZ/W
PCikXpLDRdhO667NPrPmQ4w+CnuirrNNSAlKR03Rhg2RjC+QQcQg3xEKqxe+Y8LbBm6ShNGnPP9g
2i5kM37BPvgJ3UlbHYabI+8y9bQkSephdPL70W7TUQOs+SuOkvrYCb8SSYomioQn5BQGK/DamitG
biN/G46jtYhwSSXZ+c+Mvco8pWp1pB2gNd/R4Y7fxYdu61hHNnpwQ5f7aOk35EbYVzxUJjC3Z7r1
hqAEKR4zGWzcmVIjbxsN3Aeao7HqX61alsPbiRHgUc6KsUQE2Apc0Wn9NGxHBNY2M2XUpV+Px3QU
2UbBNo0f575nP8yc0XZ2J2v9EAPeSiNIHkP7me7ZSGZQUQ0Tfur3dq5zOB3BjCFvtod8bXV/Y785
lJDanDcWpgW/Vlqc1niLpQfrpwu8iNG1TkL4mUjfnMJhye0XhK8cuSkD2BvYBrRqZ+FXNnkA33rF
CQTcjo0Y+8QaT+KirUeJRbq7bYwZRtgX46Yfl7zWkJp1O+bVSmpVEqdIUhObXNfXIx8FoFTG8zR/
N7CW6Q1nKENjhBYzoFSqNCPUNxoWM6JzT6hwhRobVbAg0OivrB4rmjHYHCY3XOstjOL83CD+Dcq/
j4QpW0ng4ApR6S5p8G4nrZrDzxbvwo7SfozXnYmri9TClqt7pDqZrIBENAmBLT7Opq7rupfx+GBW
vSkm3yfky0H3oM1kJQCcPmbvs/7BYi1HhqEGrbJWk/QQPOTF08JQtZGWR1R+eIVQri5C4W989+pm
49sISLw/PxCL9cZYVdTFoHVNTcwGmiNn8N3kavL8bjJ4dA1/XFvXydGp7BcnSZu8l9RIE2tAdXmA
asLIeJ/Law6KszCYQKzo6qF6BpdS6JG2M3b0sIMiPTARB2D4A7XhpvmI+87uvnj87Ifne49++HGX
dELdzZ4/fPDTbiRzLxXbyg8adaW2nbJ0Xm2zNpodq2fTiJNyJ2bL+9UVyhTm9GslAX3JBdd6o1wd
+cGWU/FtS6ZEKr9pfZetIRKbqo/NbRdPWPj50+CJEnNb176JB21fKDmexGRJhfLufHlGQ8sBwgRb
WAaoOxdcI/HCt0MpcLZbIdrueqP2rHxGwjA531DTKD+VuroXOan8Cr1OUL142+hvZH7l3uZzp6Qv
xTIal6DPd4hSHJ3xpLUuCxeKgHZp/Arxz7hWi4HGFTkcaRTduo/W77dpeVwN7oViofXV52Btu/rF
U+NaPaYa17ID+mJwedu2iXpkWnQ8YygHnvqtj3kkSPic28P3cG+15wg/jKwU7ZZ1NzuXtmz4JZsc
I5ImC6HnxJqvJqE7ltJ91lSAbqye5+FhnN86kwIOrVjx2iSkFG1Q+7C6swQ33C86Q6y/pGxE0fp0
zUMxUverM1vwqwa6RM9hJ4ump5xk5eMex65C8hRtpL2R3jG+UrLqtWvPBXst+nHKPto7Z0gdA+5V
qkt3gH6if3hVG7UegaHmJfiGlXrV/7NUklFG1HL9QNhxXcnYz3Q80v7I9HXTNYxKR7NSwTF+L2q8
9Sg4bpm7zhW7ZKE62OSjysQbxvJhYOxc/cru6TatWovWdv0fNUBHzeuOzZ/87WT/KYrKaAy/8iFU
ulMSp/3nXc/bKPnnXOeLE+9HOXK9m8Es3z1fHIVdmu8tUoAzzL3+pJi/rWZUDAi2kpflxo8lObKQ
pgkOpb5Cm/xyqcaV4lQnPA+SXWUxdfOwC1GyrvZdZKnrBERxYXTuH3xOv2Tonny6ZKtf1Hl4s1EH
89UkI8Uggh4x+WouPz4VfPqk6XHXyH/S7NNgVADLdnItiRVQnZj6seZcGOqb60CTA8tffslr+BE7
LpwKdpPkoCvX147irHxvvI2JOJKSFxSJV+pVrmP38Ejd+Eqt3EG1YBPfW53Zb1TBjA23QFIyvBFF
L71c1hRIkX2mHOKth9UXLoUHUZz54RtQmtb40Lbr/4ViRvnHwN9c/PdsZiKwzm9OVzlxvWTGsxIq
c3FG6Upf/U9FQZaXS7mTjHjo4p6jJJiFekiHNZ/MEiPzpphNoLFTJzaSj5HTJxRKnCGthiF/Ulez
epgc5eoQnxZwHjzN31N6ZXAFWfKS3FlhcKreNLyDLRERTrnh4cfuHto4KDfE7Bc0852mQy66k0Ww
ikbH3ZQULS8555oCvJz7/EMT1AD1GsmznzkBWbUbw2myaFuzpZ4JYk0KonKF2FJNImkPAj8BM9uJ
M27RzMPsmKEHKTfy84E1v75UCCwkUDSFuNeNri476aNmoeNLUQXYjFiww7Fx95luxjy4WxFvimOu
Za459s507wYST8NJd63TkRk3j5dMumnnz3sHJEsXYBpfgGj5+vYVUN1UoF9p8rfF9Wu3rieUY3VS
vGWF1BQ2dw47l+ISaV0ocqE6S9d1RmN9R83xOzadv+bsqd5yGj+AGD/fWM3n4qqgHRS8etOPqHJh
WcjeOoWbtfp24WRd11+Lrpo8XLJm0spfsVdy1zoVfLO5/inWbbVloyXS+8ZMtJlkS6a+6VDp9EGP
FDOcNjreUB1jCKcoJP/aEd8itHrZxr3DddnN8rq5Dgjp9owjyO3bHCwOzPuRbw793P62dDNhojSy
eOHDF8UO1IlfghpUSt7DC92v40S9RM14hJk+MtujGQPUvUHcUB139hphSncbVdgbdT6cSTMTZeGJ
T9JitmyOFrNg66BLmp+8307JP8VOyUHfGpUuWpiqVrH3FcGQZ2eHKOSQKqKH/XdYnZ6Wc4qr2uc8
Dzn25fn+a701c7s1+8nH0Lj4pt5vGqbe7tiwrosLbtVIx0EMoEUKrhoNaVCwgvMDTLQfEdcyRwVK
iqvGg1rJ/1lyR2Mh7nLqhhrGB/5CaUJsncBbL3B55Ypj6e7yYDUnpS4FnRJu94tgY2UGUJV93BhX
aeUbmtoLrmP6t/SJxaK/KWpa5BPENL4toC1TIj6Kzpu6jmrbzZVAdJolEmA4B2ZT4cOpekHU70wP
1fRwmXrygmS7g0um++rS9IR+MiPSR9UQM0l81tycm406Ymb1t+EnVZHLtYAvJK88Kg9zLoKNcw1C
jpd92akLZzojz3H796XXgPwypMqlxQjdcGve0BwYrMQcVjghipiYbs4QRKXpR8VhOUJMPiZ+ikQN
qnkOjDUrk6lNbNlJsHjjt1AWjypHfPSo6c7iACpffz7T3UKBdFqIIBDL0LzKevA5F1aRSB8av1it
UEvDhON/Fpn6eJZPT8rDGrRlVFYKGqQYpOUpOCWtxrKMpuP9nkk3RduCUq2rfXHGcgrV4P6QhE23
krP4JH2iAd8tjzWhSX5ZnE7rrgGc5r9Us+XAU7PLBpxy99AJFQkZbyzaTxSiqCM4TXTpV2eFaEXn
XeNG6OnyYaOVGrWosveqyZ6rGb/s+cDhqQvqdAxF2LzukahGPriRXi6qqG/bgCwhJBvH5dxlh/3l
9FP8i0IGmixRjC2Zgb2ROkvHveaBm7qzcSmrh6A7nZ8E2GwDfLqGoi2Wy0eiW142Fvoq2U5MhOJ3
OeBoddlAv5gQ66uOs7Fi7xQvDRC6t9EZyiYUy8Hndpc8gP1nC3UcHx2R/he1qQRWELtib6QO2/ME
/97vQiW07YFHaNY6nPjB/VIJIpd1Xv/LokR2rwXFMhxDGdhC+icer2gPgBmWG5H67PoxJkXU++jS
I8xdkfS947xz5d1mn2zhd8aKzZo1hs9ZBkgwUCCf5eNF4QCM9J97J0oarFHERXV6DQLMu63k+s0h
HZN0B1zez/wmM6TUzc7iSHFrW8gzknYM1n5iRaSgwV8WVuw4ZeS5vi6kQsp200APFj7V5iG5Czhw
UL0jMbdA6HmWsG7yfQJnGJ2KDSl04PKQRREFM7pHBoK9OWXYWdNqro6ZDF9aeZM1JJ9L4TKmisUf
iBJuPTr6QMfXMeSg5efgkFo5CijVRrWrQMlIHyFSO1vZzkolyXOiRZJ+KLqEQm4V91wekbZF7SEq
V6iWAz9hhI9jiZP3tXOOTCt3fozoL+K/GwPCATKrSbZWRduOvIGfCW0y2lMcRaOdrbYcc7fvtegH
XTdUeF1qi8fVrGhTWUR0qc6edVWpuhwGe2Qrae3BrBzdv4v7WBdSKqgGbycJ+TlNqiRoZbWpaRrX
os6WGY4AUmvp6EtUxFhHDFPZw98Bz4vpOEeMOQgc5QmcsDH5zmQ0q8pRsvvzMPkLiOO9cbUYJQ/y
U4qreFD8WEHf+OTpy2Fyv6wPq9mICOWfEEOFsHRkGkJix8PFvE4v7AKiL1uXZFVvEH2t7hWiL5vQ
z3fwmM1Xjc8wsLTFN3qYzFEa8LLa53CQEaf/09MbTQC4z7oyZO2z66B4xcUEsVSKd8oZA77ehJL8
I+Dv76iir49zWNGXs/Kr+q7oazWQffsDf5osVoUi0mScns2zjNOp0j3NR9KyXexEC0LnDIvTIEyf
VLHYO3wuqljUevK7BMEWVUMNVeVPie7A4PCyJAcTtYMKosQDp1YHsl4Pk2dqfxXqNRJ17zx7yBpd
QeTjgln3eTXdmNGWIMd9HOTzE50qFDqe6igZaeKeRRmk3eLd3My0cNO2hJJzRhdamW2KjBTZHLLj
PKPXKC7m7hhn9sDn8vwyJLb7bD4rTwfO6S7/WVLPHbJVUhvlwcGsyN941sP20HaKc/DijkX3oGPD
CZ133bSRQ7+949FBKmH/dKSq5p2f/32xmW/eyNP2OuRyqvKweoQidZy7MjXtR2/Q8yfLAfAP1/z3
8CczVkHFympfKpPtWolAaouVOhjG9xw18U6X6UT6iTgGv0a9lOtZ/eywpQPDMhN9L12/frU6ys73
e9ZU6brOQ2Ob6obSL5YjFoO9hLEctKiT0AePHCMbOvni98uUZAmzXR49fbC3s/vXRz+47SHhK3pj
suq+V6Q92T0h7+nxmPQJonUyJvVP4VLdctqTdE+0tYYXrXU++6c79ne0n/qcHTPhjXaMM7uWxKme
v98Q93MyqOcbNQ9JNcZh0/8ED2spxs7xoDpMz9PcsdL5H/GO8X82ymiSQTnT8jFizbKiPCv006d4
T9+rUQeb+MdcWBi7cq9dNYtfP5dlr4dq1oISukiesqgLLrC33p6EpLm3plVdiiA+K8ZKIjsrWGiX
0s3lBGFBG0fjAlWZ83F5TEiBws2HZAQLY4QcPLqb1wSs+iCw8UDqGEVc+ZqsRHRqHWDzg7oaL5BC
oCVtDzxlNkAI4g1mEue08W1rE1tfOb3W3tGJiZhqb2OLM28mN1pbHVSzUTF7no/KBaa3HTAYDo5n
kKO31KQiZ7+OgXJZ2/T3Nw+/PvjmoKWTw2oMIh2+fy3HP/z+EV0t7ztE+VYrpK4r3Lebm/FGftxZ
+yzO1e67AwS0uNc2ke8UZDzhPKkb6laksYe5Fj1v3cJU3Lr1R0yDvh3dkLsQh34ui7cX3Y+H47yu
n5DlBtQX7tzl4T3cLOqMvjKMFVb/qG1pN5t7PnqV3BpnHI3kWQnNKqWZO9BEypsOveHNbETHXJ8d
09ff6s1FB7rdR/QTKu+71TvaMpvJ9Zvqf2A6FASWsajnyCqGIXPYyT2gtLmv9+51c+eRQrRDqjE/
EyWUvY9IcudBy8ypA/iEYB9BN3ztenLj7Nr1ZtSi1+z020Q1/Br/bHy9pO3jr5Pr106u3Uzd6T1D
dQQlp76jrKSQVjkgxCvwKJmoRcVtE1GjCNHReFGf7Janxczeo5xOzj3JBjh5QBn4etT3laVdWwO+
wsm+mG1nj/NyIrk87kynsUyIXF0w2pVTvcu+42VBpIFEoINcw6APKM/r1A+Z51oNkU/aj8nwsQVu
m9frk/LI40DCfnVSRJqhuCIVXXK0qdai0h386epAv3N1oN6Yqwm5Gzp526f5e2i3w5LsqEcFP87b
xI93ZVKVZk6hSFMqed2zNvddwKt/AGLmizGZAtEDkPAPVyOvY6no+4oD0EsWpmLT00ypsfVov+9c
v/Nl6yDd+Euhb/ZZjWXVY9lRgVhjXjB53W6+eKVUej5MbmzaQphXr2JR9iimB5oRpBTgElTqi6iw
VtRqqskcCDu4RNmqhuppPkUmTPDUZ8VM9zZX3M4xCprlkmZf9TT2M/UqzCIav3KFb5suylYc9dfq
opWfl+Ke2Hp0/OCBlK2A7NxEQllOM2ANrSWI8XUyLyBQx66VqUq4I4rhHUyeJlF4ST9QuyujAejI
uKXFVOVF6sUtp+p9WrfakSzLFnQMRtHlQQDckAwu0T46ht/sJPmDNxFCxO3i6KKTPmNhmbC55p38
dIT6LgsNLoGeU+43p+09vhe0LA8rX5y1UlPQspogcwe4u0FIgnqUd27b8AYO1Fkym7+pcotWt3Ve
aPZmUbRnb84Lfm9ua40mHiJ1tLc7wsUad78O9UYDCf1d8Q5Ko+SD8DB5bc4K1eLq1d+L28PjnBKV
vXj+6DY1VEuHGJ/f/R9QSwMEFAAAAAgAToplXfHPOqJaEQAARiUAABgAAABTeXN0ZW0gVXBkYXRl
cy9SRUFETUUubWR9Wu2O20h2/c+nKMjBuqVIlO2Z/UBPJoj7Y2aNadu93fYaiyAwS2RJokWRDIts
WQtjsb8C5G+QV0gebJ4k59xbJNWeQTDocYss1ce955577q1+Yu6PvnV7877ObOu8Obu06fb49n4a
RZdbl+7MumqMLTOTl761RWHCe+P1e1343rqp9uZHu3fmdZW5uTnk7daUVZuv89S2eVX6qO1Klxlf
GWuaqijycmOy3LdNZbLK+fJpa9rK+tYcq864B9ccjceYwpnMHuMoevLEvAp7OLvCzo4mw6iiql1j
9lgTO34em8uqPppEN7cIm4v/mtcJJjft1pk99p+XLo5exJhv3PK5mc3+1OU48cs0dd6bn//jv4yu
w9/uXdtiNzBQWm2m4eXp8vKoKmezOPomNhcWE+WlTjDH1ONgjusPclt0G4wS472/u+GXv42xVvPg
ZLPYuL482bnJW++KtTilrvKylZfr3BWZsS3enkfGmCRJ+E+amb8tr6pDWVQ28+Y3vzH1sd1WpVns
zbZt69hzrcb84dmzZxz/hNs4l1fny+XzF7+Pn+G/5+d8v/ylVfuVoreN6UruNm8NXGrzzbbl+bnJ
xuGwTau2OI8ifsF3WRW+sajMLyc2i8wst9XeLf/h/f31nfy6atxhWYvF/FJnSLc4mlncGRl1Lv//
/783eYz3ic6jG0jbYtisjv9Is7lGtkwAftiKhQWwUTSbSYgAFvFsZt57hEGS8kk4SKK+S2qb7m25
SKuybfJVYg5bV5oaK7myBQjXnDFnAEQhyFw2F6fqJmQ1+ewJ1nbLyFEQnJu0qvP+7bFMzdUFgW4N
jlNHWd7McaI1ltpi0KzF9mdzcUqWr9fe2I3lkpgtNteIWCDhYI8yW+Nsgchr7cp6YM5HJWMSk3c4
IvaHOF4B5Jum6gSIGtCpZRwXzgLAjGNCwNQwaG4L+HfTwJwACKwT034hDoIF32HZfkzTldie50ka
W/ocpgpeyoAbglxxpI8WGG4WC774PiPMFnihXsDjslqsigoBuVjUDWOwPX7/7li776sShqlaE8ex
uvgVFumah/zBceX71tm9Af9tYHcPS7sBHjSh7f3TOMJkrtS2z7P+oNE2T9OuNodqNIrl6cFpignD
bcXmJ3dslFwS26Rb2KP7vNjpw2QeJSk5t/LDo2nvVIR949s5iTId5w7D4DTxZOc7S2Bbj7i3UUKD
AIv46j6hnYEFBB1xGDblPgNdIO9y8VfXKGv6tMlrhnZVe5Pv9y7LYdviSEMghJq1TQMKi2pjGitQ
AtxonLY5cjc///2/sd0yx66JQ3ClU4b0O8wqHCyYuMenOiCCvxsF3i4vCt/vkEYWXNiUuSVGYOaj
UXFu32J4lAXi04AxG4dj3b/68dWbd+aMRyR5XLZN8Y+XBlvNiMNzOUT/RU6VATI1EB/p6QAj+BvG
ZBAgwWk09nE7jc1bukIiun/MEdjazm5go6qJYPOSz7ZVtfNhaOHWzH/BQhqjvzD8yiEba2Yo3Wc+
dXV09kNh29ru5ubl+zusHz7KDHhiVl1eZNwLKKfaNExtFpO4MkM2boSoLYI+Ni+jZORBLpiYaq0I
QlzNGQhA2LZraZ25WnNkJeCr3SNKxYBR2PbB0syUEEIp4dxptYeblONKPVoswV/b0mFpkLo3kx4H
P//9fydRV8KhMl5NM7nt7cmziLdPrD0RihXYjJAIq0dV1/ocDIOngSEkZyGqXQYjyH5qmqbTr7m6
4iuSUXg1D5C0fiRsge5tMDChq4gcFxFCa786pB19srLg3qrZYSXsMBqyPuLpfMCjyA/YgtsJ1K0H
fOpPTHL2ZjoBj8HIzXEquC0N9puvGYfB6pORek1OP7+ZhDeyx8q3pwGmUI2jr7FFAHo5C5mveuBs
OEhPSJjqaDZgUwSKkY0T4htkDgq6a9F4KXUQTsw3I/4Ss+w/CbnLZz1qoqYUgWkZH91q5bLIlQ95
U5V7yakiNWCT22M4JrzFbAXQg93oUKTqm6uPN68u7l7e/eXj7ct3f0xUTfEIFpk40EOybPf18uPr
61ezBKEEknCKQGixImvEXtQEJQgvF21QU0OC9WnHA3a0iYp85X0hBMiHydvb6zf39zcfv4m/jZ+R
QxAhmBlyweZF17g4aA1MjvlURFNvjCFiC0SsDyDinG3T4R2Op/HV0QgvITtFUQONVQmuBuMDHaI+
QL6RBjeS+xaHRT79Yu46QPYLrLe2XdHitzcVtf2X6MtisRh+MPDepR2Oyyk/Y1jYDnDyxTzk1kgW
W9guy9tkbvL1yI8xpzQezku3dlW4mJOblxiOmMJZvugkXQk6AfvC/f47bhZntZJFJkAA0xk8ReVa
Ep0THFQT/EgBOLNyBoKAMSXzca0PtmWG1chhvPRr7lwD084NUr1FhD/kSHHzXnOA7uDFdD5KgbnK
gzkjuEWqDDkan/PaHWDpuenTNnPLFvIc7wrr95i1yPdU8tzPa/sJ9IhQ8IyzVbev+w1Jbh/egDRr
GAIhBMuVCPPvwoBZe6hmwrF6Ai9C5Hfx899KqYFffqeIEEdKcZEzWZfOjdr8y9fO68WTT74beLun
HFBigXyf4Rirxja5QsT8APTi4dVPr+816fSzPpIVz1jblYpCckZGzPUFYOPCFzHdjW3gnBXdJRPN
zc//+T9/eGbq3YY4EVVDAWL+1C5/urpmemqrqoB1RJLpRAdqLs72FnbMOhdmev4ti0pOk7m1a0Qt
MbWS1cH55DOqVwTGIKZAGzno6gtj84lkKwHsBlaKohHA+HbdrYAviGRq/DT3lEl63HKQtzQ+6X/b
0TI9M6iYIKFEe7tjOfFIq2X0O/S2ijXONoYJcA5D4Su/GiAqXvqqc9W1QKwcVIpGsJkXOqlic6cT
fq3MojMVoQMuymQa8kUt6Ws2e41AUxtYL+GGEASnB7HEEkNNFwDYQ+8RrzEusY8eoprXv4bfiLoT
g/aYjGW2YYYe36BXuHZyFz4OQgt5cpcjhSVvXMvs+9qWoIQGrJUcavsRNURd5ChqWsrwPh91mXvI
OGRIUM5XxYOTZ9mq84mmiCQ/gNTp3LAN9W4Fa0h6t8gMD9yslwin0PTEXQMzym40yZ2IBrEHyKek
XuI8VD8iHaVNEwH2VdWO6lEbKhDqhVdAA9jAB/Do8EXFvmgXOoYJvZep6pTZ7PQZ/Mlqr54Ha7IY
firCMqealwX7NhLKxnlIT0w9Ar/TuTRrbqUi6iWSSu8hVQzM1x8G2GIqmEc46oQfqCNBKRM5/J8v
71E+zRYb5JzpsE4sz4dVQw0L1buhfotOG1ThCHnDvB8/3q2SCU6a/G0ZMxDc8jQc/FIGJNGZr6CF
b3/68eL9q5srfA9xsOPELILhyl60YGLHLLCTmPehkIQxWXDjOAXsO40jkQDaChuUPIRdmpI9tEUQ
4jHobfYUgipHaKPS5ZTsPAEZadVorIt8gphqOhTEG2iGVWLOYMHkiNJ/8Zfh4VQSSSIWHU2Rt9Gn
DqDiZrQuQVlCYFdroKkXpmq/vjnY9w4F9VtCT/SIkOLk1NATklJVKsCioefGPCatF8RtmAuqgDXm
AfQqSv0RPSW/Ulhe471ISC70LwFbCdezZYn0yHxWlWnfurTm9y8WW8ZiiqSiFY/U90FkRZpsTzLX
QoNN3cV+CGKUT7REEaY9aE0gIkLrQymWmHlCH4X+WRedZA8xD6L2aeNEvLK7JxWB8B8VNGP0MOgZ
OYpBZd5SWWmVtfAOjrYsGEKHkIsAQDX2tSmqlQeza78hqJVZMlX9eWOPLESid4eK4ewDXi8uFy9+
+8zcsHBkvRxFC/BEiPvZ7BzbFlrYVAKKkodkqY9F3Pw0wkMa0iwSmV8l5zN+U4hdCc4MBBdas6f9
mJ70MVcgSqxcnKiU6Vzyk9LjKXudhwD0Y9nt2o7dTSqK+Qh+kDKwsSurgySkFQw0N/BcSzXXj8L8
de37GmluHJFnMZmwZ2h+AEaeJ5XaSdiNwjIe+8z0pkkLkHwmmYEQDAjAVKsKttv/Spddlj08jpVY
XPQORxEHDeeT08EGqJmkU7cWuOuSsleUku/+rNUOe5cV66g5Vuf5emmsbYdwSp5GOxshzxD6J01N
2W8vQ6oGU905lI0sXUC7NU8wH0rTHkn73PuhqDdk2NB0CZ68b23b0evSe0Wh+A6gMH+8ev1qcXl9
aaTYXx3l39hcuEIMbuG4Gw0k0wNo8kGROC4h/A1WOmOOrZg7WGYAsi7dljB5wfIcFc6eJSVUwsJX
6/YgSRkROaWp8Ptjk8LoJ24mtd1KcofKgODM3Ff+CWbh+apQU8P7n6XJ5SBsanr3pdwwMCACkPtc
TbeK44O0CuykfcvHC3EBUrgfe2NryJO50VuRd8zot1LrXF2YC5sJ0i/v782N9Minj5zLyZreuWeQ
sWFfVEj9h0VPBP+UZ//86EWj35PnYCMzyAqMl7TRhN4CZcz518Ij9JtC7+Zpn119OAmmw1nG3CSN
9FEyqRmR1xp3OkZFwePLA0LOKvnLfnUqpL51S3URCrX5yGw6NwJTeouhjpuoTsJkwSXqOO5HddYv
eBH8fHMBnN9dmLOb5/zl+TTU1MjF7cGFLg5Zm1lC/K9Zf5WCvBfi9NhvkeoHHyjMgh96BwwP2TUO
Qxf40VFeAi+hp/EJBmkXqUuT/hyniy0+VVAZ0keMBCfgzLpr+6GD/mlYtO9dkEDSLQixjqoCdfx5
QPC/d1gNWxNhKfx1qDqmN7/DsXfBZ5k2MiRzy5E41c65XmaL2gqOj67vb795ofqDvRJU6kMSpthk
CSaRzRFdG/fg5td7wuKPlNU28tBbZabFUehHDUnmbIf0a9IO2hvl/Or4NYCn454+gxhz9rQCS0sA
BKMBZPu8tIWm67fiKotshbwaEhX0NaXKeOMWKvHFvXl8J2XGho1ehPzizmojdyKsIYbLocd3Xd89
6voYV1KEeG0G992ipmP3DCoIQA2XE0zwSF1uUzVHTY2IBnpSpfoKDAXNVKahSgF/SwtcNtJ0cnUF
WNm2lX52FF1qsWx8aWve7aj6smmr3QKVqkRIr+dWiMS+iJScS4GxoLEjJjwRXqf3GdQgPu3gsPuL
/hIKazGBkWKj0xY6wyP0ehZh0IK3dHGQKsO9ovTZqKQuQpOyv/5qsBnw5wRw3PjJufnXCZ9M/k2C
LFFAxZ88lOyUeaDvz4bLeeEQz56GAlSNoR4DSIWmAiT6qoKz9IRTQ64DqNy3bULj8LSPrxKYGVq6
ODr7hiUarISYcUzwQSePtyHUAWCMUDsvpa+2FD3kC61Lh/6S7pAO4bZuqo0/ZwU2XOoi+frlY05e
JuyywezJJ0Q44oGeWHTmq1vBRNH0Q99lP0mDUbiUV0lJ7pI03OeCPrmTG/rqXM/y1I9CkddiPbWO
wyj7e9V7cpczFquvWhUxXiXcCYGe1MVnJ38R0OyYsImF5YNtlrDl8uRLyTTiKZTx8oFyznv39GUj
tcTByq1Hf2ePkkr2LclA7hoTbSLdXF+BN8F9pfa6ZEt6za8l4UH71pp9eSngpKQ76xMsKlEHMmmi
RxRrH5Ps0DUSsmXHoWCXCWcY7lFu79+HpDcds/el6tTo0rH9pfc3uq3BaKw3hz1CkPHmClWp9eak
pxAbqRflgm0InlNfyV8BOBaDPJ2iSe+LQ3lGHmvatGOD60MfOSeyjguOPn1ZQuPnmYHcPvtgj/Jh
Oj9p/dgs8xGwfwgvF+0DEvjwVy2Pl8bUk3HGCYy7xtE0JXmNqkhqUPnDFW3DzYMT1WE4ndTxo+Y8
2TrSeDBJNK4iV2fhyELPtmAT8AiQYo0QA8B0GWpf5kC5QI2yTnpscv12esUhSZt3XnK4pypJhyWk
5GXXLPc7pfKoP77eyPTtw/4CeCSToWjfQEDbYBf+JcVRjBC5z21j+7+sqNYYUtiuTJkCaJeMF6cK
UhoLien/AFBLAwQUAAAACACKqmVdqEgQj/cAAADVAQAAGwAAAFN5c3RlbSBVcGRhdGVzL3BhY2th
Z2UuanNvbn2QPU/DMBCG9/yKU4ZO5JqkKSpMSCAxIQZ2JGNfVYs4tvxREVX979hO2mZAjH6f14/P
dyoAyoEpKh+h5IwfxioYwTy58i6hI1kn9ZBog/fYTakgx600fibP6d77B7jReVIwC2BvtYLX6IY3
LWi66UeTn1JahH7OJpeL8SkeY/AVZC9Syx1+wCqo7B6EdB5WK7C674OBipexe56nMTQIGrikheRJ
EP8e18zIZPpssME2v3djYUIdPmC91B1f/jNOE8zSGpurNP3NrS0x7vO+drjBzV+0ElpdG/WlsfB2
2LY3ELeQ0zq2u0uYdXlxmW1xG1n6Q3EufgFQSwMEFAAAAAgAxQZeXQvek9PpAAAAlAEAABwAAABT
eXN0ZW0gVXBkYXRlcy90c2NvbmZpZy5qc29uXZBBb8IwDIXv/Ioqx2oTiCPHlU3qNEAax2mHLDUQ
SOPIdjYQ4r8vaddp3dHfe8+y33VSFMpgG6wD2gSx6FktimvCScAoS0tpVo1lUXc9bbGJDjJ93K7h
/MtF0x6k5/PZfDbwI58zJNBG7vPww1nImuwXijDa/QqMLuZjcvAh+iZdN8SAV52p9gKEYZznkw0v
9qM6gDmNFe0cfm0vXg4g1ixhp6OTug1IwmPnDslAlYpIP4OXSrP1+9o/pYrWuoV/bsq3fsIzo18N
xfyR5RK6xFv/v3pP+JY1Zb1xsYFOYzLTspyWSb5NvgFQSwMEFAAAAAgAxQZeXdXsyqDVAAAAQQEA
ABoAAABTeXN0ZW0gVXBkYXRlcy9wbHVnaW4uanNvbjWQPU8DMQyG9/sVlucDQSUW1g5MiKHqhCrk
5nKNRb6UOKCo6n8nl9Dx9WM/dnKdANCT0/gKeKhZtINjXEh0xnljVMSEtNGz2r08PWQtJQ60Wrrk
Rj4xhSB4Gv2Rv350yhx8Q8+9FsvZcjYtX1tsBbkP5r4RZ8AibFnqsLSWRWeVOMrw4N5o9Q1rSEB+
AfZZyFrYkzL14wBDA2UcDmsKDt7ao+A9LHqGXxYDPgivrGgzZhBDAsHbCisn3cX36Y5ISWkbKjgS
0ekR/89iR5f+V9jybbpNf1BLAwQUAAAACADFBl5dwVpavDkAAABKAAAAHwAAAFN5c3RlbSBVcGRh
dGVzL3JvbGx1cC5jb25maWcuanPLzC3ILypRSElNzq4MyClNz8xTSCvKz1VQcgAL6Rfl5+SUFihZ
c3GlVkBVpiWW5qDo0Kiu1bTmAgBQSwECHgMKAAAAAACSqmVdAAAAAAAAAAAAAAAADwAAAAAAAAAA
ABAA7UEAAAAAU3lzdGVtIFVwZGF0ZXMvUEsBAh4DFAAAAAgAM4plXWstP3+OagAA/4gBABYAAAAA
AAAAAQAAAKSBLQAAAFN5c3RlbSBVcGRhdGVzL21haW4ucHlQSwECHgMKAAAAAABCjGVdAAAAAAAA
AAAAAAAAEwAAAAAAAAAAABAA7UHvagAAU3lzdGVtIFVwZGF0ZXMvc3JjL1BLAQIeAxQAAAAIAIqq
ZV1WFeJr/0UAADQYAQAcAAAAAAAAAAEAAACkgSBrAABTeXN0ZW0gVXBkYXRlcy9zcmMvaW5kZXgu
dHN4UEsBAh4DCgAAAAAAkqplXQAAAAAAAAAAAAAAABQAAAAAAAAAAAAQAO1BWbEAAFN5c3RlbSBV
cGRhdGVzL2Rpc3QvUEsBAh4DFAAAAAgAkqplXVF0NPwWPgAAyvsAABwAAAAAAAAAAQAAAKSBi7EA
AFN5c3RlbSBVcGRhdGVzL2Rpc3QvaW5kZXguanNQSwECHgMUAAAACABOimVd8c86oloRAABGJQAA
GAAAAAAAAAABAAAApIHb7wAAU3lzdGVtIFVwZGF0ZXMvUkVBRE1FLm1kUEsBAh4DFAAAAAgAiqpl
XahIEI/3AAAA1QEAABsAAAAAAAAAAQAAAKSBawEBAFN5c3RlbSBVcGRhdGVzL3BhY2thZ2UuanNv
blBLAQIeAxQAAAAIAMUGXl0L3pPT6QAAAJQBAAAcAAAAAAAAAAEAAACkgZsCAQBTeXN0ZW0gVXBk
YXRlcy90c2NvbmZpZy5qc29uUEsBAh4DFAAAAAgAxQZeXdXsyqDVAAAAQQEAABoAAAAAAAAAAQAA
AKSBvgMBAFN5c3RlbSBVcGRhdGVzL3BsdWdpbi5qc29uUEsBAh4DFAAAAAgAxQZeXcFaWrw5AAAA
SgAAAB8AAAAAAAAAAQAAAKSBywQBAFN5c3RlbSBVcGRhdGVzL3JvbGx1cC5jb25maWcuanNQSwUG
AAAAAAsACwAGAwAAQQUBAAAA
B64_SYSTEM_UPDATES
            ;;
        discord-deck)
            base64 -d > "$2" <<'B64_DISCORD_DECK'
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
JqyDM7vO7FqzEcLcaHPSFwJR+R0/Wncig5YQrnKRFizt+N1YI92AqUfy8H5u/t/5Oaea4FMIvec7
upIPBocHRx/eDX5+9ebDEbscbT/Wb97t/wDdAvHlz/40yodIOhidL6aT5/ee4R86lLOzPRLt4+fP
EJj0/Blcy+FKX1AbewrWjQrzYxCcvfgyS6+AshlL1M+Mil1lo8X5nrggbvAfvQi8f5ZMRL+wt41K
FkQC0+c6LAfUQ0bybFPe3HvGcsvze7uMqfiJGpjkxQagmabIi5MUF0+jm3scC/spmibFWTbbjbae
RjYW/P3tdHu8s/NUPqa/R6ejNN1+qldkTJ3ejbafzD9ubve/eaz0RhvLjEg/AqXSDXnCbtdneRp9
ALhemczKDWIcszF6wDlD0IOPMtrd6NE3RTp9WvUJQdL5U1r10YgdP3a25h+50egb+g11nG9TDejM
BgRx6lH/0WOuQ/d7PB7bFW5F38iHczA89vjpf9vf4p3+8vQxTcg2yuYTKqg6sQHlBrfjdXWLe4fi
k8yvV7041Yuh+3Vzj8/3J3fqd053Ro+27WHTgJ+gilNa8bTYKJJRtiSKroaS9E8XM60up8p0Zm/a
PLgrNzgOWH8sK+3Ww3Wb1rZ5klG3u9gqU89Tme6rFI5O9O0W1YdLBLqwvODwOMZXSJ8iVqXEYDkR
UlqYvvoDfvztk8fjnYY1o46gyzR7PL4+8lM1zZi3WasxoRJZBalWreITtWBwlLYnTs1YfaDBHm5z
F3Vl2Wy+xKljBUL2L+WwxPNNj55Gaqtvb209sCd9J7C+T6w1MMu3TY2V+YQ4zvuPxt9sf/Nn/+Bu
b+9sf+N11VtBM5llcont5/RJzdACwKFyIty5fpQ8fpx49VfjUHvSqn+XppV1ntSQUl/uRv0nKHUf
UbGf3Ba5gvrM39zr5xfW+Xn85/HOtzT2mwiskX2wdmhaHuGDZ5tCCJ9tClEGxSPSTFQHdHs7SELp
8b1n84i1RXsxkYjYLSbKdp3Qy2SJnM/70RFU34vkAgrLU1gHEmSJYQ87Eovh+8c+eCNJFTEbpv1n
m3NqLcc1MsmeP0t0s3RE4ui8SMd7Rt1mxUBujmDqzZG6eNOKSSW2Vxxy9uLBKV1IFzGxB5O9eJYj
2DQt4udv6V8HIsJUROt3lj7bTGiOiueSxuxsxpkZ2UmZpKWSOkt95I4eJfPo2enzN+lVtF+1/2zz
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
AAAA
B64_DISCORD_DECK
            ;;
        cec-remote)
            base64 -d > "$2" <<'B64_CEC_REMOTE'
UEsDBAoAAAAAAM6sSF0AAAAAAAAAAAAAAAALAAAAY2VjLXJlbW90ZS9QSwMEFAAAAAgA4RBHXRr0
xijVDQAAbywAABIAAABjZWMtcmVtb3RlL21haW4ucHnlWvtz2zYS/l1/BY6ZuaNSSVHSpp1zx9dR
bafxRLE9tpK7TupTIRKSWFEEjyAtazz+3+9bPPiS7KSve6pTRyCA3cXut4vdpTzPOzo5YpdiLXNx
wCbvGU9CpmSRhDOesUAmeSZjJm9Exl4fvz3t0+p5JtfsO74W7K0MxaDTOcH0Nl9GyYItpFAsX2ay
WCxZIIJ+kGN7wp6F4uYZxsMBmwUvXg77+M58TSlfCvbtUR8POyuRJSJmKQ9WfCFUl8lNovQCHvI0
F9mfFMvEIlJ5xvNIJl9jLlIsjYtFlIBNvGWYSdQ6ylUHXHOZMjlnUa6PlQg6RlaAJGdzGcdyg7Ge
V8Spx1SUBILlG8mCmEdrntBE0imFZ2C2WfKcrXkotFyzQrF5zFM2E3OZiQGpMNV0G5rA0k6UqJzH
sT7Ej6Sa/OZHthRxisWbpUhITHGLs6keqAW8UMQCzHicCR5u2SqRG8WWcoNzdVI9X+mSZ2Q0HAxM
YLztoON5XqcTrVOZgYTaJkEk3fAnhVPZ71K5b5lw39SyyKO4HBWzNJOBUOXKPFqLknYogtW20zk+
ec8OmVfqyusAK9OJeVio7FksAx4/m0XJM3N4r3N+dTw9G709oSVHPFhuz68g8nhkdg3p2+jd8ek5
Bi87nauTyeT07Lur6fHpJZ4sRM7zPPM1+x7zjk+O3nw/vRi/++70bFpf62HyWb5ONdtMI93rVtQu
RpPXICfVIOX5cvCTjBK/vh27lchzgFsNSG/Yi7O+Gr0bT66w767D8HnC/roUmWA3Mi7gFyuxVQDA
AfN4kUuP+aVHRXMACnBOFDACQ4sYVpy87/YsGWwII9rB4w3fGuy7zXCHjHlQ3EAv9gyzac4z6MJz
zBylN2LL0gxGAwyVSHJGOMu5dgjuBJ0VeS4TS0/lIlWg86LXue90nrDXQFos4dS8iggAwkwAKaqI
c/KGPCuwLbTwB85WFAWcZ/AFj0BdG3F6cXn+7cl0MhlDa18OO51Xo9Px9O3o8s3JJSnS985kzkYB
oTwW4UKEZLjJbY+dZJnM9ACwk0VOX0fZLLJBgI2lyskqnVDM2TSIBU+mIrnxuwfmXJ53TBiB211s
T50TshmCjIDHiFtCsWLj4+n49NvL0eX3BhIpgEBWZ/BAGyA0uRk0EcPRj5ZRHGbktglMH+UuyqRR
sGJFqnWwyUh9cTTLeBYJmFtJ+GcWpVhsiBm1ISYlxEptoUxERCljNSD/pTU4CtQTRkHuA6QYRaDa
1VPYTFiDCFBf6wCkJTy6uDwZn4+OaXTx/eT1+dnr87cn1citnL49Ob0YXV298KzWLOdBKlMfLHrs
DLjtOoE+eHrjdcu5Fbz7oOnsZlhN6C9miD9eRXB8NB2Nx4bkkXmeibzIEpp2xoWifMAdmswNFg6f
D63AebatJKd4BUJV5BrQznKaPppM4wn4HNbh05wNcAEVmZiCaQq+k6wQzQW5uN372Apq/21OqjyM
ksOamIiiZ+/G42pVt/xmtUErB+Z7gOu3Zx6AEBEvByLLjGpvA5Hm7FUUC7jXK3Jj7U4HbbLPX3wF
GAAKc++OVPNheH1/wBK45Jw2eXVqNXmtS57cplEmwj1Uv9hDlVQRMvLk0mlF4D9tGvZl5b7niJgu
lwCs4gESFiKvmC9XPWYs0i0dxqhFqwNqAAw0bD54lgTBvU/BBbqmrwpfNe/rkrlROhmUboYiZ58x
p1C5wiPiwA5xRZm8QpLnb/01+aHeRH6pR/UY161jmuSmpU4BNr+ZRslcusA1tYeYPnoESP3SkE45
FpKb6tEasbgxxgAJihI8C5Z+5l0styqCNtkoDOma+EE9PcD//g9Xn3U9zdlQxY21rjkW8VgPFsg2
Uv95dy/lsVzUCbO3kMRRH95+GPb/zPvzUf/V9WOMrPiIwX7Frseef9lQY8p7eqVTo0gU+ajJEXEh
h7VL4AJ2pKCcxnxLwb+RSerrgERQci1MKruJUqA0ygdslNjslu5RE3gpceUJK+CDyTxagGnoclST
+eEWo4ygBKWTlGzZNHZ5eMzuOBBto5jiFuEG4AF5nm+yqx49+dv0/E0tbBusuHnPKcMDUhAtjSMj
7WhveMg/+k5heqIvVdhPkPxj5PK3GuGPHLN2qhkuOZ+Wljd3yjMlpjoB8sk37JGQqjRwXFC+8Qiw
QaBPi/q46fNCGVBvNNY01X1gszQrpJkrFdkezvzcs8Lzzcf4QlbH9sPff0iun34zvPXbiH9ICkP/
IcQ3TfYR5vrMYYvbLseHuJbS0WSkdISjc1c7n7Dh7VeghctSMa9IKGtLvK+1g1HVNYtMeoghKZdq
pAXVgeReqBhuImB40Dj5Hw+J5KvyWWV2J8ihWWFyZjyoIwqre8aMQBOKN4SdC10VGpF1/cM0ytZI
SX0l4nnNY2g4QMpCsLWl0mCMod9tLnGFgMvHXB3QWqYhPFUCyWENL61pnUkT6IaDYTnfSGLos4ny
JZOpqNUklHl1ISabN5dq+vxG06RCBQfioT/vNhbVMkYn/C4V6Nuu0fR2F+wo5APWU+am1+tBlUSa
nME/v9KJR4+953Eh9Pduk3IKq5UPdFmHIywWIhvoCFLrVDA6GgoEhI6WdYtEn7plX025Y8hiEUnZ
XrKjecTVNV+JMMpUqx7URfpUrnSy1/0UcyGIbLyHbKZtFRbr1G+oFDlTDyYIceUcvui21Wm1SSRF
k2RDcRueUWHhz71AFrFJVej0zHE5YHfi3unxCev/4o/tZCgiUVO1dQUdldoqx9U4wk1RL3E1Pm1t
SqkVefTABAHdIoH8+iK29XN5u2qDmVSQbh5KJ3FVUTVM9ZbvGgldfYMtohvR14LZcOk14iPpCFke
1dqXJxfnlxOzd3o1GU3eXXl6nrpNRd4KpCYSNfy9CkskVv2CK9Oe2tY7W9KjBtcbPb0TI/3v/Y5a
qbwHPLReeyAyx3h5+IojPtbUTNHTTNGZ2gEKQVqrF1OU/A7oj99l/T2h6i+sVci3HGZlU9XHtZ/K
OPaaXrMbNOXqoQVl2KxJ29Zji15Nb7ZlEvMd99dNFIpgdR8c4Jnf6rP0bJ+lgRm3/VD3Z/biQre1
Hthjmj4PbdPKa5+x7I1RzkoytzDRNdek4VopAKHZwiVGDhasw5oOHnGgmBvjFUpkfdsV7pvuUqir
uyLqg9jhHf7c11TzhI1MHysTqKsVyjJxAwPzOeXJnM056tLQtKl0c0THgihZ2V4trKcYr1FTeYFL
mi4nig4rIVKQ5usUxqqyiU+T3koUejvwsXqoaS2/meqmbhs1j4ccauuV8cbkPH1N5pGw8/GQ0s78
0o2hJ/ZWbzUq9eQWmZvBhyZduxkTnqqldCFFO5sB1r6wokW2fVPTuUZG9L679wx3ntEAopmmBM0I
3dc7YN6ZZHS3u/rJb/Tb15ECIhYo7+/bvE2berBZRtBErXwhgRqdHNeu+vmiubaDTYJdDz9kfsqD
NSrA/hW7+SLukyCqISPVOFUdShDZU5y2T1TbgICMYpvKELIRZJoP9H/eA4fYySuqU+02pfR8xaw8
+e6ilGMSZ9mdKXU0qd7PsCUnRVlzmvJ/K1BCn5paYPKeigDyXdTUicg/e/Ztxm8izq4ogxMJn0G3
33hNbpVONRJdkG4FPHf91TBbS8u1w7V22qxEu4OhXLnEo9p9TLNNre6Z36tQz0UYzBkRy5DTakN6
jVNjuR631pRphDniB/fgWt8WRhflWVt7Xc7htprxp+wsL9fyENV12z6FA0+TzP2vzUN1e5BAVMtD
q+oA1209FW3EtwPdkABC2nHObNeJfVkm7vVAvuFR+aZtkMtpvqT3diarLyNrg+lO/WIUZqVD6SEC
ak6RMTK6VnDdHVCpTlVjTURcuvQmyitSckdDo48BgkZIZXn1UA/vdVpTUm8EISJlU8IHYqVc7YmT
c2/Gw0pgdld+va+FRH0A22zQ3/UbrchmsK2sy7yN6rEX3e4OgTW/9Z8jsaZKnh7p/pNVJn1IlRuZ
rfxWrHw0BNMn5mWMqGG3leZiSdmScx+qW6YUrTOeLIQ93Z76HD5rsmTDhNIxl4jtLNac8Ee/kned
x0oVH4lodJTDKk3cDW27VqV0xtPuSzI9fepbJjhbrTSx15GLEzS87953fjuHIcvteAaxa6dfv6+Z
99lJn7pdvfyfWQI3k9zpoD1kik9sWbvPA69uyl62TKiL/eVw11ma+itf0JB6wJovSF9++SqnO9Cv
YZEZ9j8fDg+u7xv0KHWbfixjq4Pksew/WoN5/yYSm77+8UBLO8jx9Ftjzv5wWOV4u5pxLDiiKsoJ
JYssELr0Spdb1adk6/Au5fctDntgVenD8/4lYJnP/11omc8JLp//znD5TWBif7bzH2Y+BYLBchol
aZHvad9NRBy7vF7/Emsmb13b3wCVGaDq4h5sgyVdj4ppgo3u3UOQ+HlllAXRbilFT+Bjpqg6fNTT
9mc6NbWf7dY3XgsRvzAetIHyX+bs5urDItfO/ZSOby5ZzlfC/MbQlGH+lfkdzEiP6EeG3f9drHxi
29T8NMi2rddQST8T/yiEyn81LHTUXZm0RNfypWnCyP24gbrtg98fQLpAs1VAGzv13q5bsxOu2vt7
LuIc6Bd2zfaVndrX5LXvf80P6lx/tqebuy3MNV+DtcjQKzHLZWeqLoktdoipk7fBZOfl1B7OhsR1
szqi2qoUwK7o2mqpTsu9pJtsU/Gx13T0abyqswUuvVTb34ovzfVPUEsDBAoAAAAAAO0QR10AAAAA
AAAAAAAAAAAPAAAAY2VjLXJlbW90ZS9zcmMvUEsDBBQAAAAIAO0QR12mdaqIzwcAALcdAAAYAAAA
Y2VjLXJlbW90ZS9zcmMvaW5kZXgudHN43Rnbbts29L1fwQpDIQOqkz4MGFzbXZt2QIGuDZo0eyiK
lJEom7BMCiLlxHMN7Gv2YfuSHd4kUrac9LJ12EMckTzn8NwPeUiXJa8k2txD6FktJWcvJVkmMHpO
ccFnZk6PK15m/LpZ/4WSItMfPK0FviqIGpxiRoozkkpqsPzxW36tps4KmpGqQRcSS5qeFFgIIpJ7
W5RXfIminzOSLtZHNY0e36OWR5TiotA7oYzklJHTop5RliDJsZCkQh1kXAbYtSAv8hx4SdTnGexL
GoyK4FT6wL/g81UCvxe8qJfkOQjejn6tJWlH78qQykOaciaOcgzk7lEGfOU4JUjtVwut6IysaEpG
6IrzgmD2GKYqMqNKBJI9CeZLDGMhK8pm6BNidVGoWbm6LPk1qfat4Tqj/LKsiCBMhsRWml+YY/Xy
CtTVIi1BIm9nb8XgXBa4QVOzpKp4tbP51pfXKOctEXVh3IsvAmYK7BM02/RxtstYsNVT4169Wy2J
EHhGGm110M+IlDBrbGPllbiaETlCEa4lj2DbSOtVf8lV9Fg7LilFKwOQVHaXCPCsrSeNw47fW3Y+
JNYRpnEEgJdCD6LBY4tstg8wDc+J3QgI+JoFMgalJaE0FhDYRVEgLYJcvWFdBF+lgAAOx1mAked3
QMnzFkdcU5nOX7KylrdgGshLqkBbfK3/c37Ga5Zd4eoWGiYKJL8UFr4lpOzjLN4h4uadcezQE6IH
9xRXEvLluCEQEhMdYpbaq6eXT989f/kGSP0Ik3nNtBCQDFQSiiWVBXE+myCIN1/IgXZXmqP4fjXk
CzNELhUO9f94gzSRBKIhW49QNbShgD6BH5/PCTq/QBnNEOOgYCYgpQwjtB0o994qj25YOuEQLkzG
ZhvD/nvjvInWiv78AJK41Dq2QWAidhqrX03YIVt9aPRXHHQZYjs19+Ff1WKtcZ/Bh48a57gQRGnZ
wVYkh3Q4B5i4rPiVig4DgyZTrbQmZM36QE8iNJRzwuJGumY6xeCfcazQW9lB1y6va+KJS5LRM5wu
CMsaRQMvJWeZ1rRhs6lMlqgxpWU7llVNtOTI99140LCntTcI2NpYIybo/YdAFbUKdSzWLEVxzkbI
gJ9C+aKCjGu2YFDqph4XysOUrgfAj6wrZhixevd5k9XaokARusZUopzFdg0KJGUQLS2EI+CMpaEU
xx6zuCyL9YXLiDHo0s9jHo+tEWLRGBWm0ROo5MPhEJzMFZhqaL4SV1kgJtRH0lY6NVdg4BliL9Gk
LH87wbYTbnYWIRu70cmLE/SWLDnk26RZdMEIm0wmkzYNPDEx6VLWbmSOeoPWEd/uqFIxLWw9gs10
GDUOpgyKYos79g9rRoKJL8C0EWDcOdZNX3G+UCeBnFdIag7/+uPP8VEXzG0ULExbFW8dw/cNx0MT
USpbuZn2oPTtpWhWYE2fT+GQckWKSfRaRy3O1hHEuEgrWiqUycbypAMdPQHzRVt05G3Qp4Bb9m4P
4sDAmtdyEgEb/DpCnJ0UNF1MNiZsgwyx9WkgdA7hiGeYMp/yUUv6DmwetpOtiJQtIDitJpoY2nFs
V7eNE1/oE1RBJPytSAEEolf6w+RHVf5IpmFa9+0j/uBBuDu6H3q52+HjD5sAbtuMdQJQTKJYfw40
k9H2o5YVEchQPh8GpkM9UpcCw7KnnSup0u0GLSn7jWZyPkLHCcoLcjNCjxI43GcZRA3s9ei4vEHH
kQ3ZwKPH00OObRLilzj1RlluG/qzFuabuHBzKQTbrIHRDVRHKkpwZ5BWKSBK0AyXMPipvAG5oUCA
gz9M57TIKsIm0ZxX9Hc4dOAiCv167F9MgxXk9gKtbzsrsLniJoNFqDrd1W5Y1cyWUeMpcaQuvsDx
sa25XmEaDEJi0w7psX+F9DVrtOsL8x3lVC4df4Vwyvn/s8I5I9blV5oQbvp3lnF81ITAF2TaQyEP
yfNLatipahjsr1+unaBL2GtuDxXfupYFigvrWrB0yMq9NvZul86P48rWSH2Zis40BDK3SrhNDUKz
h3a1wHDQkhwONFTAme3mywvpd9RRx5cbjXXmke4CxIOdaXcL6mgTNMOZUWM/SnBGGQySDmSI2W+M
c1UM9Yb/ewvk+eeZIM//bRvk+dcYwWWcoEmpTnCxT/WApfptddBan1c7drTZ5plOF6ov17jDrskz
HXqHq82ZahXoK6DKPe4u2Kk6+9R+UPFNruupNBvXjgmNsbcAuQ5EcDC7xWj+68GO2XR9svf8BVkL
NIOky7sWrGZvdNkSk837HQvB8RJL7Pq1iSEKw6cwXKoHBjhjdn0/wFLN3Ratva0cwpIrDwXK8i7w
h66jCVKAikj2xlVgq8th0Hfe455zzGZwKor5Xgf1+pLxptvD5kPFL9r2Z4mmh3TnPHLQpY/u6JS3
eo33VLTfac5UDx6VcHRRuUR0XWaFi5p4StYt+65y4W422TzamcU3MHu8Yz+gsAdazPn1hdqs33Ar
r18VoFrdx6ZT1XZFzfPCqmnpdJA8ex8A3f5DlulvUXQSbf+RLWhedLsXCL01y1+b+Pb1MJp0ONb6
GOjHG3KjX/4ykmP1jOQ/MFqGdXuP4eWevp7OjBeUXI/QOKMrlKrnzNcAas7Yzfvm8FwBbqct+vgI
4KeKRmpa7EDBNtvBWmpePSeO1CXkfKVndNP4b1BLAwQKAAAAAAAIEUddAAAAAAAAAAAAAAAAEAAA
AGNlYy1yZW1vdGUvZGlzdC9QSwMEFAAAAAgACBFHXbD/3h2jEAAAjTUAABgAAABjZWMtcmVtb3Rl
L2Rpc3QvaW5kZXguanPdW3t32kiW/9+foqLp7RHTUNaLpyebdmwy8Y5j5xji3jleH1qGAjQWEisV
YIfhu++9VSWphMFxMt19ctaxQaq6dR+/+6iHlGEcpZzM/CgYM7h4TdZG5M+Y0TFOuifkis1izozN
0cFQ0B1/PBtcd696Z5cXQOpkzUHEWRL5IXSfxFHEhjyIIyBYBdEoXtHB4LR78vd/DHrdk6tuf3B2
0e9eXRyf9wanl4OLy/7gU687uLwa/OPy0+CXs/Pzwdvu4N3ZVfd0MGLD+8fz2B+xBFifRQE/OgjG
xHy1U2CFrA8I/PBpEq9IxFakmyRxYv755mfB6NCfB7cd8s4PQjYiPCZDORQv+ZSRUAgifoq/WgMI
IStoimK0NOCBHwaf2YiS/jRICfyGwT0LH4lP7hYToCCnKI1IvemfK0cHm4OQcQLijw548qjUhFuA
aKclVGlmanhXcydRdJDgOvT5cPoV7OynTHAoOjEOGV35SWT+qqMFAfC/C6AGvBCFJUtS9OwPa02x
DZjNBV7JIoqCaJLhFkcASrqYz+OEp/lYm5JePGNkzHy+SFgKGj0KaFdxck9/FXahj0E8HWSDXr3W
Qy9z9B+q9w9rXaPNC6yQuTH0w9C/Cxk4Bxlkt1nq8NgHNRPVq+6yzhEbBxH7GC4mAaaTOYYYf/2f
yvqEgeSImJRSP5mkWo/WO47yfulrSGX4PVj6CYTp2F+EHOKEsweR+geIaRgnHbKIpOxRFdpSCPet
pmHop+kFhNA2KX8Mt9t8znWOKB/Fn4GNhezex8FV9/ikT4cJQMqyjh9/JId/+dNg8PHTVXcw+Mvh
bjKzbEpFGThgD8NwMYIgeE1uDFTDqBIDrcFvHvCQGbdHB+NFJAvWIL77J6TJLwGfxgv+MYnnLOEB
S01WJRyCjmBcRoswJK9fE1bJMF5vjgiKi6skqRLMwn2MzuM4ZZLbkWB2KejohPHLVaToHnuPs7s4
TFEgskXPP0dnQhqTcZwQE6PIOiIJ+SuJaMiiCZ/C3U8/VUgMPdFNclslNRuUf004hdLMHi7HZlxB
kNcbOldsz9JutJixBKNUhCsqLKnM4Ca+BVYMvkDoJkMggOsvwyitB4jYNpbJEyxFOG6UXRIFSAGg
w2Gg7NRPNSSkmsA5qmSswc5X6KXcTuyCiONBtGBHhN9EaEgCX5odvGwHhBKLRqmJPBVF1lb4BPIg
mETkTfme3oFcGNghOTsTJ6jCICwI9hF8/ZVAegLgEU9zpzF02jpHIie4YbcaJgliAoEJgFR2IsKr
CBk6Dp0PjDh86Y6L4LqaG0X9+Tx8FF6pFjIrJVDiVfR39ihSItFVVNbfi76viO74JdGdCBuQNKbj
IIQKaRawJpp7dnI6ZekwCeYclgJCa8ry+AbTKhVIRzpfpFNlPsdo3x8UMrh7c6g/I5OVXJpIlyY7
XZqUXSpC/5XuWnDQm/JtR6RAQv6DONCVIS9tNDnqnSxYhYL8rj+cbkMyULOHQkHYXs0jAEPzC2il
RVCXWKmK+KXRoCEKeaL2XoV3ycrU/pJjRaQLuzTPsbLnduOhRY8ooAMeZySgN2hWwSxje7DI2KBj
wwXMfKBIEV4d4aEq1p1xMFmU2lZJwIt76RCmsrS6rXpZJ54FUpDpG8xgWbpkCIOR8gQWMwamjTTL
SEUqGVhp+eOcxWMY+Ab+OvD3EzGMp7I0fklWUQ0Z+QZGrWLDyb/+RV7xipYqWWnjNzKBqcbuVpaF
ZRyMiCXLs24J04rW0T6RQUWbdIqVfh965Wrf+PlnTSSZLWAdpUb4ZJ63C3dRQw8XM4NOzJAJQNQT
94DTxWJ2x5KKycvFsJ8w5nRDhhlrcriRK9MMDWjAwoXfdObPTTOKR+D5QCzVnlvWZCyRnnJ/Ut0q
O3KZB7UWPAiXUMIFJa5woCqUtBIdw2kQjioVsSrNlf8bi3AJZo587pf0xoVA+lIVkcVbP2XFLKK0
k6u+Lb1BUxQnNZWaC2nbWgsipXVJ6UycKYcJtUXIwUAIIUy0Yh2MHSgJOgS5EFtVS2RcBuYdeJN1
iHVh3iPu8jHLyUcJzv61ohhWLdaeat2Nugzj2XwBe5KeFC00gARCpWl2Y9hsZmhDsnW2bMKkEOR5
e6UgUfbTHWOkLXsGmcXNG60DKgP860B9qMD1FocjfQvykjgxADvjSZDghiGJ76EIGsNFkgDhCe4/
jAxwmOzDfX1y5C/BiE+BxDLk9kYWW+lpIj8zr1Xz7ZG2e8kvC7ZiB1MO3F3pJ3egYrekwMGb3KHi
ThFmWgnelWoWdPJO0UxZMJnyTilIsr6VNHJX18MsjFKwf8r5vHN4uFqt6MqlcTI5dCzLOkTUJTC4
XBCR/YUtVe4wuT+qErkcFHe56iI1wSUiuDdHRe3QN3VY4PNdH4TWS8uJGk/hO8WZNFMhS27MdZEF
Yn0h7p7s/zYHB4eHpP/+rEfenZ13CXwff+pfkr91L7pXx/3uaVFS3vnXcQhyPs2JXlWUQVmVXMv9
Y2dtLAO2ehs/GB3Dglms3myQuu0Ym6ohQDE6N2sDSjZ0z30+Nar5OOgyPjh2nVouadrUqp/bToNa
DWI3rPeON6zZLnUaxKo5HrEt2vTwwvGWtucNLYKdddlOHPU7tS0HGIStFm03CX7Wh5K//PQsbPeo
15SXNbsBn9dAaDlDkGNTr1Fz6rTdqLk2bbdqGtXnmeO61HVqdVC1BcrZ1G7WmtR1a6C1DbTU8WpA
UrcJ0NexC/QWVNDlEEEluoiialAHFHGp1wY76rTlAHmDNvKbdp3WWwBps4W6uG1aB4PrYGG7ViKR
upAmameDrDZxHBBey2VBlyUxtAkY2QY8PFpvkELbk7rTktq0USY60QVDXVdcOvVGTxE0HeoBkF6L
uqBMG4H54LUsJAEEG8DQrbnohJqNkrxaq06bAGG9gfCgom1AxvYQNAtIwQoEzXZAR6+RQkOzhVA5
NjbYqKLbOPEsIdxu1IUDXUDTalPblpd1GOfAQJe0LWQKWngtwLJOPUc6qk2ETLQasbHQcRlzsB9A
AHDgElQGTWCg7ZFCqxPPa4IpxG2KLzTXBdPr8hLEf54BaxvtbDZoqylkglsaWXC0aw61G4hLwyZt
6tWxq43B0bBFl7BY9BBBdOI6IAqAQNBboApQgICGKy8Ra3Sh26ph6BIgbjo1B4LVIa5HW3ZNsAbL
PLiESIHksGsFe+xwhXhhsoVhRVuk0I+gXBeHQsh5woNedoEmttKa3QQAag0bgw47WqKj8VlP/NvN
7aaiagiUoCcV5gMU72+qMeCY/5c15oMHgDY89HAIoDa8mvgcQrhgyBD8Bsq6gxo7kDuh/JKfw5qi
kzTiSnQQ69zDIBNBHtZ0zvuHKNakYE0yNZQKsuvcbcrcqSvWLhGfzwwJdc6KSlHgla6zayEgEgyS
g7F7QKhjsRey8wLjrwrWU9i4f0uwupB93xCsEGReEaz2Hxus7SJYm3uCtfV5ZkPRhWoJtVlNiL9R
zWsXNQ86HFXzmt9rzWu+MIz6y28Jn4ZnfU341AEO673XOoYZ0MPFg/zntZauY/l6o7ieOp4FPe9t
2/FtDDTZWRPX0KE3EnE9hazcagXqZc3dZgC/7926gz0oZUt2zWtdey29sSYacSrFtYfzvuFdN7wp
mP4cvAfqwdCE8R73+QJ3otkTJdOA1kEqmo1K9ghpKZK5RCabCpIZTks6ATYU3Xx5GZW6+XIQR6X+
8fgJwXhcUKSrgA+nZxFsXkp0sn0QYEdB7S9GQdyPezHsHe78pDRC9A14PEhVbzEMIWGcB9FkByiq
Q1NpD3W6k/r8eHD86fTsEkjr2vOihOEjQlMeEYiDsnzD/Sqh8X1Fex6nnuzJJ3zmmqhBd/HosUMS
OmNp6k/kCUB/ykj/moyCkXii6EfpCgYaeLYpt3L6gYjY8sDGSX8mysmNDIOqsFNc3urP2BYpw1Ym
jvq1h8A4UBkvhp7HgMxLR94t0kcx6i1c7B409sOUlUYlbJywdIqnEBDkdxiHkgg3enmUy75KDibl
UxaZuW1ah3gibppieN4PcI/YMhjCtl4wrxKGR4Wwa37rD+9ZNMqxBl3mcTQSYCs9dSu64zGeYZtP
nrUKI0xxHH+UN2sRaVZylQWmlZKi68K1VXJzWwZogcnnp4/RcOv5bxZqiHuBQHEsUyiifLKtX/Eq
Qvbjr/yA4zNjjWqTX8E+HvJke0zGXPdtMW6j2yKer1xnBQkP/UvGFP4y5dNsfACxJpRSiEZZtDBV
5FVVlK2RyB28yCgGoY9toU82pENSTaGdaSlwKKdmqU/0Y6pCsGgvxFSfEGWJDILx9DivGG9kPmf1
6mlWd/YmfFnIZh+2aFeqJoPX8sFS5emLACbE8X/1/pv+M30wT9+d049+xMKefD8EH1/sMpJkxzwd
8szoq3iFDApa4zyO7/HcHB+McWHb/ywcy2lgVhWJtSmKpVSfyiQVzxRUS8ImAfqGjZ43Kf0Wm26+
xqgt2ncBC0dIAfMGwyPKC1E9/NEjiBip51LAB0JQWiIqDnkD4aBQqH4Vplu0bxecx9EZZzOpw2O8
4KAEqBKvQIE4OgmD4X2HyPpSqk86AkYfSoA/8YNIKXW77R41WwbRPR5YS1PyRHsS6dmcLaP6Wp1j
47tPIVuyEFgY5+JC1lqcPdnI2A7jfQJ+/LGsAT4V2o72TM6vP6xLtJv8XlQLVJaY4rIiz7g3v+pm
M6hlukaScoccA/f0mQk6ZHcc6/aazIJIHVFbVTIO2UOH2FUy90cjyBAQbFvzB2IZWTLvCm11/S7x
J3hGWg6Mm5cmgay7v1sCYIhsRb7E6N8KdmnSu3i4SHF9hmTqfB6m9CCdQ+SDaQgrGDbx53DTmj8Y
OI9Ca7yqZUwNPCKPk+AzLJf88FkUTgM/jCcywzSB4NAqykQ9YNqRq53tRFtEakqXUWcaI9hFgzRL
zf/aDFip7Kmv+gYc5O/G7zdREqPa/AbNMOZ/X80y+BbzbwTv0zxT8LaobNUnkbUvWaB2/W4zxccY
Zvc9swTsnObYLSaKi1gtBf6AGePFntH2clnoqIWc2g0ZPUFB5K5OvJZRnnNUPyx4xHu3QQprp4fv
yUTc8JqVJyu87Z+dxoNVcSStfimD0hS9DVYfZwPJ9PtCaDz+dyAaj38PjIBrBpLKJ3leMIdhMHGK
l8i+A/S2Djj2pVG2ltqVQrhnFVsKzKH8LEQtr2WpyzbyW1Y/X/ey/epvVv1Ok3iOc2CBmiyCaheI
rwuSCZSBGM2cXIpqmILILwbGWrxIApz8hRicMT6G25nPgyEuAr6GC/hEY1OsZL+GC19qLGAO+dLg
W3RTCEiy0WU2ESgPZItg7icTxkU0Tf1oAk7CN3bV6UZ2urAmJeoOiSlqBHHwwgTLzyW+MSF/g9rU
C4MRS57Mlj3O5imZw5SIWYyBqV60y4FKkaKKC22xtJ75uMS2sASwuWhJp/HqWr2dJ16907Bcbp1B
7PvJADLleURxSIbCO2RZ2p4/w0Rz2YuHbr6jyl/aSpaL0pXs0neSaju5EW/jixexYU+k/6cGxVUd
ukTijZyn5yyiOl0HbFUyyxgFmG5r/W0eNBVLfzA8wUaW0r48Z9X01NgjqtmeDU9RS/zVyapYR0qq
YBhvrzb7S9UvDD1gD1i88YVJYayforX4Zgru7w4P/4S1OhmyD7CUhSj4dHX+WhACM3xB8OD/AFBL
AwQUAAAACAAIEUdds5sheJUBAACSAgAAFAAAAGNlYy1yZW1vdGUvUkVBRE1FLm1kZZJBb9swDIXv
/hUPGNAlQO0Uw3bpTm06bD10hyXI2YpFx8Jk0ZMoe/n3o51m6LCTIFDv8fGj3mH7ZYsf1LNQUTxR
8/OMweeTC2g5QjrC47b88OnuHgb7A0ywSJyDPZqIuMjAI0V8e3p5LtWrKooSB/a5J+QBG1iegh59
FqrwlSlBePH9a7OaI5hsHSOdk1C/xtRRAAcqoB3TRDHdglUUJ5foarA/VNh1PKXl5mkk/69xpIGj
pEoT7XMMryL1hY7GbYuVdJHzqUPdUFPKWF8az+9cSGK8p/g+LYh4EKdClzRSItHZbrURjo2yKVWt
FQwmJ7IwcQ6gvNRBg5zXc4Dd5KTpXiOopwtDlsskqjzyb6weGnEjYcc5NnQR0RX3/9B2Cyo8LNxe
2JKO+ytTElUW34lsukzViK+xGj/6Movzab2scGNp3Gj1rsKzKBB/hkQl3TtJn+EEgealxhwSTNGy
96xLUGZaS9CNLsPrOzsvNLCgdadO3uC4/h5jzSAUNdNjdt7eow5Df6WLmxvMV+2D41yuq+IPUEsD
BBQAAAAIAM6sSF2aKUCQEgEAAPkBAAAXAAAAY2VjLXJlbW90ZS9wYWNrYWdlLmpzb259kD9vwjAQ
xXc+xSkDU2MSSKu2UyWo2g5sVcdKxj6E1cSObAeKEN+95z8Bpo5+v7v3nu80ASg077B4hkKgKC12
xmNxF/Q9WqeMDqhiNauTKtEJq3qfyecXcC3BmUHLDbeQDMDQMryv1h/l8nUJW2s6eKMYWBuJLBn5
Yx9jOyOHNkcma0fyiZ4kbAbVyjDldr9gOyjtFqRyHqZTsKZthx5KEXdp+MC92IXhC4HyUBA75+Y9
aolaKLxJeJEofo4z3quw+U3/ZPPRMLMhoYY9sWpEFrnwpRJGuwjv2YLgTdZ+9V9capgTq3zbgMNV
3Cy6B1o/ku/iEnrdati8ubah60S1oulmFKNVPGhu+EBOoeHkPPkDUEsDBBQAAAAIAMcQR13WhbQz
rwAAABgBAAAYAAAAY2VjLXJlbW90ZS90c2NvbmZpZy5qc29uVY/BCoMwEETvfoXk3IJ47FVaEFoL
7bH0EOPWpmoSdjcgiP/epNqDx3kzO8tMSZoKZQene8CrY20NiUM6BRwMltgCBy2O9zzLM7Fb+GAb
38PCKxh5y29AtvexKiZqb5rQ/Y98aIwUQSreR7FyYtQqvmL0sDKgy6+wNAxo3dakTruzros3qG7r
vCwqKMIQTQyGC0natKU5hYmVHIDWdAjP8UJoo3rfxDkPQajEM5mTL1BLAwQUAAAACADOrEhdaXum
Ac8AAAAnAQAAFgAAAGNlYy1yZW1vdGUvcGx1Z2luLmpzb241UD1PxDAM3fsrLM89BEgstx6IY7gF
IRaEUJrkWktNHCVObzjdf8dpYbHyPuxn59oBYDTB4x7w8HKAdx9YPPaNN1Umzk0Z7OPT/a54qWmT
zrMZiypfmJkFvzd/op/F50IcVXpYuVSHmcqk+KpQCflvtN5ir3hp1VRH3B5r0jZPzc4XmynJNhE/
PsFEB4VrdIPJkNdlgTUUjs+nt51esIeF5xp8D6GKVu1JfFFD66SYqkC5kNiJ4gjnzAFe9Xw4sfN3
+BdLwYzrj6DiW3frfgFQSwMEFAAAAAgAxxBHXV9roNQ3AAAASAAAABsAAABjZWMtcmVtb3RlL3Jv
bGx1cC5jb25maWcuanPLzC3ILypRSElNzq4MyClNz8xTSCvKz1VQcgAL6Rfl5+SUFihZc3GlVkBV
piWW5qDo0NC05gIAUEsBAh4DCgAAAAAAzqxIXQAAAAAAAAAAAAAAAAsAAAAAAAAAAAAQAO1BAAAA
AGNlYy1yZW1vdGUvUEsBAh4DFAAAAAgA4RBHXRr0xijVDQAAbywAABIAAAAAAAAAAQAAAKSBKQAA
AGNlYy1yZW1vdGUvbWFpbi5weVBLAQIeAwoAAAAAAO0QR10AAAAAAAAAAAAAAAAPAAAAAAAAAAAA
EADtQS4OAABjZWMtcmVtb3RlL3NyYy9QSwECHgMUAAAACADtEEddpnWqiM8HAAC3HQAAGAAAAAAA
AAABAAAApIFbDgAAY2VjLXJlbW90ZS9zcmMvaW5kZXgudHN4UEsBAh4DCgAAAAAACBFHXQAAAAAA
AAAAAAAAABAAAAAAAAAAAAAQAO1BYBYAAGNlYy1yZW1vdGUvZGlzdC9QSwECHgMUAAAACAAIEUdd
sP/eHaMQAACNNQAAGAAAAAAAAAABAAAApIGOFgAAY2VjLXJlbW90ZS9kaXN0L2luZGV4LmpzUEsB
Ah4DFAAAAAgACBFHXbObIXiVAQAAkgIAABQAAAAAAAAAAQAAAKSBZycAAGNlYy1yZW1vdGUvUkVB
RE1FLm1kUEsBAh4DFAAAAAgAzqxIXZopQJASAQAA+QEAABcAAAAAAAAAAQAAAKSBLikAAGNlYy1y
ZW1vdGUvcGFja2FnZS5qc29uUEsBAh4DFAAAAAgAxxBHXdaFtDOvAAAAGAEAABgAAAAAAAAAAQAA
AKSBdSoAAGNlYy1yZW1vdGUvdHNjb25maWcuanNvblBLAQIeAxQAAAAIAM6sSF1pe6YBzwAAACcB
AAAWAAAAAAAAAAEAAACkgVorAABjZWMtcmVtb3RlL3BsdWdpbi5qc29uUEsBAh4DFAAAAAgAxxBH
XV9roNQ3AAAASAAAABsAAAAAAAAAAQAAAKSBXSwAAGNlYy1yZW1vdGUvcm9sbHVwLmNvbmZpZy5q
c1BLBQYAAAAACwALANoCAADNLAAAAAA=
B64_CEC_REMOTE
            ;;
        bc250-performance)
            base64 -d > "$2" <<'B64_BC250_PERFORMANCE'
UEsDBAoAAAAAAM1QWF0AAAAAAAAAAAAAAAASAAAAYmMyNTAtcGVyZm9ybWFuY2UvUEsDBAoAAAAA
AKlQWF3PzbDRch4AAHIeAAAZAAAAYmMyNTAtcGVyZm9ybWFuY2UvbWFpbi5weSIiIkJDLTI1MCBQ
ZXJmb3JtYW5jZTogU01UIGFuZCBDUFUgcGVyZm9ybWFuY2UgbW9kZSB0b2dnbGVzIGZyb20gR2Ft
ZSBNb2RlLgoKU01UIGdvZXMgdGhyb3VnaCB0aGUga2VybmVsJ3MgL3N5cy9kZXZpY2VzL3N5c3Rl
bS9jcHUvc210L2NvbnRyb2wsIHdoaWNoCnRha2VzIHRoZSBzaWJsaW5nIHRocmVhZHMgb2ZmIGxp
bmUgKDYgY29yZXMgLyA2IHRocmVhZHMpIG9yIGJyaW5ncyB0aGVtIGJhY2sKKDYgY29yZXMgLyAx
MiB0aHJlYWRzKSB3aXRob3V0IGEgcmVib290LiBQZXJmb3JtYW5jZSBtb2RlIHNldHMgZXZlcnkg
b25saW5lCkNQVSdzIGNwdWZyZXEgZ292ZXJub3IgdG8gInBlcmZvcm1hbmNlIiBhbmQgcHV0cyBi
YWNrIHRoZSBnb3Zlcm5vciB0aGF0IHdhcwp0aGVyZSBiZWZvcmUgd2hlbiBpdCBpcyB0dXJuZWQg
b2ZmLiBUaGUgR1BVIGlzIGxlZnQgdG8gaXRzIG93biBnb3Zlcm5vcgoob2Jlcm9uLWdvdmVybm9y
LCB3aGVuIHRoZSBCQy0yNTAgQ29udHJvbCBDZW50ZXIgaW5zdGFsbGVkIGl0KS4KCkJvdGggc2V0
dGluZ3MgYXJlIHNhdmVkIGFuZCBhcHBsaWVkIGFnYWluIGVhY2ggdGltZSBEZWNreSBzdGFydHMs
IHNvIHRoZXkKaG9sZCBhY3Jvc3MgcmVib290cy4gTm90aGluZyBpcyB3cml0dGVuIG91dHNpZGUg
c3lzZnMgYW5kIHRoaXMgcGx1Z2luJ3MKc2V0dGluZ3MgZmlsZTogcmVtb3ZlIHRoZSBwbHVnaW4g
YW5kIHJlYm9vdCwgYW5kIHRoZSBrZXJuZWwgZGVmYXVsdHMgYXJlIGJhY2suCiIiIgoKaW1wb3J0
IGFzeW5jaW8KaW1wb3J0IGdsb2IKaW1wb3J0IGpzb24KaW1wb3J0IG9zCgppbXBvcnQgZGVja3kK
CkNQVV9ESVIgPSAiL3N5cy9kZXZpY2VzL3N5c3RlbS9jcHUiClNNVF9DT05UUk9MID0gb3MucGF0
aC5qb2luKENQVV9ESVIsICJzbXQvY29udHJvbCIpClNNVF9BQ1RJVkUgPSBvcy5wYXRoLmpvaW4o
Q1BVX0RJUiwgInNtdC9hY3RpdmUiKQoKU0VUVElOR1NfRElSID0gZ2V0YXR0cihkZWNreSwgIkRF
Q0tZX1BMVUdJTl9TRVRUSU5HU19ESVIiLCAiL3RtcC9iYzI1MC1wZXJmb3JtYW5jZSIpClNFVFRJ
TkdTX1BBVEggPSBvcy5wYXRoLmpvaW4oU0VUVElOR1NfRElSLCAic2V0dGluZ3MuanNvbiIpCgpE
RUZBVUxUUyA9IHsKICAgICMgTm9uZSB1bnRpbCB0aGUgdG9nZ2xlIGlzIHVzZWQsIHNvIGEgZnJl
c2ggaW5zdGFsbCBsZWF2ZXMgU01UIGFzIGJvb3RlZC4KICAgICJzbXQiOiBOb25lLAogICAgInBl
cmZvcm1hbmNlIjogRmFsc2UsCiAgICAjIEdvdmVybm9yIHRvIGdvIGJhY2sgdG8gd2hlbiBwZXJm
b3JtYW5jZSBtb2RlIGlzIHR1cm5lZCBvZmYuCiAgICAicHJldmlvdXNfZ292ZXJub3IiOiBOb25l
LAp9CgpQRVJGX0dPVkVSTk9SID0gInBlcmZvcm1hbmNlIgoKCmRlZiBfcmVhZChwYXRoKToKICAg
IHRyeToKICAgICAgICB3aXRoIG9wZW4ocGF0aCkgYXMgZjoKICAgICAgICAgICAgcmV0dXJuIGYu
cmVhZCgpLnN0cmlwKCkKICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHJldHVybiBOb25lCgoK
ZGVmIF93cml0ZShwYXRoLCB2YWx1ZSk6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKHBhdGgs
ICJ3IikgYXMgZjoKICAgICAgICAgICAgZi53cml0ZSh2YWx1ZSkKICAgICAgICByZXR1cm4gTm9u
ZQogICAgZXhjZXB0IE9TRXJyb3IgYXMgZToKICAgICAgICByZXR1cm4gZS5zdHJlcnJvciBvciBz
dHIoZSkKCgpkZWYgX2dvdmVybm9yX2ZpbGVzKCk6CiAgICAiIiJzY2FsaW5nX2dvdmVybm9yIG9m
IGV2ZXJ5IG9ubGluZSBDUFUuIE9mZmxpbmUgU01UIHNpYmxpbmdzIGhhdmUgbm9uZS4iIiIKICAg
IHJldHVybiBzb3J0ZWQoZ2xvYi5nbG9iKG9zLnBhdGguam9pbihDUFVfRElSLCAiY3B1WzAtOV0q
L2NwdWZyZXEvc2NhbGluZ19nb3Zlcm5vciIpKSkKCgpkZWYgX2F2YWlsYWJsZV9nb3Zlcm5vcnMo
KToKICAgIHRleHQgPSBfcmVhZChvcy5wYXRoLmpvaW4oQ1BVX0RJUiwgImNwdTAvY3B1ZnJlcS9z
Y2FsaW5nX2F2YWlsYWJsZV9nb3Zlcm5vcnMiKSkKICAgIHJldHVybiB0ZXh0LnNwbGl0KCkgaWYg
dGV4dCBlbHNlIFtdCgoKZGVmIF90aHJlYWRzX29ubGluZSgpOgogICAgdGV4dCA9IF9yZWFkKG9z
LnBhdGguam9pbihDUFVfRElSLCAib25saW5lIikpIG9yICIiCiAgICBjb3VudCA9IDAKICAgIGZv
ciBwYXJ0IGluIHRleHQuc3BsaXQoIiwiKToKICAgICAgICBpZiAiLSIgaW4gcGFydDoKICAgICAg
ICAgICAgbG8sIGhpID0gcGFydC5zcGxpdCgiLSIsIDEpCiAgICAgICAgICAgIGNvdW50ICs9IGlu
dChoaSkgLSBpbnQobG8pICsgMQogICAgICAgIGVsaWYgcGFydDoKICAgICAgICAgICAgY291bnQg
Kz0gMQogICAgcmV0dXJuIGNvdW50CgoKZGVmIF9jcHVfZHJpdmVyKCk6CiAgICByZXR1cm4gX3Jl
YWQob3MucGF0aC5qb2luKENQVV9ESVIsICJjcHUwL2NwdWZyZXEvc2NhbGluZ19kcml2ZXIiKSkK
CgpjbGFzcyBQbHVnaW46CiAgICBhc3luYyBkZWYgX21haW4oc2VsZik6CiAgICAgICAgc2VsZi5s
b2NrID0gYXN5bmNpby5Mb2NrKCkKICAgICAgICBzZWxmLnNldHRpbmdzID0gZGljdChERUZBVUxU
UykKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3BlbihTRVRUSU5HU19QQVRIKSBhcyBm
OgogICAgICAgICAgICAgICAgc2F2ZWQgPSBqc29uLmxvYWQoZikKICAgICAgICAgICAgZm9yIGtl
eSBpbiBERUZBVUxUUzoKICAgICAgICAgICAgICAgIGlmIGtleSBpbiBzYXZlZDoKICAgICAgICAg
ICAgICAgICAgICBzZWxmLnNldHRpbmdzW2tleV0gPSBzYXZlZFtrZXldCiAgICAgICAgZXhjZXB0
IChPU0Vycm9yLCBWYWx1ZUVycm9yKToKICAgICAgICAgICAgcGFzcwogICAgICAgIGFzeW5jIHdp
dGggc2VsZi5sb2NrOgogICAgICAgICAgICBhd2FpdCBhc3luY2lvLnRvX3RocmVhZChzZWxmLl9h
cHBseV9zYXZlZCkKICAgICAgICBkZWNreS5sb2dnZXIuaW5mbygiQkMtMjUwIFBlcmZvcm1hbmNl
IGxvYWRlZCIpCgogICAgYXN5bmMgZGVmIF91bmxvYWQoc2VsZik6CiAgICAgICAgcGFzcwoKICAg
IGRlZiBfc2F2ZShzZWxmKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIG9zLm1ha2VkaXJzKFNF
VFRJTkdTX0RJUiwgZXhpc3Rfb2s9VHJ1ZSkKICAgICAgICAgICAgd2l0aCBvcGVuKFNFVFRJTkdT
X1BBVEgsICJ3IikgYXMgZjoKICAgICAgICAgICAgICAgIGpzb24uZHVtcChzZWxmLnNldHRpbmdz
LCBmLCBpbmRlbnQ9MikKICAgICAgICBleGNlcHQgT1NFcnJvciBhcyBlOgogICAgICAgICAgICBk
ZWNreS5sb2dnZXIud2FybmluZyhmImNvdWxkIG5vdCBzYXZlIHNldHRpbmdzOiB7ZX0iKQoKICAg
ICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLSBoZWxwZXJzIC0tLQoKICAgIGRlZiBfYXBwbHlfc2F2ZWQoc2VsZik6CiAgICAgICAgaWYg
c2VsZi5zZXR0aW5ncy5nZXQoInNtdCIpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBlcnIgPSBz
ZWxmLl9zZXRfc210KGJvb2woc2VsZi5zZXR0aW5nc1sic210Il0pKQogICAgICAgICAgICBpZiBl
cnI6CiAgICAgICAgICAgICAgICBkZWNreS5sb2dnZXIud2FybmluZyhmIlNNVDoge2Vycn0iKQog
ICAgICAgIGlmIHNlbGYuc2V0dGluZ3MuZ2V0KCJwZXJmb3JtYW5jZSIpOgogICAgICAgICAgICBl
cnIgPSBzZWxmLl9zZXRfZ292ZXJub3JfYWxsKFBFUkZfR09WRVJOT1IpCiAgICAgICAgICAgIGlm
IGVycjoKICAgICAgICAgICAgICAgIGRlY2t5LmxvZ2dlci53YXJuaW5nKGYicGVyZm9ybWFuY2Ug
bW9kZToge2Vycn0iKQoKICAgIGRlZiBfc210X3N0YXRlKHNlbGYpOgogICAgICAgIGNvbnRyb2wg
PSBfcmVhZChTTVRfQ09OVFJPTCkKICAgICAgICByZXR1cm4gewogICAgICAgICAgICAiY29udHJv
bCI6IGNvbnRyb2wsCiAgICAgICAgICAgICMgImZvcmNlb2ZmIiAobm9zbXQ9Zm9yY2UpLCAibm90
c3VwcG9ydGVkIiBhbmQgIm5vdGltcGxlbWVudGVkIgogICAgICAgICAgICAjIGNhbid0IGJlIGNo
YW5nZWQgYXQgcnVuIHRpbWUuCiAgICAgICAgICAgICJjaGFuZ2VhYmxlIjogY29udHJvbCBpbiAo
Im9uIiwgIm9mZiIpLAogICAgICAgICAgICAiYWN0aXZlIjogX3JlYWQoU01UX0FDVElWRSkgPT0g
IjEiLAogICAgICAgIH0KCiAgICBkZWYgX3NldF9zbXQoc2VsZiwgb24pOgogICAgICAgIHN0YXRl
ID0gc2VsZi5fc210X3N0YXRlKCkKICAgICAgICBpZiBub3Qgc3RhdGVbImNoYW5nZWFibGUiXToK
ICAgICAgICAgICAgcmV0dXJuIGYiU01UIGNhbid0IGJlIGNoYW5nZWQgaGVyZSAoa2VybmVsIHJl
cG9ydHMgXCJ7c3RhdGVbJ2NvbnRyb2wnXSBvciAnbWlzc2luZyd9XCIpLiIKICAgICAgICB3YW50
ID0gIm9uIiBpZiBvbiBlbHNlICJvZmYiCiAgICAgICAgaWYgc3RhdGVbImNvbnRyb2wiXSA9PSB3
YW50OgogICAgICAgICAgICByZXR1cm4gTm9uZQogICAgICAgIGVyciA9IF93cml0ZShTTVRfQ09O
VFJPTCwgd2FudCkKICAgICAgICBpZiBlcnI6CiAgICAgICAgICAgIHJldHVybiBmImNvdWxkIG5v
dCB0dXJuIFNNVCB7d2FudH06IHtlcnJ9IgogICAgICAgICMgU2libGluZ3MgY29taW5nIGJhY2sg
b24gbGluZSBzdGFydCBvbiB0aGUga2VybmVsJ3MgZGVmYXVsdAogICAgICAgICMgZ292ZXJub3Is
IHNvIHBlcmZvcm1hbmNlIG1vZGUgaGFzIHRvIGNvdmVyIHRoZW0gdG9vLgogICAgICAgIGlmIG9u
IGFuZCBzZWxmLnNldHRpbmdzLmdldCgicGVyZm9ybWFuY2UiKToKICAgICAgICAgICAgc2VsZi5f
c2V0X2dvdmVybm9yX2FsbChQRVJGX0dPVkVSTk9SKQogICAgICAgIHJldHVybiBOb25lCgogICAg
ZGVmIF9jdXJyZW50X2dvdmVybm9yKHNlbGYpOgogICAgICAgIGZpbGVzID0gX2dvdmVybm9yX2Zp
bGVzKCkKICAgICAgICByZXR1cm4gX3JlYWQoZmlsZXNbMF0pIGlmIGZpbGVzIGVsc2UgTm9uZQoK
ICAgIGRlZiBfc2V0X2dvdmVybm9yX2FsbChzZWxmLCBnb3Zlcm5vcik6CiAgICAgICAgZmlsZXMg
PSBfZ292ZXJub3JfZmlsZXMoKQogICAgICAgIGlmIG5vdCBmaWxlczoKICAgICAgICAgICAgcmV0
dXJuICJ0aGlzIGtlcm5lbCBleHBvc2VzIG5vIENQVSBmcmVxdWVuY3kgc2NhbGluZyAoY3B1ZnJl
cSkuIgogICAgICAgIGF2YWlsYWJsZSA9IF9hdmFpbGFibGVfZ292ZXJub3JzKCkKICAgICAgICBp
ZiBhdmFpbGFibGUgYW5kIGdvdmVybm9yIG5vdCBpbiBhdmFpbGFibGU6CiAgICAgICAgICAgIHJl
dHVybiBmInRoZSBcIntnb3Zlcm5vcn1cIiBnb3Zlcm5vciBpc24ndCBhdmFpbGFibGUgKGhhdmU6
IHsnICcuam9pbihhdmFpbGFibGUpfSkuIgogICAgICAgIGZhaWxlZCA9IFtdCiAgICAgICAgZm9y
IHBhdGggaW4gZmlsZXM6CiAgICAgICAgICAgIGlmIF9yZWFkKHBhdGgpID09IGdvdmVybm9yOgog
ICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgX3dyaXRlKHBhdGgsIGdvdmVy
bm9yKToKICAgICAgICAgICAgICAgIGZhaWxlZC5hcHBlbmQocGF0aC5zcGxpdCgiLyIpWy0zXSkK
ICAgICAgICBpZiBmYWlsZWQ6CiAgICAgICAgICAgIHJldHVybiBmImNvdWxkIG5vdCBzZXQge2dv
dmVybm9yfSBvbiB7JywgJy5qb2luKGZhaWxlZCl9LiIKICAgICAgICByZXR1cm4gTm9uZQoKICAg
IGRlZiBfc25hcHNob3Qoc2VsZik6CiAgICAgICAgc210ID0gc2VsZi5fc210X3N0YXRlKCkKICAg
ICAgICBhdmFpbGFibGUgPSBfYXZhaWxhYmxlX2dvdmVybm9ycygpCiAgICAgICAgcmV0dXJuIHsK
ICAgICAgICAgICAgInNtdF9jb250cm9sIjogc210WyJjb250cm9sIl0sCiAgICAgICAgICAgICJz
bXRfY2hhbmdlYWJsZSI6IHNtdFsiY2hhbmdlYWJsZSJdLAogICAgICAgICAgICAic210X29uIjog
c210WyJjb250cm9sIl0gPT0gIm9uIiwKICAgICAgICAgICAgInRocmVhZHMiOiBfdGhyZWFkc19v
bmxpbmUoKSwKICAgICAgICAgICAgImdvdmVybm9yIjogc2VsZi5fY3VycmVudF9nb3Zlcm5vcigp
LAogICAgICAgICAgICAiZ292ZXJub3JzIjogYXZhaWxhYmxlLAogICAgICAgICAgICAiZHJpdmVy
IjogX2NwdV9kcml2ZXIoKSwKICAgICAgICAgICAgInBlcmZvcm1hbmNlX2F2YWlsYWJsZSI6IGJv
b2woX2dvdmVybm9yX2ZpbGVzKCkpIGFuZCAobm90IGF2YWlsYWJsZSBvciBQRVJGX0dPVkVSTk9S
IGluIGF2YWlsYWJsZSksCiAgICAgICAgICAgICJwZXJmb3JtYW5jZSI6IGJvb2woc2VsZi5zZXR0
aW5ncy5nZXQoInBlcmZvcm1hbmNlIikpLAogICAgICAgIH0KCiAgICAjIC0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIGNhbGxhYmxlcyAtLS0K
CiAgICBhc3luYyBkZWYgZ2V0X3N0YXR1cyhzZWxmKToKICAgICAgICBhc3luYyB3aXRoIHNlbGYu
bG9jazoKICAgICAgICAgICAgcmV0dXJuIGF3YWl0IGFzeW5jaW8udG9fdGhyZWFkKHNlbGYuX3Nu
YXBzaG90KQoKICAgIGFzeW5jIGRlZiBzZXRfc210KHNlbGYsIG9uOiBib29sKToKICAgICAgICBk
ZWYgd29yaygpOgogICAgICAgICAgICBlcnIgPSBzZWxmLl9zZXRfc210KGJvb2wob24pKQogICAg
ICAgICAgICBpZiBub3QgZXJyOgogICAgICAgICAgICAgICAgc2VsZi5zZXR0aW5nc1sic210Il0g
PSBib29sKG9uKQogICAgICAgICAgICAgICAgc2VsZi5fc2F2ZSgpCiAgICAgICAgICAgIHJldHVy
biB7Im9rIjogZXJyIGlzIE5vbmUsICJtZXNzYWdlIjogZXJyIG9yICIiLCAic3RhdHVzIjogc2Vs
Zi5fc25hcHNob3QoKX0KCiAgICAgICAgYXN5bmMgd2l0aCBzZWxmLmxvY2s6CiAgICAgICAgICAg
IHJldHVybiBhd2FpdCBhc3luY2lvLnRvX3RocmVhZCh3b3JrKQoKICAgIGFzeW5jIGRlZiBzZXRf
cGVyZm9ybWFuY2Uoc2VsZiwgb246IGJvb2wpOgogICAgICAgIGRlZiB3b3JrKCk6CiAgICAgICAg
ICAgIGlmIG9uOgogICAgICAgICAgICAgICAgY3VycmVudCA9IHNlbGYuX2N1cnJlbnRfZ292ZXJu
b3IoKQogICAgICAgICAgICAgICAgaWYgY3VycmVudCBhbmQgY3VycmVudCAhPSBQRVJGX0dPVkVS
Tk9SOgogICAgICAgICAgICAgICAgICAgIHNlbGYuc2V0dGluZ3NbInByZXZpb3VzX2dvdmVybm9y
Il0gPSBjdXJyZW50CiAgICAgICAgICAgICAgICBlcnIgPSBzZWxmLl9zZXRfZ292ZXJub3JfYWxs
KFBFUkZfR09WRVJOT1IpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBiYWNrID0g
c2VsZi5zZXR0aW5ncy5nZXQoInByZXZpb3VzX2dvdmVybm9yIikKICAgICAgICAgICAgICAgIGF2
YWlsYWJsZSA9IF9hdmFpbGFibGVfZ292ZXJub3JzKCkKICAgICAgICAgICAgICAgIGlmIG5vdCBi
YWNrIG9yIChhdmFpbGFibGUgYW5kIGJhY2sgbm90IGluIGF2YWlsYWJsZSk6CiAgICAgICAgICAg
ICAgICAgICAgIyBTYW1lIGZhbGxiYWNrIG9yZGVyIHRoZSBrZXJuZWwgY29uZmlnIHVzdWFsbHkg
cGlja3MuCiAgICAgICAgICAgICAgICAgICAgYmFjayA9IG5leHQoKGcgZm9yIGcgaW4gKCJzY2hl
ZHV0aWwiLCAicG93ZXJzYXZlIiwgIm9uZGVtYW5kIikgaWYgZyBpbiBhdmFpbGFibGUpLCBOb25l
KQogICAgICAgICAgICAgICAgZXJyID0gc2VsZi5fc2V0X2dvdmVybm9yX2FsbChiYWNrKSBpZiBi
YWNrIGVsc2UgIm5vIGdvdmVybm9yIHRvIGdvIGJhY2sgdG8uIgogICAgICAgICAgICBpZiBub3Qg
ZXJyOgogICAgICAgICAgICAgICAgc2VsZi5zZXR0aW5nc1sicGVyZm9ybWFuY2UiXSA9IGJvb2wo
b24pCiAgICAgICAgICAgICAgICBzZWxmLl9zYXZlKCkKICAgICAgICAgICAgcmV0dXJuIHsib2si
OiBlcnIgaXMgTm9uZSwgIm1lc3NhZ2UiOiBlcnIgb3IgIiIsICJzdGF0dXMiOiBzZWxmLl9zbmFw
c2hvdCgpfQoKICAgICAgICBhc3luYyB3aXRoIHNlbGYubG9jazoKICAgICAgICAgICAgcmV0dXJu
IGF3YWl0IGFzeW5jaW8udG9fdGhyZWFkKHdvcmspClBLAwQKAAAAAACwUFhdAAAAAAAAAAAAAAAA
FgAAAGJjMjUwLXBlcmZvcm1hbmNlL3NyYy9QSwMECgAAAAAAsFBYXbY3sl3JDQAAyQ0AAB8AAABi
YzI1MC1wZXJmb3JtYW5jZS9zcmMvaW5kZXgudHN4aW1wb3J0IHsKICBCdXR0b25JdGVtLAogIEZp
ZWxkLAogIFBhbmVsU2VjdGlvbiwKICBQYW5lbFNlY3Rpb25Sb3csCiAgVG9nZ2xlRmllbGQsCiAg
c3RhdGljQ2xhc3NlcywKfSBmcm9tICJAZGVja3kvdWkiOwppbXBvcnQgeyBjYWxsYWJsZSwgZGVm
aW5lUGx1Z2luLCB0b2FzdGVyIH0gZnJvbSAiQGRlY2t5L2FwaSI7CmltcG9ydCB7IHVzZUVmZmVj
dCwgdXNlU3RhdGUgfSBmcm9tICJyZWFjdCI7CmltcG9ydCB7IEZhVGFjaG9tZXRlckFsdCB9IGZy
b20gInJlYWN0LWljb25zL2ZhIjsKCmludGVyZmFjZSBTdGF0dXMgewogIHNtdF9jb250cm9sOiBz
dHJpbmcgfCBudWxsOwogIHNtdF9jaGFuZ2VhYmxlOiBib29sZWFuOwogIHNtdF9vbjogYm9vbGVh
bjsKICB0aHJlYWRzOiBudW1iZXI7CiAgZ292ZXJub3I6IHN0cmluZyB8IG51bGw7CiAgZ292ZXJu
b3JzOiBzdHJpbmdbXTsKICBkcml2ZXI6IHN0cmluZyB8IG51bGw7CiAgcGVyZm9ybWFuY2VfYXZh
aWxhYmxlOiBib29sZWFuOwogIHBlcmZvcm1hbmNlOiBib29sZWFuOwp9CgppbnRlcmZhY2UgUmVz
dWx0IHsKICBvazogYm9vbGVhbjsKICBtZXNzYWdlOiBzdHJpbmc7CiAgc3RhdHVzOiBTdGF0dXM7
Cn0KCmNvbnN0IGdldFN0YXR1cyA9IGNhbGxhYmxlPFtdLCBTdGF0dXM+KCJnZXRfc3RhdHVzIik7
CmNvbnN0IHNldFNtdCA9IGNhbGxhYmxlPFtib29sZWFuXSwgUmVzdWx0Pigic2V0X3NtdCIpOwpj
b25zdCBzZXRQZXJmb3JtYW5jZSA9IGNhbGxhYmxlPFtib29sZWFuXSwgUmVzdWx0Pigic2V0X3Bl
cmZvcm1hbmNlIik7CgpmdW5jdGlvbiBDb250ZW50KCkgewogIGNvbnN0IFtzdGF0dXMsIHNldFN0
YXR1c10gPSB1c2VTdGF0ZTxTdGF0dXMgfCBudWxsPihudWxsKTsKICBjb25zdCBbZmFpbGVkLCBz
ZXRGYWlsZWRdID0gdXNlU3RhdGUoZmFsc2UpOwogIGNvbnN0IFtidXN5LCBzZXRCdXN5XSA9IHVz
ZVN0YXRlKGZhbHNlKTsKCiAgY29uc3QgcmVmcmVzaCA9ICgpID0+CiAgICBnZXRTdGF0dXMoKQog
ICAgICAudGhlbigocykgPT4gewogICAgICAgIHNldFN0YXR1cyhzKTsKICAgICAgICBzZXRGYWls
ZWQoZmFsc2UpOwogICAgICB9KQogICAgICAuY2F0Y2goKCkgPT4gc2V0RmFpbGVkKHRydWUpKTsK
CiAgdXNlRWZmZWN0KCgpID0+IHsKICAgIHJlZnJlc2goKTsKICB9LCBbXSk7CgogIGNvbnN0IHJ1
biA9IGFzeW5jICh0aXRsZTogc3RyaW5nLCBmbjogKCkgPT4gUHJvbWlzZTxSZXN1bHQ+KSA9PiB7
CiAgICBpZiAoYnVzeSkgcmV0dXJuOwogICAgc2V0QnVzeSh0cnVlKTsKICAgIHRyeSB7CiAgICAg
IGNvbnN0IHIgPSBhd2FpdCBmbigpOwogICAgICBzZXRTdGF0dXMoci5zdGF0dXMpOwogICAgICBp
ZiAoIXIub2spIHRvYXN0ZXIudG9hc3QoeyB0aXRsZSwgYm9keTogci5tZXNzYWdlIH0pOwogICAg
fSBjYXRjaCB7CiAgICAgIHRvYXN0ZXIudG9hc3QoeyB0aXRsZSwgYm9keTogIkJhY2tlbmQgZGlk
IG5vdCByZXNwb25kLiIgfSk7CiAgICB9IGZpbmFsbHkgewogICAgICBzZXRCdXN5KGZhbHNlKTsK
ICAgIH0KICB9OwoKICBpZiAoc3RhdHVzID09PSBudWxsKSB7CiAgICByZXR1cm4gKAogICAgICA8
UGFuZWxTZWN0aW9uIHRpdGxlPSJQZXJmb3JtYW5jZSI+CiAgICAgICAgPFBhbmVsU2VjdGlvblJv
dz57ZmFpbGVkID8gIkJhY2tlbmQgZGlkIG5vdCByZXNwb25kLiIgOiAiUmVhZGluZyB0aGUgQ1BV
4oCmIn08L1BhbmVsU2VjdGlvblJvdz4KICAgICAgICB7ZmFpbGVkICYmICgKICAgICAgICAgIDxQ
YW5lbFNlY3Rpb25Sb3c+CiAgICAgICAgICAgIDxCdXR0b25JdGVtIGxheW91dD0iYmVsb3ciIG9u
Q2xpY2s9e3JlZnJlc2h9PgogICAgICAgICAgICAgIFRyeSBhZ2FpbgogICAgICAgICAgICA8L0J1
dHRvbkl0ZW0+CiAgICAgICAgICA8L1BhbmVsU2VjdGlvblJvdz4KICAgICAgICApfQogICAgICA8
L1BhbmVsU2VjdGlvbj4KICAgICk7CiAgfQoKICBjb25zdCBzbXROb3RlID0gc3RhdHVzLnNtdF9j
aGFuZ2VhYmxlCiAgICA/IGAke3N0YXR1cy50aHJlYWRzfSB0aHJlYWRzIG9uIGxpbmUuIE9mZiBn
aXZlcyBlYWNoIGdhbWUgYSB3aG9sZSBjb3JlIHBlciB0aHJlYWQ7IG9uIHJ1bnMgbW9yZSBhdCBv
bmNlLmAKICAgIDogYENhbid0IGJlIGNoYW5nZWQgd2hpbGUgcnVubmluZyAoa2VybmVsIHJlcG9y
dHMgIiR7c3RhdHVzLnNtdF9jb250cm9sID8/ICJtaXNzaW5nIn0iKS5gOwoKICBjb25zdCBwZXJm
Tm90ZSA9IHN0YXR1cy5wZXJmb3JtYW5jZV9hdmFpbGFibGUKICAgID8gYENQVSBnb3Zlcm5vcjog
JHtzdGF0dXMuZ292ZXJub3IgPz8gInVua25vd24ifSR7c3RhdHVzLmRyaXZlciA/IGAgKCR7c3Rh
dHVzLmRyaXZlcn0pYCA6ICIifS4gT24ga2VlcHMgdGhlIENQVSBhdCBmdWxsIGNsb2NrczsgbW9y
ZSBoZWF0IGFuZCBmYW4gbm9pc2UuYAogICAgOiAiVGhpcyBrZXJuZWwgZXhwb3NlcyBubyBDUFUg
ZnJlcXVlbmN5IHNjYWxpbmcuIjsKCiAgcmV0dXJuICgKICAgIDxQYW5lbFNlY3Rpb24gdGl0bGU9
IkNQVSI+CiAgICAgIDxQYW5lbFNlY3Rpb25Sb3c+CiAgICAgICAgPFRvZ2dsZUZpZWxkCiAgICAg
ICAgICBsYWJlbD0iU01UIChoeXBlcnRocmVhZGluZykiCiAgICAgICAgICBkZXNjcmlwdGlvbj17
c210Tm90ZX0KICAgICAgICAgIGNoZWNrZWQ9e3N0YXR1cy5zbXRfb259CiAgICAgICAgICBkaXNh
YmxlZD17YnVzeSB8fCAhc3RhdHVzLnNtdF9jaGFuZ2VhYmxlfQogICAgICAgICAgb25DaGFuZ2U9
eyh2KSA9PiBydW4oIlNNVCIsICgpID0+IHNldFNtdCh2KSl9CiAgICAgICAgLz4KICAgICAgPC9Q
YW5lbFNlY3Rpb25Sb3c+CiAgICAgIDxQYW5lbFNlY3Rpb25Sb3c+CiAgICAgICAgPFRvZ2dsZUZp
ZWxkCiAgICAgICAgICBsYWJlbD0iUGVyZm9ybWFuY2UgbW9kZSIKICAgICAgICAgIGRlc2NyaXB0
aW9uPXtwZXJmTm90ZX0KICAgICAgICAgIGNoZWNrZWQ9e3N0YXR1cy5wZXJmb3JtYW5jZX0KICAg
ICAgICAgIGRpc2FibGVkPXtidXN5IHx8ICFzdGF0dXMucGVyZm9ybWFuY2VfYXZhaWxhYmxlfQog
ICAgICAgICAgb25DaGFuZ2U9eyh2KSA9PiBydW4oIlBlcmZvcm1hbmNlIG1vZGUiLCAoKSA9PiBz
ZXRQZXJmb3JtYW5jZSh2KSl9CiAgICAgICAgLz4KICAgICAgPC9QYW5lbFNlY3Rpb25Sb3c+CiAg
ICAgIDxQYW5lbFNlY3Rpb25Sb3c+CiAgICAgICAgPEZpZWxkCiAgICAgICAgICBsYWJlbD0iS2Vw
dCBhY3Jvc3MgcmVib290cyIKICAgICAgICAgIGRlc2NyaXB0aW9uPSJCb3RoIHNldHRpbmdzIGFy
ZSBhcHBsaWVkIGFnYWluIGVhY2ggdGltZSBHYW1lIE1vZGUgc3RhcnRzLiIKICAgICAgICAvPgog
ICAgICA8L1BhbmVsU2VjdGlvblJvdz4KICAgIDwvUGFuZWxTZWN0aW9uPgogICk7Cn0KCmV4cG9y
dCBkZWZhdWx0IGRlZmluZVBsdWdpbigoKSA9PiAoewogIG5hbWU6ICJCQy0yNTAgUGVyZm9ybWFu
Y2UiLAogIHRpdGxlVmlldzogPGRpdiBjbGFzc05hbWU9e3N0YXRpY0NsYXNzZXMuVGl0bGV9PkJD
LTI1MCBQZXJmb3JtYW5jZTwvZGl2PiwKICBjb250ZW50OiA8Q29udGVudCAvPiwKICBpY29uOiA8
RmFUYWNob21ldGVyQWx0IC8+LAp9KSk7ClBLAwQKAAAAAADIUFhdAAAAAAAAAAAAAAAAFwAAAGJj
MjUwLXBlcmZvcm1hbmNlL2Rpc3QvUEsDBAoAAAAAALxQWF3E6Zsc2yIAANsiAAAfAAAAYmMyNTAt
cGVyZm9ybWFuY2UvZGlzdC9pbmRleC5qc2NvbnN0IG1hbmlmZXN0ID0geyJuYW1lIjoiQkMtMjUw
IFBlcmZvcm1hbmNlIn07CmNvbnN0IEFQSV9WRVJTSU9OID0gMjsKY29uc3QgaW50ZXJuYWxBUElD
b25uZWN0aW9uID0gd2luZG93Ll9fREVDS1lfU0VDUkVUX0lOVEVSTkFMU19ET19OT1RfVVNFX09S
X1lPVV9XSUxMX0JFX0ZJUkVEX2RlY2t5TG9hZGVyQVBJSW5pdDsKaWYgKCFpbnRlcm5hbEFQSUNv
bm5lY3Rpb24pIHsKICAgIHRocm93IG5ldyBFcnJvcignW0BkZWNreS9hcGldOiBGYWlsZWQgdG8g
Y29ubmVjdCB0byB0aGUgbG9hZGVyIGFzIGFzIHRoZSBsb2FkZXIgQVBJIHdhcyBub3QgaW5pdGlh
bGl6ZWQuIFRoaXMgaXMgbGlrZWx5IGEgYnVnIGluIERlY2t5IExvYWRlci4nKTsKfQpsZXQgYXBp
Owp0cnkgewogICAgYXBpID0gaW50ZXJuYWxBUElDb25uZWN0aW9uLmNvbm5lY3QoQVBJX1ZFUlNJ
T04sIG1hbmlmZXN0Lm5hbWUpOwp9CmNhdGNoIHsKICAgIGFwaSA9IGludGVybmFsQVBJQ29ubmVj
dGlvbi5jb25uZWN0KDEsIG1hbmlmZXN0Lm5hbWUpOwogICAgY29uc29sZS53YXJuKGBbQGRlY2t5
L2FwaV0gUmVxdWVzdGVkIEFQSSB2ZXJzaW9uICR7QVBJX1ZFUlNJT059IGJ1dCB0aGUgcnVubmlu
ZyBsb2FkZXIgb25seSBzdXBwb3J0cyB2ZXJzaW9uIDEuIFNvbWUgZmVhdHVyZXMgbWF5IG5vdCB3
b3JrLmApOwp9CmlmIChhcGkuX3ZlcnNpb24gIT0gQVBJX1ZFUlNJT04pIHsKICAgIGNvbnNvbGUu
d2FybihgW0BkZWNreS9hcGldIFJlcXVlc3RlZCBBUEkgdmVyc2lvbiAke0FQSV9WRVJTSU9OfSBi
dXQgdGhlIHJ1bm5pbmcgbG9hZGVyIG9ubHkgc3VwcG9ydHMgdmVyc2lvbiAke2FwaS5fdmVyc2lv
bn0uIFNvbWUgZmVhdHVyZXMgbWF5IG5vdCB3b3JrLmApOwp9CmNvbnN0IGNhbGxhYmxlID0gYXBp
LmNhbGxhYmxlOwpjb25zdCB0b2FzdGVyID0gYXBpLnRvYXN0ZXI7CmNvbnN0IGRlZmluZVBsdWdp
biA9IChmbikgPT4gewogICAgcmV0dXJuICguLi5hcmdzKSA9PiB7CiAgICAgICAgcmV0dXJuIGZu
KC4uLmFyZ3MpOwogICAgfTsKfTsKCnZhciBEZWZhdWx0Q29udGV4dCA9IHsKICBjb2xvcjogdW5k
ZWZpbmVkLAogIHNpemU6IHVuZGVmaW5lZCwKICBjbGFzc05hbWU6IHVuZGVmaW5lZCwKICBzdHls
ZTogdW5kZWZpbmVkLAogIGF0dHI6IHVuZGVmaW5lZAp9Owp2YXIgSWNvbkNvbnRleHQgPSBTUF9S
RUFDVC5jcmVhdGVDb250ZXh0ICYmIC8qI19fUFVSRV9fKi9TUF9SRUFDVC5jcmVhdGVDb250ZXh0
KERlZmF1bHRDb250ZXh0KTsKCnZhciBfZXhjbHVkZWQgPSBbImF0dHIiLCAic2l6ZSIsICJ0aXRs
ZSJdOwpmdW5jdGlvbiBfb2JqZWN0V2l0aG91dFByb3BlcnRpZXMoZSwgdCkgeyBpZiAobnVsbCA9
PSBlKSByZXR1cm4ge307IHZhciBvLCByLCBpID0gX29iamVjdFdpdGhvdXRQcm9wZXJ0aWVzTG9v
c2UoZSwgdCk7IGlmIChPYmplY3QuZ2V0T3duUHJvcGVydHlTeW1ib2xzKSB7IHZhciBuID0gT2Jq
ZWN0LmdldE93blByb3BlcnR5U3ltYm9scyhlKTsgZm9yIChyID0gMDsgciA8IG4ubGVuZ3RoOyBy
KyspIG8gPSBuW3JdLCAtMSA9PT0gdC5pbmRleE9mKG8pICYmIHt9LnByb3BlcnR5SXNFbnVtZXJh
YmxlLmNhbGwoZSwgbykgJiYgKGlbb10gPSBlW29dKTsgfSByZXR1cm4gaTsgfQpmdW5jdGlvbiBf
b2JqZWN0V2l0aG91dFByb3BlcnRpZXNMb29zZShyLCBlKSB7IGlmIChudWxsID09IHIpIHJldHVy
biB7fTsgdmFyIHQgPSB7fTsgZm9yICh2YXIgbiBpbiByKSBpZiAoe30uaGFzT3duUHJvcGVydHku
Y2FsbChyLCBuKSkgeyBpZiAoLTEgIT09IGUuaW5kZXhPZihuKSkgY29udGludWU7IHRbbl0gPSBy
W25dOyB9IHJldHVybiB0OyB9CmZ1bmN0aW9uIF9leHRlbmRzKCkgeyByZXR1cm4gX2V4dGVuZHMg
PSBPYmplY3QuYXNzaWduID8gT2JqZWN0LmFzc2lnbi5iaW5kKCkgOiBmdW5jdGlvbiAobikgeyBm
b3IgKHZhciBlID0gMTsgZSA8IGFyZ3VtZW50cy5sZW5ndGg7IGUrKykgeyB2YXIgdCA9IGFyZ3Vt
ZW50c1tlXTsgZm9yICh2YXIgciBpbiB0KSAoe30pLmhhc093blByb3BlcnR5LmNhbGwodCwgcikg
JiYgKG5bcl0gPSB0W3JdKTsgfSByZXR1cm4gbjsgfSwgX2V4dGVuZHMuYXBwbHkobnVsbCwgYXJn
dW1lbnRzKTsgfQpmdW5jdGlvbiBvd25LZXlzKGUsIHIpIHsgdmFyIHQgPSBPYmplY3Qua2V5cyhl
KTsgaWYgKE9iamVjdC5nZXRPd25Qcm9wZXJ0eVN5bWJvbHMpIHsgdmFyIG8gPSBPYmplY3QuZ2V0
T3duUHJvcGVydHlTeW1ib2xzKGUpOyByICYmIChvID0gby5maWx0ZXIoZnVuY3Rpb24gKHIpIHsg
cmV0dXJuIE9iamVjdC5nZXRPd25Qcm9wZXJ0eURlc2NyaXB0b3IoZSwgcikuZW51bWVyYWJsZTsg
fSkpLCB0LnB1c2guYXBwbHkodCwgbyk7IH0gcmV0dXJuIHQ7IH0KZnVuY3Rpb24gX29iamVjdFNw
cmVhZChlKSB7IGZvciAodmFyIHIgPSAxOyByIDwgYXJndW1lbnRzLmxlbmd0aDsgcisrKSB7IHZh
ciB0ID0gbnVsbCAhPSBhcmd1bWVudHNbcl0gPyBhcmd1bWVudHNbcl0gOiB7fTsgciAlIDIgPyBv
d25LZXlzKE9iamVjdCh0KSwgdHJ1ZSkuZm9yRWFjaChmdW5jdGlvbiAocikgeyBfZGVmaW5lUHJv
cGVydHkoZSwgciwgdFtyXSk7IH0pIDogT2JqZWN0LmdldE93blByb3BlcnR5RGVzY3JpcHRvcnMg
PyBPYmplY3QuZGVmaW5lUHJvcGVydGllcyhlLCBPYmplY3QuZ2V0T3duUHJvcGVydHlEZXNjcmlw
dG9ycyh0KSkgOiBvd25LZXlzKE9iamVjdCh0KSkuZm9yRWFjaChmdW5jdGlvbiAocikgeyBPYmpl
Y3QuZGVmaW5lUHJvcGVydHkoZSwgciwgT2JqZWN0LmdldE93blByb3BlcnR5RGVzY3JpcHRvcih0
LCByKSk7IH0pOyB9IHJldHVybiBlOyB9CmZ1bmN0aW9uIF9kZWZpbmVQcm9wZXJ0eShlLCByLCB0
KSB7IHJldHVybiAociA9IF90b1Byb3BlcnR5S2V5KHIpKSBpbiBlID8gT2JqZWN0LmRlZmluZVBy
b3BlcnR5KGUsIHIsIHsgdmFsdWU6IHQsIGVudW1lcmFibGU6IHRydWUsIGNvbmZpZ3VyYWJsZTog
dHJ1ZSwgd3JpdGFibGU6IHRydWUgfSkgOiBlW3JdID0gdCwgZTsgfQpmdW5jdGlvbiBfdG9Qcm9w
ZXJ0eUtleSh0KSB7IHZhciBpID0gX3RvUHJpbWl0aXZlKHQsICJzdHJpbmciKTsgcmV0dXJuICJz
eW1ib2wiID09IHR5cGVvZiBpID8gaSA6IGkgKyAiIjsgfQpmdW5jdGlvbiBfdG9QcmltaXRpdmUo
dCwgcikgeyBpZiAoIm9iamVjdCIgIT0gdHlwZW9mIHQgfHwgIXQpIHJldHVybiB0OyB2YXIgZSA9
IHRbU3ltYm9sLnRvUHJpbWl0aXZlXTsgaWYgKHZvaWQgMCAhPT0gZSkgeyB2YXIgaSA9IGUuY2Fs
bCh0LCByKTsgaWYgKCJvYmplY3QiICE9IHR5cGVvZiBpKSByZXR1cm4gaTsgdGhyb3cgbmV3IFR5
cGVFcnJvcigiQEB0b1ByaW1pdGl2ZSBtdXN0IHJldHVybiBhIHByaW1pdGl2ZSB2YWx1ZS4iKTsg
fSByZXR1cm4gKCJzdHJpbmciID09PSByID8gU3RyaW5nIDogTnVtYmVyKSh0KTsgfQpmdW5jdGlv
biBUcmVlMkVsZW1lbnQodHJlZSkgewogIHJldHVybiB0cmVlICYmIHRyZWUubWFwKChub2RlLCBp
KSA9PiAvKiNfX1BVUkVfXyovU1BfUkVBQ1QuY3JlYXRlRWxlbWVudChub2RlLnRhZywgX29iamVj
dFNwcmVhZCh7CiAgICBrZXk6IGkKICB9LCBub2RlLmF0dHIpLCBUcmVlMkVsZW1lbnQobm9kZS5j
aGlsZCkpKTsKfQpmdW5jdGlvbiBHZW5JY29uKGRhdGEpIHsKICByZXR1cm4gcHJvcHMgPT4gLyoj
X19QVVJFX18qL1NQX1JFQUNULmNyZWF0ZUVsZW1lbnQoSWNvbkJhc2UsIF9leHRlbmRzKHsKICAg
IGF0dHI6IF9vYmplY3RTcHJlYWQoe30sIGRhdGEuYXR0cikKICB9LCBwcm9wcyksIFRyZWUyRWxl
bWVudChkYXRhLmNoaWxkKSk7Cn0KZnVuY3Rpb24gSWNvbkJhc2UocHJvcHMpIHsKICB2YXIgZWxl
bSA9IGNvbmYgPT4gewogICAgdmFyIGF0dHIgPSBwcm9wcy5hdHRyLAogICAgICBzaXplID0gcHJv
cHMuc2l6ZSwKICAgICAgdGl0bGUgPSBwcm9wcy50aXRsZSwKICAgICAgc3ZnUHJvcHMgPSBfb2Jq
ZWN0V2l0aG91dFByb3BlcnRpZXMocHJvcHMsIF9leGNsdWRlZCk7CiAgICB2YXIgY29tcHV0ZWRT
aXplID0gc2l6ZSB8fCBjb25mLnNpemUgfHwgIjFlbSI7CiAgICB2YXIgY2xhc3NOYW1lOwogICAg
aWYgKGNvbmYuY2xhc3NOYW1lKSBjbGFzc05hbWUgPSBjb25mLmNsYXNzTmFtZTsKICAgIGlmIChw
cm9wcy5jbGFzc05hbWUpIGNsYXNzTmFtZSA9IChjbGFzc05hbWUgPyBjbGFzc05hbWUgKyAiICIg
OiAiIikgKyBwcm9wcy5jbGFzc05hbWU7CiAgICByZXR1cm4gLyojX19QVVJFX18qL1NQX1JFQUNU
LmNyZWF0ZUVsZW1lbnQoInN2ZyIsIF9leHRlbmRzKHsKICAgICAgc3Ryb2tlOiAiY3VycmVudENv
bG9yIiwKICAgICAgZmlsbDogImN1cnJlbnRDb2xvciIsCiAgICAgIHN0cm9rZVdpZHRoOiAiMCIK
ICAgIH0sIGNvbmYuYXR0ciwgYXR0ciwgc3ZnUHJvcHMsIHsKICAgICAgY2xhc3NOYW1lOiBjbGFz
c05hbWUsCiAgICAgIHN0eWxlOiBfb2JqZWN0U3ByZWFkKF9vYmplY3RTcHJlYWQoewogICAgICAg
IGNvbG9yOiBwcm9wcy5jb2xvciB8fCBjb25mLmNvbG9yCiAgICAgIH0sIGNvbmYuc3R5bGUpLCBw
cm9wcy5zdHlsZSksCiAgICAgIGhlaWdodDogY29tcHV0ZWRTaXplLAogICAgICB3aWR0aDogY29t
cHV0ZWRTaXplLAogICAgICB4bWxuczogImh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIgogICAg
fSksIHRpdGxlICYmIC8qI19fUFVSRV9fKi9TUF9SRUFDVC5jcmVhdGVFbGVtZW50KCJ0aXRsZSIs
IG51bGwsIHRpdGxlKSwgcHJvcHMuY2hpbGRyZW4pOwogIH07CiAgcmV0dXJuIEljb25Db250ZXh0
ICE9PSB1bmRlZmluZWQgPyAvKiNfX1BVUkVfXyovU1BfUkVBQ1QuY3JlYXRlRWxlbWVudChJY29u
Q29udGV4dC5Db25zdW1lciwgbnVsbCwgY29uZiA9PiBlbGVtKGNvbmYpKSA6IGVsZW0oRGVmYXVs
dENvbnRleHQpOwp9CgovLyBUSElTIEZJTEUgSVMgQVVUTyBHRU5FUkFURUQKZnVuY3Rpb24gRmFU
YWNob21ldGVyQWx0IChwcm9wcykgewogIHJldHVybiBHZW5JY29uKHsiYXR0ciI6eyJ2aWV3Qm94
IjoiMCAwIDU3NiA1MTIifSwiY2hpbGQiOlt7InRhZyI6InBhdGgiLCJhdHRyIjp7ImQiOiJNMjg4
IDMyQzEyOC45NCAzMiAwIDE2MC45NCAwIDMyMGMwIDUyLjggMTQuMjUgMTAyLjI2IDM5LjA2IDE0
NC44IDUuNjEgOS42MiAxNi4zIDE1LjIgMjcuNDQgMTUuMmg0NDNjMTEuMTQgMCAyMS44My01LjU4
IDI3LjQ0LTE1LjJDNTYxLjc1IDQyMi4yNiA1NzYgMzcyLjggNTc2IDMyMGMwLTE1OS4wNi0xMjgu
OTQtMjg4LTI4OC0yODh6bTAgNjRjMTQuNzEgMCAyNi41OCAxMC4xMyAzMC4zMiAyMy42NS0xLjEx
IDIuMjYtMi42NCA0LjIzLTMuNDUgNi42N2wtOS4yMiAyNy42N2MtNS4xMyAzLjQ5LTEwLjk3IDYu
MDEtMTcuNjQgNi4wMS0xNy42NyAwLTMyLTE0LjMzLTMyLTMyUzI3MC4zMyA5NiAyODggOTZ6TTk2
IDM4NGMtMTcuNjcgMC0zMi0xNC4zMy0zMi0zMnMxNC4zMy0zMiAzMi0zMiAzMiAxNC4zMyAzMiAz
Mi0xNC4zMyAzMi0zMiAzMnptNDgtMTYwYy0xNy42NyAwLTMyLTE0LjMzLTMyLTMyczE0LjMzLTMy
IDMyLTMyIDMyIDE0LjMzIDMyIDMyLTE0LjMzIDMyLTMyIDMyem0yNDYuNzctNzIuNDFsLTYxLjMz
IDE4NEMzNDMuMTMgMzQ3LjMzIDM1MiAzNjQuNTQgMzUyIDM4NGMwIDExLjcyLTMuMzggMjIuNTUt
OC44OCAzMkgyMzIuODhjLTUuNS05LjQ1LTguODgtMjAuMjgtOC44OC0zMiAwLTMzLjk0IDI2LjUt
NjEuNDMgNTkuOS02My41OWw2MS4zNC0xODQuMDFjNC4xNy0xMi41NiAxNy43My0xOS40NSAzMC4z
Ni0xNS4xNyAxMi41NyA0LjE5IDE5LjM1IDE3Ljc5IDE1LjE3IDMwLjM2em0xNC42NiA1Ny4ybDE1
LjUyLTQ2LjU1YzMuNDctMS4yOSA3LjEzLTIuMjMgMTEuMDUtMi4yMyAxNy42NyAwIDMyIDE0LjMz
IDMyIDMycy0xNC4zMyAzMi0zMiAzMmMtMTEuMzgtLjAxLTIwLjg5LTYuMjgtMjYuNTctMTUuMjJ6
TTQ4MCAzODRjLTE3LjY3IDAtMzItMTQuMzMtMzItMzJzMTQuMzMtMzIgMzItMzIgMzIgMTQuMzMg
MzIgMzItMTQuMzMgMzItMzIgMzJ6In0sImNoaWxkIjpbXX1dfSkocHJvcHMpOwp9Cgpjb25zdCBn
ZXRTdGF0dXMgPSBjYWxsYWJsZSgiZ2V0X3N0YXR1cyIpOwpjb25zdCBzZXRTbXQgPSBjYWxsYWJs
ZSgic2V0X3NtdCIpOwpjb25zdCBzZXRQZXJmb3JtYW5jZSA9IGNhbGxhYmxlKCJzZXRfcGVyZm9y
bWFuY2UiKTsKZnVuY3Rpb24gQ29udGVudCgpIHsKICAgIGNvbnN0IFtzdGF0dXMsIHNldFN0YXR1
c10gPSBTUF9SRUFDVC51c2VTdGF0ZShudWxsKTsKICAgIGNvbnN0IFtmYWlsZWQsIHNldEZhaWxl
ZF0gPSBTUF9SRUFDVC51c2VTdGF0ZShmYWxzZSk7CiAgICBjb25zdCBbYnVzeSwgc2V0QnVzeV0g
PSBTUF9SRUFDVC51c2VTdGF0ZShmYWxzZSk7CiAgICBjb25zdCByZWZyZXNoID0gKCkgPT4gZ2V0
U3RhdHVzKCkKICAgICAgICAudGhlbigocykgPT4gewogICAgICAgIHNldFN0YXR1cyhzKTsKICAg
ICAgICBzZXRGYWlsZWQoZmFsc2UpOwogICAgfSkKICAgICAgICAuY2F0Y2goKCkgPT4gc2V0RmFp
bGVkKHRydWUpKTsKICAgIFNQX1JFQUNULnVzZUVmZmVjdCgoKSA9PiB7CiAgICAgICAgcmVmcmVz
aCgpOwogICAgfSwgW10pOwogICAgY29uc3QgcnVuID0gYXN5bmMgKHRpdGxlLCBmbikgPT4gewog
ICAgICAgIGlmIChidXN5KQogICAgICAgICAgICByZXR1cm47CiAgICAgICAgc2V0QnVzeSh0cnVl
KTsKICAgICAgICB0cnkgewogICAgICAgICAgICBjb25zdCByID0gYXdhaXQgZm4oKTsKICAgICAg
ICAgICAgc2V0U3RhdHVzKHIuc3RhdHVzKTsKICAgICAgICAgICAgaWYgKCFyLm9rKQogICAgICAg
ICAgICAgICAgdG9hc3Rlci50b2FzdCh7IHRpdGxlLCBib2R5OiByLm1lc3NhZ2UgfSk7CiAgICAg
ICAgfQogICAgICAgIGNhdGNoIHsKICAgICAgICAgICAgdG9hc3Rlci50b2FzdCh7IHRpdGxlLCBi
b2R5OiAiQmFja2VuZCBkaWQgbm90IHJlc3BvbmQuIiB9KTsKICAgICAgICB9CiAgICAgICAgZmlu
YWxseSB7CiAgICAgICAgICAgIHNldEJ1c3koZmFsc2UpOwogICAgICAgIH0KICAgIH07CiAgICBp
ZiAoc3RhdHVzID09PSBudWxsKSB7CiAgICAgICAgcmV0dXJuIChTUF9KU1guanN4cyhERkwuUGFu
ZWxTZWN0aW9uLCB7IHRpdGxlOiAiUGVyZm9ybWFuY2UiLCBjaGlsZHJlbjogW1NQX0pTWC5qc3go
REZMLlBhbmVsU2VjdGlvblJvdywgeyBjaGlsZHJlbjogZmFpbGVkID8gIkJhY2tlbmQgZGlkIG5v
dCByZXNwb25kLiIgOiAiUmVhZGluZyB0aGUgQ1BV4oCmIiB9KSwgZmFpbGVkICYmIChTUF9KU1gu
anN4KERGTC5QYW5lbFNlY3Rpb25Sb3csIHsgY2hpbGRyZW46IFNQX0pTWC5qc3goREZMLkJ1dHRv
bkl0ZW0sIHsgbGF5b3V0OiAiYmVsb3ciLCBvbkNsaWNrOiByZWZyZXNoLCBjaGlsZHJlbjogIlRy
eSBhZ2FpbiIgfSkgfSkpXSB9KSk7CiAgICB9CiAgICBjb25zdCBzbXROb3RlID0gc3RhdHVzLnNt
dF9jaGFuZ2VhYmxlCiAgICAgICAgPyBgJHtzdGF0dXMudGhyZWFkc30gdGhyZWFkcyBvbiBsaW5l
LiBPZmYgZ2l2ZXMgZWFjaCBnYW1lIGEgd2hvbGUgY29yZSBwZXIgdGhyZWFkOyBvbiBydW5zIG1v
cmUgYXQgb25jZS5gCiAgICAgICAgOiBgQ2FuJ3QgYmUgY2hhbmdlZCB3aGlsZSBydW5uaW5nIChr
ZXJuZWwgcmVwb3J0cyAiJHtzdGF0dXMuc210X2NvbnRyb2wgPz8gIm1pc3NpbmcifSIpLmA7CiAg
ICBjb25zdCBwZXJmTm90ZSA9IHN0YXR1cy5wZXJmb3JtYW5jZV9hdmFpbGFibGUKICAgICAgICA/
IGBDUFUgZ292ZXJub3I6ICR7c3RhdHVzLmdvdmVybm9yID8/ICJ1bmtub3duIn0ke3N0YXR1cy5k
cml2ZXIgPyBgICgke3N0YXR1cy5kcml2ZXJ9KWAgOiAiIn0uIE9uIGtlZXBzIHRoZSBDUFUgYXQg
ZnVsbCBjbG9ja3M7IG1vcmUgaGVhdCBhbmQgZmFuIG5vaXNlLmAKICAgICAgICA6ICJUaGlzIGtl
cm5lbCBleHBvc2VzIG5vIENQVSBmcmVxdWVuY3kgc2NhbGluZy4iOwogICAgcmV0dXJuIChTUF9K
U1guanN4cyhERkwuUGFuZWxTZWN0aW9uLCB7IHRpdGxlOiAiQ1BVIiwgY2hpbGRyZW46IFtTUF9K
U1guanN4KERGTC5QYW5lbFNlY3Rpb25Sb3csIHsgY2hpbGRyZW46IFNQX0pTWC5qc3goREZMLlRv
Z2dsZUZpZWxkLCB7IGxhYmVsOiAiU01UIChoeXBlcnRocmVhZGluZykiLCBkZXNjcmlwdGlvbjog
c210Tm90ZSwgY2hlY2tlZDogc3RhdHVzLnNtdF9vbiwgZGlzYWJsZWQ6IGJ1c3kgfHwgIXN0YXR1
cy5zbXRfY2hhbmdlYWJsZSwgb25DaGFuZ2U6ICh2KSA9PiBydW4oIlNNVCIsICgpID0+IHNldFNt
dCh2KSkgfSkgfSksIFNQX0pTWC5qc3goREZMLlBhbmVsU2VjdGlvblJvdywgeyBjaGlsZHJlbjog
U1BfSlNYLmpzeChERkwuVG9nZ2xlRmllbGQsIHsgbGFiZWw6ICJQZXJmb3JtYW5jZSBtb2RlIiwg
ZGVzY3JpcHRpb246IHBlcmZOb3RlLCBjaGVja2VkOiBzdGF0dXMucGVyZm9ybWFuY2UsIGRpc2Fi
bGVkOiBidXN5IHx8ICFzdGF0dXMucGVyZm9ybWFuY2VfYXZhaWxhYmxlLCBvbkNoYW5nZTogKHYp
ID0+IHJ1bigiUGVyZm9ybWFuY2UgbW9kZSIsICgpID0+IHNldFBlcmZvcm1hbmNlKHYpKSB9KSB9
KSwgU1BfSlNYLmpzeChERkwuUGFuZWxTZWN0aW9uUm93LCB7IGNoaWxkcmVuOiBTUF9KU1guanN4
KERGTC5GaWVsZCwgeyBsYWJlbDogIktlcHQgYWNyb3NzIHJlYm9vdHMiLCBkZXNjcmlwdGlvbjog
IkJvdGggc2V0dGluZ3MgYXJlIGFwcGxpZWQgYWdhaW4gZWFjaCB0aW1lIEdhbWUgTW9kZSBzdGFy
dHMuIiB9KSB9KV0gfSkpOwp9CnZhciBpbmRleCA9IGRlZmluZVBsdWdpbigoKSA9PiAoewogICAg
bmFtZTogIkJDLTI1MCBQZXJmb3JtYW5jZSIsCiAgICB0aXRsZVZpZXc6IFNQX0pTWC5qc3goImRp
diIsIHsgY2xhc3NOYW1lOiBERkwuc3RhdGljQ2xhc3Nlcy5UaXRsZSwgY2hpbGRyZW46ICJCQy0y
NTAgUGVyZm9ybWFuY2UiIH0pLAogICAgY29udGVudDogU1BfSlNYLmpzeChDb250ZW50LCB7fSks
CiAgICBpY29uOiBTUF9KU1guanN4KEZhVGFjaG9tZXRlckFsdCwge30pLAp9KSk7CgpleHBvcnQg
eyBpbmRleCBhcyBkZWZhdWx0IH07Ci8vIyBzb3VyY2VNYXBwaW5nVVJMPWluZGV4LmpzLm1hcApQ
SwMECgAAAAAAsVBYXRyh+KVpAwAAaQMAABsAAABiYzI1MC1wZXJmb3JtYW5jZS9SRUFETUUubWQj
IEJDLTI1MCBQZXJmb3JtYW5jZQoKRGVja3kgcGx1Z2luIGZvciB0aGUgQkMtMjUwOiBDUFUgdG9n
Z2xlcyBpbiB0aGUgUXVpY2sgQWNjZXNzIE1lbnUuCgotIFNNVCAoaHlwZXJ0aHJlYWRpbmcpIG9u
IG9yIG9mZi4gT2ZmIHRha2VzIHRoZSBzaWJsaW5nIHRocmVhZHMgb2ZmIGxpbmUKICAoNiBjb3Jl
cyAvIDYgdGhyZWFkcyksIG9uIGJyaW5ncyB0aGVtIGJhY2sgKDYgY29yZXMgLyAxMiB0aHJlYWRz
KS4gQ2hhbmdlcwogIHJpZ2h0IGF3YXkgdGhyb3VnaCBgL3N5cy9kZXZpY2VzL3N5c3RlbS9jcHUv
c210L2NvbnRyb2xgLCBubyByZWJvb3QuCi0gUGVyZm9ybWFuY2UgbW9kZSBvbiBvciBvZmYuIE9u
IHNldHMgZXZlcnkgQ1BVJ3MgY3B1ZnJlcSBnb3Zlcm5vciB0bwogIGBwZXJmb3JtYW5jZWA7IG9m
ZiBwdXRzIGJhY2sgdGhlIGdvdmVybm9yIHRoYXQgd2FzIGluIHVzZSBiZWZvcmUuIFRoZSBHUFUK
ICBpcyBsZWZ0IHRvIGl0cyBvd24gZ292ZXJub3IgKG9iZXJvbi1nb3Zlcm5vciBmcm9tIHRoZSBC
Qy0yNTAgQ29udHJvbAogIENlbnRlcikuCgpCb3RoIHNldHRpbmdzIGFyZSBzYXZlZCBhbmQgYXBw
bGllZCBhZ2FpbiBlYWNoIHRpbWUgRGVja3kgc3RhcnRzLCBzbyB0aGV5CmhvbGQgYWNyb3NzIHJl
Ym9vdHMuIE5vdGhpbmcgaXMgd3JpdHRlbiBvdXRzaWRlIHN5c2ZzIGFuZCB0aGUgcGx1Z2luJ3Mg
b3duCnNldHRpbmdzIGZpbGU6IHJlbW92ZSB0aGUgcGx1Z2luIGFuZCByZWJvb3QgdG8gZ2V0IHRo
ZSBrZXJuZWwgZGVmYXVsdHMgYmFjay4KCklmIHRoZSBrZXJuZWwgd2FzIGJvb3RlZCB3aXRoIGBu
b3NtdD1mb3JjZWAsIFNNVCBzaG93cyBhcyBsb2NrZWQuCgpCdWlsZDogYG5wbSBpbnN0YWxsICYm
IG5wbSBydW4gYnVpbGRgLgpQSwMECgAAAAAAl1BYXT+xqU0AAgAAAAIAAB4AAABiYzI1MC1wZXJm
b3JtYW5jZS9wYWNrYWdlLmpzb257CiAgIm5hbWUiOiAiYmMyNTAtcGVyZm9ybWFuY2UiLAogICJ2
ZXJzaW9uIjogIjAuMS4wIiwKICAiZGVzY3JpcHRpb24iOiAiU01UIGFuZCBDUFUgcGVyZm9ybWFu
Y2UgbW9kZSB0b2dnbGVzIGZvciB0aGUgQkMtMjUwLiIsCiAgInR5cGUiOiAibW9kdWxlIiwKICAi
c2NyaXB0cyI6IHsKICAgICJidWlsZCI6ICJzaHggcm0gLXJmIGRpc3QgJiYgcm9sbHVwIC1jIiwK
ICAgICJ3YXRjaCI6ICJyb2xsdXAgLWMgLXciCiAgfSwKICAiZGVwZW5kZW5jaWVzIjogewogICAg
IkBkZWNreS9hcGkiOiAiXjEuMS4yIiwKICAgICJAZGVja3kvdWkiOiAiXjQuOS4wIiwKICAgICJy
ZWFjdC1pY29ucyI6ICJeNS4zLjAiCiAgfSwKICAiZGV2RGVwZW5kZW5jaWVzIjogewogICAgIkBk
ZWNreS9yb2xsdXAiOiAiXjEuMC4xIiwKICAgICJAdHlwZXMvcmVhY3QiOiAiMTguMy4zIiwKICAg
ICJyb2xsdXAiOiAiXjQuMjQuMCIsCiAgICAic2h4IjogIl4wLjMuNCIsCiAgICAidHlwZXNjcmlw
dCI6ICJeNS42LjMiCiAgfQp9ClBLAwQKAAAAAACXUFhd1oW0MxgBAAAYAQAAHwAAAGJjMjUwLXBl
cmZvcm1hbmNlL3RzY29uZmlnLmpzb257CiAgImNvbXBpbGVyT3B0aW9ucyI6IHsKICAgICJ0YXJn
ZXQiOiAiRVMyMDIwIiwKICAgICJtb2R1bGUiOiAiRVNOZXh0IiwKICAgICJtb2R1bGVSZXNvbHV0
aW9uIjogImJ1bmRsZXIiLAogICAgImpzeCI6ICJyZWFjdC1qc3giLAogICAgInN0cmljdCI6IHRy
dWUsCiAgICAiZXNNb2R1bGVJbnRlcm9wIjogdHJ1ZSwKICAgICJza2lwTGliQ2hlY2siOiB0cnVl
LAogICAgImZvcmNlQ29uc2lzdGVudENhc2luZ0luRmlsZU5hbWVzIjogdHJ1ZQogIH0sCiAgImlu
Y2x1ZGUiOiBbInNyYyJdCn0KUEsDBAoAAAAAAJdQWF3FILfWNAEAADQBAAAdAAAAYmMyNTAtcGVy
Zm9ybWFuY2UvcGx1Z2luLmpzb257CiAgIm5hbWUiOiAiQkMtMjUwIFBlcmZvcm1hbmNlIiwKICAi
YXV0aG9yIjogImJjMjUwLXNldHVwIiwKICAiZmxhZ3MiOiBbInJvb3QiXSwKICAiYXBpX3ZlcnNp
b24iOiAxLAogICJwdWJsaXNoIjogewogICAgInRhZ3MiOiBbInBlcmZvcm1hbmNlIiwgImNwdSIs
ICJzbXQiLCAiYmMyNTAiXSwKICAgICJkZXNjcmlwdGlvbiI6ICJTTVQgKENQVSBoeXBlcnRocmVh
ZGluZykgYW5kIENQVSBwZXJmb3JtYW5jZSBtb2RlIHRvZ2dsZXMgZm9yIHRoZSBCQy0yNTAsIGtl
cHQgYWNyb3NzIHJlYm9vdHMuIiwKICAgICJpbWFnZSI6ICIiCiAgfQp9ClBLAwQKAAAAAACXUFhd
X2ug1EgAAABIAAAAIgAAAGJjMjUwLXBlcmZvcm1hbmNlL3JvbGx1cC5jb25maWcuanNpbXBvcnQg
ZGVja3lQbHVnaW4gZnJvbSAiQGRlY2t5L3JvbGx1cCI7CgpleHBvcnQgZGVmYXVsdCBkZWNreVBs
dWdpbigpOwpQSwECHgMKAAAAAADNUFhdAAAAAAAAAAAAAAAAEgAAAAAAAAAAABAA7UEAAAAAYmMy
NTAtcGVyZm9ybWFuY2UvUEsBAh4DCgAAAAAAqVBYXc/NsNFyHgAAch4AABkAAAAAAAAAAAAAAKSB
MAAAAGJjMjUwLXBlcmZvcm1hbmNlL21haW4ucHlQSwECHgMKAAAAAACwUFhdAAAAAAAAAAAAAAAA
FgAAAAAAAAAAABAA7UHZHgAAYmMyNTAtcGVyZm9ybWFuY2Uvc3JjL1BLAQIeAwoAAAAAALBQWF22
N7JdyQ0AAMkNAAAfAAAAAAAAAAAAAACkgQ0fAABiYzI1MC1wZXJmb3JtYW5jZS9zcmMvaW5kZXgu
dHN4UEsBAh4DCgAAAAAAyFBYXQAAAAAAAAAAAAAAABcAAAAAAAAAAAAQAO1BEy0AAGJjMjUwLXBl
cmZvcm1hbmNlL2Rpc3QvUEsBAh4DCgAAAAAAvFBYXcTpmxzbIgAA2yIAAB8AAAAAAAAAAAAAAKSB
SC0AAGJjMjUwLXBlcmZvcm1hbmNlL2Rpc3QvaW5kZXguanNQSwECHgMKAAAAAACxUFhdHKH4pWkD
AABpAwAAGwAAAAAAAAAAAAAApIFgUAAAYmMyNTAtcGVyZm9ybWFuY2UvUkVBRE1FLm1kUEsBAh4D
CgAAAAAAl1BYXT+xqU0AAgAAAAIAAB4AAAAAAAAAAAAAAKSBAlQAAGJjMjUwLXBlcmZvcm1hbmNl
L3BhY2thZ2UuanNvblBLAQIeAwoAAAAAAJdQWF3WhbQzGAEAABgBAAAfAAAAAAAAAAAAAACkgT5W
AABiYzI1MC1wZXJmb3JtYW5jZS90c2NvbmZpZy5qc29uUEsBAh4DCgAAAAAAl1BYXcUgt9Y0AQAA
NAEAAB0AAAAAAAAAAAAAAKSBk1cAAGJjMjUwLXBlcmZvcm1hbmNlL3BsdWdpbi5qc29uUEsBAh4D
CgAAAAAAl1BYXV9roNRIAAAASAAAACIAAAAAAAAAAAAAAKSBAlkAAGJjMjUwLXBlcmZvcm1hbmNl
L3JvbGx1cC5jb25maWcuanNQSwUGAAAAAAsACwAnAwAAilkAAAAA
B64_BC250_PERFORMANCE
            ;;
        *) return 1 ;;
    esac
    [ -s "$2" ]
}

# One menu option, for the System Updates plugin's Tools tab: install or
# remove by the marker name each option keeps in $STATE_DIR. Nobody is at a
# keyboard, so every question takes its default (keep data, skip the flash).
setup_action() {
    case "$1:$2" in
        install:cec)       cec_install ;;
        install:led)       led_install ;;
        install:power)     power_install ;;
        install:guide)     guide_install ;;
        install:atv)       atv_install ;;
        install:xcloud)    xcloud_install ;;
        install:gfn)       gfn_install ;;
        install:discord)   discord_install ;;
        install:jd)        jd_install ;;
        # The AUR helper would ask for a password; build it the way
        # --update-ctlcenter does instead.
        install:ctlcenter) aur_build_install bc250-control-center-git && mark ctlcenter ;;
        install:boot)      boot_install ;;
        install:streamres) streamres_install ;;
        install:claude)    claude_install ;;
        remove:cec)        cec_revert ;;
        remove:led)        led_revert ;;
        remove:power)      power_revert ;;
        remove:guide)      guide_revert ;;
        remove:atv)        atv_revert ;;
        remove:xcloud)     xcloud_revert ;;
        remove:gfn)        gfn_revert ;;
        remove:discord)    discord_revert ;;
        remove:jd)         jd_revert ;;
        remove:ctlcenter)  ctlcenter_revert ;;
        remove:boot)       boot_revert ;;
        remove:streamres)  streamres_revert ;;
        remove:claude)     claude_revert ;;
        *) warn "no such option: $1 $2"; return 2 ;;
    esac
}

# Decky plugins for the System Updates Tools tab. --plugins prints one line
# per plugin on offer: PLUGIN, id, name, state, installed and offered
# version, source (tab-separated). Updates stay with System Updates and
# Decky's store, so these only install and remove. Decky is not restarted.
decky_plugins_list() {
    decky_catalog
    _n=$(wc -l < "$DECKY_CATALOG")
    _i=1
    while [ "$_i" -le "$_n" ]; do
        printf 'PLUGIN\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(cat_field "$_i" 2)" "$(cat_field "$_i" 3)" \
            "$(cat_state "$_i")" "$(cat_installed_version "$_i")" "$(cat_field "$_i" 5)" "$(cat_field "$_i" 1)"
        _i=$((_i + 1))
    done
    rm -f "$DECKY_CATALOG"
}

decky_plugin_action() {
    [ -n "$2" ] || { warn "no plugin named"; return 2; }
    if [ "$1" = remove ] && [ "$2" = system-updates ]; then
        warn "System Updates can't remove itself; use the setup tool's menu."
        return 2
    fi
    decky_present || { warn "Decky Loader isn't installed."; return 1; }
    pacman -S --needed --noconfirm unzip >/dev/null 2>&1 || true
    decky_catalog
    _n=$(wc -l < "$DECKY_CATALOG")
    _i=1 _hit=0 _rc=0
    while [ "$_i" -le "$_n" ]; do
        if [ "$(cat_field "$_i" 2)" = "$2" ]; then
            _hit=1
            if [ "$1" = install ]; then
                cat_install "$_i" && mark decky || _rc=1
            else
                cat_remove "$_i" || _rc=1
            fi
        fi
        _i=$((_i + 1))
    done
    rm -f "$DECKY_CATALOG"
    [ "$_hit" -eq 1 ] || { warn "no such plugin: $2"; return 2; }
    [ "$_rc" -eq 0 ] && say "Restart Decky to load the change."
    return $_rc
}

# System Updates runs `bc250-setup.sh --refresh` after it updates this file,
# so what the new version writes to disk is applied without opening the menu.
# It also runs --update-led and --update-ctlcenter when their upstream repos
# move on, and its Tools tab runs --install/--remove <option>, --install-all,
# --status, --test-cec, --plugins and --plugin-install/--plugin-remove <id>.
# None of them ask anything.
case "${1:-}" in
    --refresh)
        UNATTENDED=1
        refresh_installed
        exit 0 ;;
    --update-led)
        UNATTENDED=1
        led_install || exit 1
        exit 0 ;;
    --update-ctlcenter)
        UNATTENDED=1
        aur_build_install bc250-control-center-git || exit 1
        exit 0 ;;
    --install|--remove)
        UNATTENDED=1
        setup_action "${1#--}" "${2:-}" || exit 1
        exit 0 ;;
    --install-all)
        UNATTENDED=1
        install_all
        exit 0 ;;
    --status)
        UNATTENDED=1
        show_status || exit 1
        exit 0 ;;
    --test-cec)
        UNATTENDED=1
        cec_test || exit 1
        exit 0 ;;
    --plugins)
        UNATTENDED=1
        decky_plugins_list
        exit 0 ;;
    --plugin-install|--plugin-remove)
        UNATTENDED=1
        decky_plugin_action "${1#--plugin-}" "${2:-}" || exit 1
        exit 0 ;;
esac

main_menu
