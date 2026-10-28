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
yUCVikg/g5dKs/X72j+lita6hX9uyrd+wjOjXw3F/JHlErrEW/+/ek/4ljVlvXGxgU5jMtOynJZJ
vk2+AVBLAwQUAAAACAD5g0xd1ezKoNUAAABBAQAAGgAAAFN5c3RlbSBVcGRhdGVzL3BsdWdpbi5q
c29uNZA9TwMxDIb3+xWW5wNBJRbWDkyIoeqEKuTmco1FvpQ4oKjqfyeX0PH1Yz92cp0A0JPT+Ap4
qFm0g2NcSHTGeWNUxIS00bPavTw9ZC0lDrRauuRGPjGFIHga/ZG/fnTKHHxDz70Wy9lyNi1fW2wF
uQ/mvhFnwCJsWeqwtJZFZ5U4yvDg3mj1DWtIQH4B9lnIWtiTMvXjAEMDZRwOawoO3tqj4D0seoZf
FgM+CK+saDNmEEMCwdsKKyfdxffpjkhJaRsqOBLR6RH/z2JHl/5X2PJtuk1/UEsDBBQAAAAIALgh
KV3BWlq8OQAAAEoAAAAfAAAAU3lzdGVtIFVwZGF0ZXMvcm9sbHVwLmNvbmZpZy5qc8vMLcgvKlFI
SU3OrgzIKU3PzFNIK8rPVVByAAvpF+Xn5JQWKFlzcaVWQFWmJZbmoOjQqK7VtOYCAFBLAQIeAwoA
AAAAANK6XF0AAAAAAAAAAAAAAAAPAAAAAAAAAAAAEADtQQAAAABTeXN0ZW0gVXBkYXRlcy9QSwEC
HgMUAAAACACSulxdFyNroNxcAAAZUwEAFgAAAAAAAAABAAAApIEtAAAAU3lzdGVtIFVwZGF0ZXMv
bWFpbi5weVBLAQIeAwoAAAAAAKS6XF0AAAAAAAAAAAAAAAATAAAAAAAAAAAAEADtQT1dAABTeXN0
ZW0gVXBkYXRlcy9zcmMvUEsBAh4DFAAAAAgApLpcXYgAg4FAMQAAEsUAABwAAAAAAAAAAQAAAKSB
bl0AAFN5c3RlbSBVcGRhdGVzL3NyYy9pbmRleC50c3hQSwECHgMKAAAAAADOulxdAAAAAAAAAAAA
AAAAFAAAAAAAAAAAABAA7UHojgAAU3lzdGVtIFVwZGF0ZXMvZGlzdC9QSwECHgMUAAAACADOulxd
ZUykYXQsAAC5tgAAHAAAAAAAAAABAAAApIEajwAAU3lzdGVtIFVwZGF0ZXMvZGlzdC9pbmRleC5q
c1BLAQIeAxQAAAAIAM26XF0jlOCw/AwAANUaAAAYAAAAAAAAAAEAAACkgci7AABTeXN0ZW0gVXBk
YXRlcy9SRUFETUUubWRQSwECHgMUAAAACADNulxd4bO7I/cAAADWAQAAGwAAAAAAAAABAAAApIH6
yAAAU3lzdGVtIFVwZGF0ZXMvcGFja2FnZS5qc29uUEsBAh4DFAAAAAgAuCEpXQvek9PpAAAAlAEA
ABwAAAAAAAAAAQAAAKSBKsoAAFN5c3RlbSBVcGRhdGVzL3RzY29uZmlnLmpzb25QSwECHgMUAAAA
CAD5g0xd1ezKoNUAAABBAQAAGgAAAAAAAAABAAAApIFNywAAU3lzdGVtIFVwZGF0ZXMvcGx1Z2lu
Lmpzb25QSwECHgMUAAAACAC4ISldwVpavDkAAABKAAAAHwAAAAAAAAABAAAApIFazAAAU3lzdGVt
IFVwZGF0ZXMvcm9sbHVwLmNvbmZpZy5qc1BLBQYAAAAACwALAAYDAADQzAAAAAA=
B64_SYSTEM_UPDATES
            ;;
        discord-deck)
            base64 -d > "$2" <<'B64_DISCORD_DECK'
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
AAAA
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
