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
    return subprocess.run(["/usr/bin/waydroid", "shell", *cmd],
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


def purge(paths):
    """Drop host devices other than Steam's pad from Android."""
    # Names are read again now: a node that has only just appeared can
    # briefly have none, and Steam's pads must stay.
    paths = [p for p in paths if os.path.exists(p) and not name(p).startswith(PAD)]
    if paths and own_dev_input():
        try:
            shell("rm", "-f", *sorted(paths))
        except (OSError, subprocess.SubprocessError):
            pass


fds = {}            # fd -> path, Steam pads held open
down = {}           # (fd, button) -> time it went down, None once fired
seen = set()        # every event node seen so far
was_up = None       # unknown until the first scan
purges = []         # (when, paths)
next_scan = 0.0
while True:
    now = time.monotonic()
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
        if not up:
            purges.clear()
        was_up = up
    for item in [p for p in purges if p[0] <= now]:
        purges.remove(item)
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
            if android_up():
                home()
HOMEBTN
    chmod 755 /usr/local/bin/atv-home-button

    cat > /etc/systemd/system/atv-home-button.service << 'UNIT'
[Unit]
Description=Android TV: hold View/Create or Menu/Options for Home; keep reconnected controllers out
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

    cat > "$REAL_HOME/waydroid-tv.sh" << 'LAUNCH'
#!/bin/bash
# Android TV (Waydroid) launcher for game mode
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
'
waydroid session stop
LAUNCH
    chmod +x "$REAL_HOME/waydroid-tv.sh"
    chown "$REAL_USER" "$REAL_HOME/waydroid-tv.sh"

}

atv_install() {
    say "Android TV (Waydroid) for game mode"

    pacman -S --needed --noconfirm waydroid cage wlr-randr unzip

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
          /usr/local/bin/atv-home-button /usr/local/bin/atv-home-combo

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
        discord_credentials
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
AxQAAAAIALcESF2iWDQ6jwsAAL4eAAAhAAAAAAAAAAEAAACkgX8iAABiYzI1MC1saWdodGluZy9w
eV9tb2R1bGVzL2lkbGUucHlQSwECHgMUAAAACACZMCNd0Is5XXgNAAClJQAAJAAAAAAAAAABAAAA
pIFNLgAAYmMyNTAtbGlnaHRpbmcvcHlfbW9kdWxlcy9lZmZlY3RzLnB5UEsBAh4DFAAAAAgAmTAj
XQRI5vtmCgAAaR0AACMAAAAAAAAAAQAAAKSBBzwAAGJjMjUwLWxpZ2h0aW5nL3B5X21vZHVsZXMv
bm9sbGllLnB5UEsBAh4DFAAAAAgAKSJHXaBqXvpDFwAApkQAACIAAAAAAAAAAQAAAKSBrkYAAGJj
MjUwLWxpZ2h0aW5nL3B5X21vZHVsZXMvc3RyaXAucHlQSwECHgMKAAAAAACZMCNdAAAAAAAAAAAA
AAAAEwAAAAAAAAAAABAA7UExXgAAYmMyNTAtbGlnaHRpbmcvc3JjL1BLAQIeAxQAAAAIACEaSF3j
K5kiMR0AAJZ0AAAcAAAAAAAAAAEAAACkgWJeAABiYzI1MC1saWdodGluZy9zcmMvaW5kZXgudHN4
UEsBAh4DCgAAAAAAKBpIXQAAAAAAAAAAAAAAABQAAAAAAAAAAAAQAO1BzXsAAGJjMjUwLWxpZ2h0
aW5nL2Rpc3QvUEsBAh4DFAAAAAgAKBpIXXBN9I7xIQAAuIMAABwAAAAAAAAAAQAAAKSB/3sAAGJj
MjUwLWxpZ2h0aW5nL2Rpc3QvaW5kZXguanNQSwECHgMUAAAACACZMCNd2prdwkkMAAC8IgAAHgAA
AAAAAAABAAAApIEqngAAYmMyNTAtbGlnaHRpbmcvbm9sbGllLXByb2JlLnB5UEsBAh4DFAAAAAgA
xQRIXWp0csQhGAAAjTcAABgAAAAAAAAAAQAAAKSBr6oAAGJjMjUwLWxpZ2h0aW5nL1JFQURNRS5t
ZFBLAQIeAxQAAAAIAM6sSF19xFXbIAEAAA4CAAAbAAAAAAAAAAEAAACkgQbDAABiYzI1MC1saWdo
dGluZy9wYWNrYWdlLmpzb25QSwECHgMUAAAACACZMCNd1oW0M68AAAAYAQAAHAAAAAAAAAABAAAA
pIFfxAAAYmMyNTAtbGlnaHRpbmcvdHNjb25maWcuanNvblBLAQIeAxQAAAAIAM6sSF3lgGpyvgAA
ABkBAAAaAAAAAAAAAAEAAACkgUjFAABiYzI1MC1saWdodGluZy9wbHVnaW4uanNvblBLAQIeAxQA
AAAIAJkwI11fa6DUNwAAAEgAAAAfAAAAAAAAAAEAAACkgT7GAABiYzI1MC1saWdodGluZy9yb2xs
dXAuY29uZmlnLmpzUEsFBgAAAAARABEA3AQAALLGAAAAAA==
B64_BC250_LIGHTING
            ;;
        system-updates)
            base64 -d > "$2" <<'B64_SYSTEM_UPDATES'
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
AAHUAAAAAA==
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
AAALAAsA6QIAAFrJAgAAAA==
B64_DISCORD_DECK
            ;;
        cec-remote)
            base64 -d > "$2" <<'B64_CEC_REMOTE'
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
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

# System Updates runs `bc250-setup.sh --refresh` after it updates this file,
# so what the new version writes to disk is applied without opening the menu.
# It also runs --update-led and --update-ctlcenter when their upstream repos
# move on; neither asks anything.
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
esac

main_menu
