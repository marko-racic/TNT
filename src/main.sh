#!/bin/bash
printf '\033]0;TNT — Troubleshooting Network Tool\007'
# Resize this existing Terminal window only.
printf '\033[8;44;110t'
set -u

RESET='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'

APP_VERSION="2.5.0"

APP_SUPPORT_DIR="$HOME/Library/Application Support/TNT"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/TNT.log"
BACKUP_FILE="$APP_SUPPORT_DIR/network-backup.conf"
LAST_SERVICE_FILE="$APP_SUPPORT_DIR/last-service.txt"

mkdir -p "$APP_SUPPORT_DIR" "$LOG_DIR"

log_event() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' \
        "$(/bin/date '+%Y-%m-%d %H:%M:%S')" \
        "$level" "$*" >> "$LOG_FILE"
}

log_event INFO "TNT ${APP_VERSION} started"

backup_current_configuration() {
    local service="$1"
    local info dns

    [[ -z "$service" ]] && return 1

    info=$(/usr/sbin/networksetup -getinfo "$service" 2>/dev/null || true)
    dns=$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)

    {
        printf 'BACKUP_VERSION=1\n'
        printf 'SERVICE=%q\n' "$service"
        printf 'INFO_B64=%q\n' "$(printf '%s' "$info" | /usr/bin/base64)"
        printf 'DNS_B64=%q\n' "$(printf '%s' "$dns" | /usr/bin/base64)"
        printf 'CREATED_AT=%q\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')"
    } > "$BACKUP_FILE"

    log_event INFO "Saved network configuration backup for service: $service"
}

extract_info_value() {
    local info="$1"
    local key="$2"
    printf '%s\n' "$info" |
        /usr/bin/awk -F': ' -v key="$key" '$1 == key {print $2; exit}'
}

restore_saved_configuration() {
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo -e "${YELLOW}No saved network configuration backup exists.${RESET}"
        pause
        return 1
    fi

    # shellcheck disable=SC1090
    source "$BACKUP_FILE"

    local info dns config ip mask router
    info=$(printf '%s' "$INFO_B64" | /usr/bin/base64 --decode 2>/dev/null || true)
    dns=$(printf '%s' "$DNS_B64" | /usr/bin/base64 --decode 2>/dev/null || true)

    config=$(extract_info_value "$info" "Configuration")
    ip=$(extract_info_value "$info" "IP address")
    mask=$(extract_info_value "$info" "Subnet mask")
    router=$(extract_info_value "$info" "Router")

    echo
    echo -e "${CYAN}Restoring saved settings for: ${SERVICE}${RESET}"
    remember_service "$SERVICE"

    if printf '%s\n' "$info" | /usr/bin/grep -qi "DHCP Configuration"; then
        config="DHCP"
    fi

    if [[ "$config" == "DHCP" ]]; then
        sudo /usr/sbin/networksetup -setdhcp "$SERVICE" || return 1
    elif [[ -n "$ip" && -n "$mask" && -n "$router" ]]; then
        sudo /usr/sbin/networksetup -setmanual "$SERVICE" "$ip" "$mask" "$router" || return 1
    else
        echo -e "${RED}The saved IP configuration could not be interpreted.${RESET}"
        log_event ERROR "Could not interpret backup for service: $SERVICE"
        pause
        return 1
    fi

    if [[ "$dns" == *"There aren't any DNS Servers set"* || -z "$dns" ]]; then
        sudo /usr/sbin/networksetup -setdnsservers "$SERVICE" Empty
    else
        local -a dns_servers=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && dns_servers+=("$line")
        done <<< "$dns"
        sudo /usr/sbin/networksetup -setdnsservers "$SERVICE" "${dns_servers[@]}"
    fi

    log_event INFO "Restored saved network configuration for service: $SERVICE"
    echo -e "${GREEN}Saved network configuration restored.${RESET}"
    pause
}

connectivity_check() {
    local gateway="$1"

    if [[ -n "$gateway" ]] && /sbin/ping -c 2 -W 1000 "$gateway" >/dev/null 2>&1; then
        return 0
    fi

    if /sbin/ping -c 2 -W 1000 1.1.1.1 >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

run_self_test() {
    draw_common_screen_header "SELF-TEST"

    local failures=0
    local command

    for command in \
        /usr/sbin/networksetup \
        /usr/sbin/ipconfig \
        /usr/sbin/scutil \
        /sbin/route \
        /sbin/ping \
        /usr/bin/curl \
        /usr/bin/pbcopy \
        /usr/bin/osascript; do
        if [[ -x "$command" ]]; then
            echo -e "${GREEN}PASS${RESET}  $command"
        else
            echo -e "${RED}FAIL${RESET}  $command"
            failures=$((failures + 1))
        fi
    done

    local active service
    active=$(get_active_interface)
    service=$(get_network_service "$active")

    [[ -n "$active" ]] && \
        echo -e "${GREEN}PASS${RESET}  Active interface: $active" || {
            echo -e "${RED}FAIL${RESET}  No active interface detected"
            failures=$((failures + 1))
        }

    [[ -n "$service" ]] && \
        echo -e "${GREEN}PASS${RESET}  Active service: $service" || {
            echo -e "${RED}FAIL${RESET}  No active network service detected"
            failures=$((failures + 1))
        }

    if /usr/bin/curl -4 -fsS --max-time 4 https://api.ipify.org >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${RESET}  Public-IP lookup"
    else
        echo -e "${YELLOW}WARN${RESET}  Public-IP lookup unavailable"
    fi

    if [[ -w "$LOG_DIR" ]]; then
        echo -e "${GREEN}PASS${RESET}  Log directory writable"
    else
        echo -e "${RED}FAIL${RESET}  Log directory not writable"
        failures=$((failures + 1))
    fi

    echo
    if (( failures == 0 )); then
        echo -e "${GREEN}Self-test completed successfully.${RESET}"
        log_event INFO "Self-test completed successfully"
    else
        echo -e "${RED}Self-test completed with ${failures} failure(s).${RESET}"
        log_event ERROR "Self-test completed with $failures failure(s)"
    fi

    pause
}


# Timed dashboard refresh mode. Adapter-change detection always remains active.

REFRESH_MODE="10s"
DIAGNOSTIC_INPUT=""

LAST_REFRESH_EPOCH=0
LAST_REFRESH_TIME="--:--:--"

mark_dashboard_refreshed() {
    LAST_REFRESH_EPOCH=$(/bin/date +%s)
    LAST_REFRESH_TIME=$(/bin/date '+%H:%M:%S')
}

refresh_age_seconds() {
    local now

    now=$(/bin/date +%s)

    if (( LAST_REFRESH_EPOCH <= 0 || now < LAST_REFRESH_EPOCH )); then
        echo 999
    else
        echo $((now - LAST_REFRESH_EPOCH))
    fi
}

format_refresh_age() {
    local age="$1"

    if (( age < 60 )); then
        printf '%ss ago' "$age"
    else
        printf '%sm ago' $((age / 60))
    fi
}

refresh_age_color() {
    local age="$1"

    if (( age <= 10 )); then
        printf '%s' "$GREEN"
    elif (( age <= 30 )); then
        printf '%s' "$YELLOW"
    else
        printf '%s' "$RED"
    fi
}


get_refresh_seconds() {
    case "$REFRESH_MODE" in
        5s) echo 5 ;;
        10s) echo 10 ;;
        Off) echo 0 ;;
        *) echo 10 ;;
    esac
}

toggle_refresh_mode() {
    case "$REFRESH_MODE" in
        Off) REFRESH_MODE="10s" ;;
        10s) REFRESH_MODE="5s" ;;
        5s) REFRESH_MODE="Off" ;;
        *) REFRESH_MODE="10s" ;;
    esac
}

echo "TNT requires administrator access."
if ! sudo -v; then
    echo "Administrator authentication failed."
    read -r -p "Press Return to close..." _
    exit 1
fi

# Required on macOS Tahoe 26 to expose SSID in ipconfig summary.
sudo /usr/sbin/ipconfig setverbose 1 >/dev/null 2>&1 || true

# Refresh the sudo timestamp while this toolbox remains open.
(
    while true; do
        sudo -n true >/dev/null 2>&1 || exit
        /bin/sleep 60
    done
) &
SUDO_KEEPALIVE_PID=$!

cleanup_toolbox() {
    /bin/stty sane 2>/dev/null || true
    printf '\033[r'
    log_event INFO "TNT stopped"
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        /bin/kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    fi
}

trap cleanup_toolbox EXIT INT TERM

pause() {
    echo
    read -r -p "Press Return to continue..." _
}


get_terminal_columns() {
    local cols=""

    # stty reads the current TTY dimensions directly and is more reliable
    # than tput when Terminal was resized after the shell started.
    cols=$(/bin/stty size 2>/dev/null | /usr/bin/awk '{print $2}')

    if [[ -z "$cols" || ! "$cols" =~ ^[0-9]+$ ]]; then
        cols=$(tput cols 2>/dev/null || true)
    fi

    if [[ -z "$cols" || ! "$cols" =~ ^[0-9]+$ ]]; then
        cols=${COLUMNS:-110}
    fi

    printf '%s\n' "$cols"
}

repeat_char() {
    local count="$1"
    local char="$2"
    (( count < 0 )) && count=0
    printf '%*s' "$count" '' | tr ' ' "$char"
}

fit_text() {
    local text="$1"
    local width="$2"

    if (( width <= 0 )); then
        return
    fi

    if (( ${#text} > width )); then
        printf "%s" "${text:0:$width}"
    else
        printf "%-*s" "$width" "$text"
    fi
}

status_color() {
    case "$1" in
        ok) echo "$GREEN" ;;
        warn) echo "$YELLOW" ;;
        bad) echo "$RED" ;;
        *) echo "$GRAY" ;;
    esac
}


get_mac_address() {
    local interface="$1"
    local mac=""

    [[ -z "$interface" ]] && return

    mac=$(/sbin/ifconfig "$interface" 2>/dev/null |
        /usr/bin/awk '/^[[:space:]]*ether / {print $2; exit}')

    if [[ -z "$mac" ]]; then
        mac=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null |
            /usr/bin/awk -v wanted="$interface" '
                /^Device:/ {
                    device=$2
                }
                /^Ethernet Address:/ {
                    if (device == wanted) {
                        print $3
                        exit
                    }
                }
            ')
    fi

    printf '%s\n' "$mac"
}

get_active_interface() {
    local interface wifi_interface wifi_service wifi_state
    local service last_service backup_service

    # Prefer a valid default-route interface.
    interface=$(/sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/interface:/{print $2; exit}')

    if [[ -n "$interface" ]]; then
        echo "$interface"
        return
    fi

    # A physically linked non-Wi-Fi adapter remains selectable even when
    # its gateway/default route is invalid.
    while IFS= read -r interface; do
        [[ -z "$interface" ]] && continue

        if interface_link_active "$interface"; then
            echo "$interface"
            return
        fi
    done < <(
        /usr/sbin/networksetup -listallhardwareports 2>/dev/null |
        /usr/bin/awk '
            /^Hardware Port:/ {
                port=$0
                sub(/^Hardware Port: /, "", port)
            }
            /^Device:/ {
                if (port !~ /Wi-Fi|AirPort/) print $2
            }
        '
    )

    # Wi-Fi must be considered active independently of gateway reachability.
    wifi_interface=$(get_wifi_interface)

    if [[ -n "$wifi_interface" ]]; then
        wifi_service=$(get_network_service "$wifi_interface")
        wifi_state=$(/usr/sbin/networksetup \
            -getairportnetwork "$wifi_interface" 2>/dev/null || true)

        if [[ "$wifi_state" != *"not associated"* ]] ||
           interface_link_active "$wifi_interface" ||
           service_has_configured_ip "$wifi_service"; then
            echo "$wifi_interface"
            return
        fi
    fi

    # Recover through the last remembered service.
    last_service=$(get_last_service)
    interface=$(get_interface_for_service "$last_service")

    if [[ -n "$interface" ]]; then
        echo "$interface"
        return
    fi

    # Recover through the service stored in the backup.
    backup_service=$(get_backup_service)
    interface=$(get_interface_for_service "$backup_service")

    if [[ -n "$interface" ]]; then
        echo "$interface"
        return
    fi

    # Last resort: any service with a configured IP.
    while IFS= read -r service; do
        [[ -z "$service" || "$service" == \** ]] && continue

        if service_has_configured_ip "$service"; then
            interface=$(get_interface_for_service "$service")
            [[ -n "$interface" ]] && {
                echo "$interface"
                return
            }
        fi
    done < <(
        /usr/sbin/networksetup -listallnetworkservices 2>/dev/null |
        /usr/bin/tail -n +2
    )

    # Keep Wi-Fi recoverable even if Tahoe hides association information.
    [[ -n "$wifi_interface" ]] && echo "$wifi_interface"
}

get_wifi_interface() {
    /usr/sbin/networksetup -listallhardwareports 2>/dev/null |
    awk '
        /^Hardware Port: (Wi-Fi|AirPort)$/ { found=1; next }
        found && /^Device:/ { print $2; exit }
    '
}

get_network_service() {
    local interface="$1"

    /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null |
    awk -v iface="$interface" '
        /^\([0-9]+\)/ {
            service=$0
            sub(/^\([0-9]+\) /, "", service)
        }
        $0 ~ "Device: " iface "\\)" {
            print service
            exit
        }
    '
}

remember_service() {
    local service="$1"
    [[ -n "$service" ]] && printf '%s\n' "$service" > "$LAST_SERVICE_FILE"
}

get_last_service() {
    [[ -s "$LAST_SERVICE_FILE" ]] && /bin/cat "$LAST_SERVICE_FILE"
}

get_backup_service() {
    [[ -f "$BACKUP_FILE" ]] || return

    /usr/bin/awk -F= '
        /^SERVICE=/ {
            value=substr($0, index($0, "=") + 1)
            gsub(/^'\''|'\''$/, "", value)
            gsub(/\\ /, " ", value)
            print value
            exit
        }
    ' "$BACKUP_FILE"
}

get_interface_for_service() {
    local wanted="$1"
    [[ -z "$wanted" ]] && return

    /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null |
    /usr/bin/awk -v wanted="$wanted" '
        /^\([0-9]+\)/ {
            service=$0
            sub(/^\([0-9]+\) /, "", service)
        }
        service == wanted && /Device:/ {
            line=$0
            sub(/^.*Device: /, "", line)
            sub(/\).*$/, "", line)
            print line
            exit
        }
    '
}

interface_link_active() {
    local interface="$1"
    /sbin/ifconfig "$interface" 2>/dev/null |
        /usr/bin/grep -q "status: active"
}

service_has_configured_ip() {
    local service="$1"
    local value

    [[ -z "$service" ]] && return 1

    value=$(/usr/sbin/networksetup -getinfo "$service" 2>/dev/null |
        /usr/bin/awk -F': ' '/^IP address:/ {print $2; exit}')

    [[ -n "$value" && "$value" != "none" ]]
}


get_private_ip() {
    local interface="$1"
    local service value

    service=$(get_network_service "$interface")

    if [[ -n "$service" ]]; then
        value=$(/usr/sbin/networksetup -getinfo "$service" 2>/dev/null |
            /usr/bin/awk -F': ' '/^IP address:/ {print $2; exit}')

        if [[ -n "$value" && "$value" != "none" ]]; then
            echo "$value"
            return
        fi
    fi

    /usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true
}

get_subnet_mask() {
    local interface="$1"
    local service value

    service=$(get_network_service "$interface")

    if [[ -n "$service" ]]; then
        value=$(/usr/sbin/networksetup -getinfo "$service" 2>/dev/null |
            /usr/bin/awk -F': ' '/^Subnet mask:/ {print $2; exit}')

        if [[ -n "$value" && "$value" != "none" ]]; then
            echo "$value"
            return
        fi
    fi

    /usr/sbin/ipconfig getoption "$interface" subnet_mask 2>/dev/null || true
}

get_gateway() {
    local service="${1:-}"
    local value

    value=$(/sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/gateway:/{print $2; exit}')

    if [[ -n "$value" ]]; then
        echo "$value"
        return
    fi

    [[ -z "$service" ]] && return

    /usr/sbin/networksetup -getinfo "$service" 2>/dev/null |
        /usr/bin/awk -F': ' '/^Router:/ {print $2; exit}'
}

get_public_ip() {
    local provider ip
    local providers=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    for provider in "${providers[@]}"; do
        ip=$(/usr/bin/curl -4 -fsS --max-time 3 "$provider" 2>/dev/null || true)
        ip=$(printf '%s' "$ip" | /usr/bin/tr -d '[:space:]')

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return
        fi
    done

    echo "Unavailable"
}

get_dns_servers() {
    local service="${1:-}"
    local output

    output=$(/usr/sbin/scutil --dns 2>/dev/null |
        /usr/bin/awk '/nameserver\[[0-9]+\]/{print $3}' |
        /usr/bin/awk '!seen[$0]++')

    if [[ -n "$output" ]]; then
        printf '%s
' "$output"
        return
    fi

    [[ -z "$service" ]] && return

    output=$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)

    if [[ "$output" != *"There aren't any DNS Servers set"* ]]; then
        printf '%s
' "$output"
    fi
}

get_wifi_ssid() {
    local interface="$1"
    local summary=""
    local value=""

    [[ -z "$interface" ]] && {
        echo "Unavailable"
        return
    }

    summary=$(/usr/sbin/ipconfig getsummary "$interface" 2>/dev/null || true)

    value=$(printf '%s
' "$summary" |
        /usr/bin/awk '
            /^[[:space:]]*SSID[[:space:]]*:/ {
                line=$0
                sub(/^[^:]*:[[:space:]]*/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                print line
                exit
            }
        ')

    if [[ -n "$value" &&
          "$value" != "<redacted>" &&
          "$value" != "(null)" ]]; then
        echo "$value"
        return
    fi

    value=$(/usr/sbin/networksetup \
        -getairportnetwork "$interface" 2>/dev/null || true)
    value=${value#Current Wi-Fi Network: }

    if [[ -n "$value" &&
          "$value" != *"not associated"* &&
          "$value" != *"<redacted>"* ]]; then
        echo "$value"
        return
    fi

    if [[ -n "$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)" ]]; then
        echo "Connected (SSID unavailable)"
    else
        echo "Not connected"
    fi
}
get_vpn_status() {
    /usr/sbin/scutil --nc list 2>/dev/null |
    awk '
        /\(Connected\)/ {
            if (match($0, /"[^"]+"/)) {
                print substr($0, RSTART+1, RLENGTH-2)
                found=1
            }
        }
        END {
            if (!found) print "Disconnected"
        }
    '
}

get_location() {
    /usr/sbin/networksetup -getcurrentlocation 2>/dev/null || echo "Unavailable"
}

get_ip_mode() {
    local service="$1"
    local interface="$2"
    local info=""

    if [[ -n "$service" ]]; then
        info=$(/usr/sbin/networksetup -getinfo "$service" 2>/dev/null || true)

        if printf '%s\n' "$info" | /usr/bin/grep -qi "DHCP Configuration"; then
            echo "DHCP"
            return
        fi

        if printf '%s\n' "$info" | /usr/bin/grep -Eqi \
            "Manual Configuration|Manually configured|Static Configuration"; then
            echo "Manual"
            return
        fi

        # Compatibility with older macOS output.
        if printf '%s\n' "$info" | /usr/bin/grep -Eqi "^Configuration:[[:space:]]*DHCP"; then
            echo "DHCP"
            return
        fi

        if printf '%s\n' "$info" | /usr/bin/grep -Eqi "^Configuration:[[:space:]]*Manual"; then
            echo "Manual"
            return
        fi
    fi

    # A current DHCP packet is a reliable fallback for the active interface.
    if [[ -n "$interface" ]] &&
       /usr/sbin/ipconfig getpacket "$interface" 2>/dev/null |
       /usr/bin/grep -q "yiaddr"; then
        echo "DHCP"
        return
    fi

    # If an address exists but no DHCP lease is present, it is most likely manual.
    if [[ -n "$interface" ]] &&
       [[ -n "$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)" ]]; then
        echo "Manual"
        return
    fi

    echo "Unknown"
}

get_ipv6() {
    /sbin/ifconfig "$1" 2>/dev/null |
        awk '/inet6 / && $2 !~ /^fe80/ {print $2; exit}'
}

get_uptime() {
    local boot_epoch now total days hours minutes

    boot_epoch=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null |
        /usr/bin/awk -F'[=,]' '{gsub(/[^0-9]/, "", $2); print $2}')

    if [[ -z "$boot_epoch" ]]; then
        echo "Unavailable"
        return
    fi

    now=$(/bin/date +%s)
    total=$((now - boot_epoch))

    if (( total < 0 )); then
        echo "Unavailable"
        return
    fi

    days=$((total / 86400))
    hours=$(((total % 86400) / 3600))
    minutes=$(((total % 3600) / 60))

    if (( days > 0 )); then
        printf "%d days, %d hours, %d min\n" "$days" "$hours" "$minutes"
    elif (( hours > 0 )); then
        printf "%d hours, %d min\n" "$hours" "$minutes"
    else
        printf "%d min\n" "$minutes"
    fi
}


dns_provider_name() {
    case "$1" in
        1.1.1.1|1.0.0.1) echo "Cloudflare" ;;
        8.8.8.8|8.8.4.4) echo "Google" ;;
        9.9.9.9|149.112.112.112) echo "Quad9" ;;
        208.67.222.222|208.67.220.220) echo "OpenDNS" ;;
        "") echo "Unavailable" ;;
        *) echo "Custom" ;;
    esac
}

extract_ping_ms() {
    /usr/bin/awk -F'time=' '
        /time=/ {
            split($2, values, " ")
            print values[1]
            exit
        }
    '
}

latency_state() {
    local value="$1"
    local whole

    if [[ -z "$value" || "$value" == "timeout" ]]; then
        echo "bad"
        return
    fi

    if [[ "$value" == "reachable" ]]; then
        echo "ok"
        return
    fi

    whole=${value%%.*}

    if (( whole < 50 )); then
        echo "ok"
    elif (( whole < 120 )); then
        echo "warn"
    else
        echo "bad"
    fi
}

check_ping_latency() {
    local target="$1"
    local output latency

    [[ -z "$target" ]] && {
        echo "timeout"
        return
    }

    output=$(/sbin/ping -c 1 -W 1000 "$target" 2>/dev/null || true)
    latency=$(printf '%s\n' "$output" | extract_ping_ms)
    echo "${latency:-timeout}"
}

check_dns_health() {
    local dns_server="$1"
    local output latency

    [[ -z "$dns_server" ]] && {
        echo "timeout"
        return
    }

    output=$(/usr/bin/dig +time=2 +tries=1 @"$dns_server" example.com A 2>/dev/null || true)

    if printf '%s\n' "$output" | /usr/bin/grep -q "status: NOERROR"; then
        latency=$(printf '%s\n' "$output" |
            /usr/bin/awk '/Query time:/ {print $4; exit}')
        echo "${latency:-reachable}"
    else
        echo "timeout"
    fi
}

check_internet_health() {
    local output latency

    output=$(/sbin/ping -c 1 -W 1000 1.1.1.1 2>/dev/null || true)
    latency=$(printf '%s\n' "$output" | extract_ping_ms)

    if [[ -n "$latency" ]]; then
        echo "$latency"
    elif /usr/bin/curl -4 -fsS --max-time 3 https://api.ipify.org >/dev/null 2>&1; then
        echo "reachable"
    else
        echo "timeout"
    fi
}

collect_info() {
    ACTIVE_IF=$(get_active_interface)
    WIFI_IF=$(get_wifi_interface)
    SERVICE=""
    PRIVATE_IP=""
    SUBNET=""
    IPV6=""
    ACTIVE_MAC=""

    if [[ -n "$ACTIVE_IF" ]]; then
        SERVICE=$(get_network_service "$ACTIVE_IF")
    fi

    if [[ -z "$SERVICE" ]]; then
        SERVICE=$(get_last_service)
    fi

    if [[ -z "$SERVICE" ]]; then
        SERVICE=$(get_backup_service)
    fi

    if [[ -n "$SERVICE" ]]; then
        remember_service "$SERVICE"

        if [[ -z "$ACTIVE_IF" ]]; then
            ACTIVE_IF=$(get_interface_for_service "$SERVICE")
        fi
    fi

    if [[ -n "$ACTIVE_IF" ]]; then
        PRIVATE_IP=$(get_private_ip "$ACTIVE_IF")
        SUBNET=$(get_subnet_mask "$ACTIVE_IF")
        IPV6=$(get_ipv6 "$ACTIVE_IF")
        ACTIVE_MAC=$(get_mac_address "$ACTIVE_IF")
    fi

    PUBLIC_IP=$(get_public_ip)
    GATEWAY=$(get_gateway "$SERVICE")
    DNS_SERVERS=$(get_dns_servers "$SERVICE")
    SSID=$(get_wifi_ssid "$WIFI_IF")
    VPN=$(get_vpn_status)
    LOCATION=$(get_location)
    IP_MODE=$(get_ip_mode "$SERVICE" "$ACTIVE_IF")
    MACOS=$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo "Unknown")
    HOST=$(/bin/hostname -s 2>/dev/null || echo "Unknown")
    USER_NAME=$(/usr/bin/id -un 2>/dev/null || echo "Unknown")
    UPTIME=$(get_uptime)

    PRIMARY_DNS=$(printf '%s
' "$DNS_SERVERS" | /usr/bin/head -n 1)
    DNS_PROVIDER=$(dns_provider_name "$PRIMARY_DNS")
    GATEWAY_LATENCY=$(check_ping_latency "$GATEWAY")
    DNS_LATENCY=$(check_dns_health "$PRIMARY_DNS")
    INTERNET_LATENCY=$(check_internet_health)
}

print_item() {
    local state="$1"
    local label="$2"
    local value="$3"
    local width="$4"
    local sc

    sc=$(status_color "$state")
    printf "%b●%b " "$sc" "$RESET"
    fit_text "$(printf "%-18s %s" "$label" "$value")" $((width-2))
}

print_empty() {
    local width="$1"
    fit_text "" "$width"
}

print_pair() {
    local left_state="$1"
    local left_label="$2"
    local left_value="$3"
    local right_state="$4"
    local right_label="$5"
    local right_value="$6"
    local col="$7"

    if [[ -n "$left_label" ]]; then
        print_item "$left_state" "$left_label" "$left_value" "$col"
    else
        print_empty "$col"
    fi

    printf " | "

    if [[ -n "$right_label" ]]; then
        print_item "$right_state" "$right_label" "$right_value" "$col"
    else
        print_empty "$col"
    fi

    printf "
"
}

section_pair_header() {
    local left_title="$1"
    local right_title="$2"
    local left_color="$3"
    local right_color="$4"
    local col="$5"

    printf "%b" "$left_color$BOLD"
    fit_text "$left_title" "$col"
    printf "%b | %b" "$RESET" "$right_color$BOLD"
    fit_text "$right_title" "$col"
    printf "%b
" "$RESET"

    printf "%b" "$left_color"
    repeat_char "$col" "-"
    printf "%b | %b" "$RESET" "$right_color"
    repeat_char "$col" "-"
    printf "%b
" "$RESET"
}

full_header() {
    local title="$1"
    local color="$2"
    local width="$3"

    printf "%b%s%b\n" "$color$BOLD" "$title" "$RESET"
    printf "%b" "$color"
    repeat_char "$width" "-"
    printf "%b\n" "$RESET"
}

show_dashboard() {
    collect_info
    mark_dashboard_refreshed

    # Read actual Terminal width after launch and resizing.
    local cols
    cols=$(get_terminal_columns)

    # Use the terminal's actual live width. Keep a practical minimum,
    # but never cap larger Terminal windows.
    if (( cols < 84 )); then
        cols=84
    fi

    # Reserve one safety cell to avoid auto-wrap at the right edge.
    local full=$((cols - 1))
    local col=$(( (full - 3) / 2 ))

    # Keep full exactly equal to both columns plus the center separator.
    full=$((col * 2 + 3))

    clear

    printf "%b" "$GREEN$BOLD"
    repeat_char "$full" "="
    printf "%b\n" "$RESET"

    local header_title="TNT v${APP_VERSION}"
    local title_pad=$(( (full - ${#header_title}) / 2 ))
    (( title_pad < 0 )) && title_pad=0
    printf "%*s%s\n" "$title_pad" "" "$header_title"

    local sub="Troubleshooting Network Tool"
    local sub_pad=$(( (full - ${#sub}) / 2 ))
    (( sub_pad < 0 )) && sub_pad=0
    printf "%b%*s%s%b\n" "$CYAN" "$sub_pad" "" "$sub" "$RESET"

    printf "%b" "$GREEN$BOLD"
    repeat_char "$full" "="
    printf "%b\n\n" "$RESET"

    section_pair_header "NETWORK INTERFACES" "WI-FI / VPN" "$CYAN" "$MAGENTA" "$col"

    print_pair "$([[ -n "$ACTIVE_IF" ]] && echo ok || echo bad)" "Primary interface" "${ACTIVE_IF:-Unavailable}" \
               "$([[ -n "$WIFI_IF" ]] && echo ok || echo warn)" "Wi-Fi interface" "${WIFI_IF:-Unavailable}" "$col"

    print_pair "$([[ -n "$ACTIVE_MAC" ]] && echo ok || echo warn)" "MAC address" "${ACTIVE_MAC:-Unavailable}" \
               none "" "" "$col"

    print_pair "$([[ -n "$SERVICE" ]] && echo ok || echo warn)" "Network service" "${SERVICE:-Unavailable}" \
               "$([[ "$SSID" == "Hidden by macOS" || "$SSID" == "Not connected" || "$SSID" == "Unavailable" ]] && echo warn || echo ok)" "SSID" "$SSID" "$col"

    print_pair "$([[ "$IP_MODE" == "DHCP" ]] && echo ok || echo warn)" "IP configuration" "${IP_MODE:-Unknown}" \
               "$([[ "$VPN" == "Disconnected" ]] && echo warn || echo ok)" "macOS VPN" "$VPN" "$col"

    print_pair "$([[ -n "$PRIVATE_IP" ]] && echo ok || echo bad)" "IPv4 address" "${PRIVATE_IP:-Unavailable}" \
               "$([[ "$LOCATION" != "Unavailable" ]] && echo ok || echo warn)" "Network location" "$LOCATION" "$col"

    print_pair "$([[ -n "$SUBNET" ]] && echo ok || echo warn)" "Subnet mask" "${SUBNET:-Unavailable}" \
               none "" "" "$col"

    print_pair "$([[ -n "$IPV6" ]] && echo ok || echo warn)" "IPv6 address" "${IPV6:-Unavailable}" \
               none "" "" "$col"

    print_pair "$([[ -n "$GATEWAY" ]] && echo ok || echo bad)" "Default gateway" "${GATEWAY:-Unavailable}" \
               none "" "" "$col"

    echo

    section_pair_header "INTERNET" "SYSTEM INFO" "$GREEN" "$YELLOW" "$col"

    print_pair "$([[ "$PUBLIC_IP" != "Unavailable" ]] && echo ok || echo bad)" "Connection" "$([[ "$PUBLIC_IP" != "Unavailable" ]] && echo Online || echo Offline)" \
               ok "macOS" "$MACOS" "$col"

    print_pair "$([[ "$PUBLIC_IP" != "Unavailable" ]] && echo ok || echo bad)" "Public IPv4" "$PUBLIC_IP" \
               ok "Host" "$HOST" "$col"

    print_pair none "" "" ok "User" "$USER_NAME" "$col"
    print_pair none "" "" ok "Uptime" "$UPTIME" "$col"

    echo

    if [[ -n "$SERVICE" && -z "$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')" ]]; then
        full_header "RECOVERY MODE" "$YELLOW" "$full"
        print_item "warn" "Service" "$SERVICE" "$full"
        printf "\n"
        print_item "warn" "Status" "No default route; option 8 can restore settings" "$full"
        printf "\n\n"
    fi

    section_pair_header "NETWORK HEALTH" "DNS SERVERS" "$GREEN" "$BLUE" "$col"

    local gateway_state dns_state internet_state
    local dns_1="" dns_2="" dns_3="" dns_4=""
    local dns_count=0 dns_value=""

    gateway_state=$(latency_state "$GATEWAY_LATENCY")
    dns_state=$(latency_state "$DNS_LATENCY")
    internet_state=$(latency_state "$INTERNET_LATENCY")

    if [[ -n "$DNS_SERVERS" ]]; then
        while IFS= read -r dns_value; do
            [[ -z "$dns_value" ]] && continue
            dns_count=$((dns_count + 1))

            case "$dns_count" in
                1) dns_1="$dns_value" ;;
                2) dns_2="$dns_value" ;;
                3) dns_3="$dns_value" ;;
                4) dns_4="$dns_value" ;;
            esac
        done <<< "$DNS_SERVERS"
    fi

    [[ -z "$dns_1" ]] && dns_1="Unavailable"

    local gateway_value dns_health_value internet_value public_ip_value
    local gateway_health_state dns_health_state internet_health_state public_ip_state

    gateway_health_state="$gateway_state"
    dns_health_state="$dns_state"
    internet_health_state="$internet_state"
    public_ip_state="$([[ "$PUBLIC_IP" != "Unavailable" ]] && echo ok || echo bad)"

    if [[ "$GATEWAY_LATENCY" == "timeout" ]]; then
        gateway_value="FAIL"
    else
        gateway_value="${GATEWAY:-Unavailable} (${GATEWAY_LATENCY} ms)"
    fi

    if [[ "$DNS_LATENCY" == "timeout" ]]; then
        dns_health_value="FAIL (${DNS_PROVIDER})"
    elif [[ "$DNS_LATENCY" == "reachable" ]]; then
        dns_health_value="${PRIMARY_DNS:-Unavailable} ${DNS_PROVIDER} (OK)"
    else
        dns_health_value="${PRIMARY_DNS:-Unavailable} ${DNS_PROVIDER} (${DNS_LATENCY} ms)"
    fi

    if [[ "$INTERNET_LATENCY" == "timeout" ]]; then
        internet_value="FAIL"
    elif [[ "$INTERNET_LATENCY" == "reachable" ]]; then
        internet_value="Reachable"
    else
        internet_value="Reachable (${INTERNET_LATENCY} ms)"
    fi

    public_ip_value="$PUBLIC_IP"

    print_pair "$gateway_health_state" "Gateway" "$gateway_value" \
               "$([[ "$dns_1" == "Unavailable" ]] && echo bad || echo ok)" "DNS 1" "$dns_1" "$col"

    print_pair "$dns_health_state" "DNS" "$dns_health_value" \
               "$([[ -n "$dns_2" ]] && echo ok || echo none)" "$([[ -n "$dns_2" ]] && echo "DNS 2" || echo "")" "$dns_2" "$col"

    print_pair "$internet_health_state" "Internet" "$internet_value" \
               "$([[ -n "$dns_3" ]] && echo ok || echo none)" "$([[ -n "$dns_3" ]] && echo "DNS 3" || echo "")" "$dns_3" "$col"

    print_pair "$public_ip_state" "Public IP" "$public_ip_value" \
               "$([[ -n "$dns_4" ]] && echo ok || echo none)" "$([[ -n "$dns_4" ]] && echo "DNS 4" || echo "")" "$dns_4" "$col"

    echo

    full_header "ACTIONS MENU" "$CYAN" "$full"

    fit_text "1  Refresh information" "$col"
    printf " | "
    fit_text "C  Copy network information" "$col"
    printf "\n"

    fit_text "2  Diagnostics" "$col"
    printf " | "
    fit_text "R  Toggle refresh (${REFRESH_MODE})" "$col"
    printf "\n"

    fit_text "3  Network configuration" "$col"
    printf " | "
    fit_text "A  About TNT" "$col"
    printf "\n"

    fit_text "4  Open Network Settings" "$col"
    printf " | "
    fit_text "Q  Quit" "$col"
    printf "\n"

    printf "%b" "$CYAN"
    repeat_char "$full" "-"
    printf "%b\n\n" "$RESET"
}


is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets

    read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    local octet
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done

    return 0
}

is_valid_subnet_mask() {
    local mask="$1"
    local valid_masks=(
        0.0.0.0
        128.0.0.0 192.0.0.0 224.0.0.0 240.0.0.0
        248.0.0.0 252.0.0.0 254.0.0.0 255.0.0.0
        255.128.0.0 255.192.0.0 255.224.0.0 255.240.0.0
        255.248.0.0 255.252.0.0 255.254.0.0 255.255.0.0
        255.255.128.0 255.255.192.0 255.255.224.0
        255.255.240.0 255.255.248.0 255.255.252.0
        255.255.254.0 255.255.255.0 255.255.255.128
        255.255.255.192 255.255.255.224 255.255.255.240
        255.255.255.248 255.255.255.252
    )

    local valid
    for valid in "${valid_masks[@]}"; do
        [[ "$mask" == "$valid" ]] && return 0
    done

    return 1
}

get_active_service_for_config() {
    local interface service

    interface=$(get_active_interface)
    service=$(get_network_service "$interface")

    [[ -z "$service" ]] && service=$(get_last_service)
    [[ -z "$service" ]] && service=$(get_backup_service)
    [[ -z "$service" ]] && return 1

    remember_service "$service"
    printf '%s
' "$service"
}

set_dhcp_mode() {
    local service

    service=$(get_active_service_for_config) || {
        echo
        echo -e "${RED}Could not determine the active network service.${RESET}"
        pause
        return
    }

    backup_current_configuration "$service"
    echo
    echo -e "${YELLOW}This will change '${service}' to DHCP and automatic DNS.${RESET}"
    read -r -p "Continue? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if sudo /usr/sbin/networksetup -setdhcp "$service" &&
       sudo /usr/sbin/networksetup -setdnsservers "$service" Empty; then
        echo -e "${GREEN}DHCP and automatic DNS enabled for '${service}'.${RESET}"
    else
        echo -e "${RED}Could not enable DHCP.${RESET}"
    fi

    pause
}

set_static_mode() {
    local service ip mask gateway dns_input
    local -a dns_servers=()

    service=$(get_active_service_for_config) || {
        echo
        echo -e "${RED}Could not determine the active network service.${RESET}"
        pause
        return
    }

    backup_current_configuration "$service"
    echo
    echo -e "${CYAN}Configure static IPv4 for: ${service}${RESET}"
    echo

    read -r -p "IPv4 address: " ip
    if ! is_valid_ipv4 "$ip"; then
        echo -e "${RED}Invalid IPv4 address.${RESET}"
        pause
        return
    fi

    read -r -p "Subnet mask [255.255.255.0]: " mask
    mask=${mask:-255.255.255.0}

    if ! is_valid_subnet_mask "$mask"; then
        echo -e "${RED}Invalid or non-contiguous subnet mask.${RESET}"
        pause
        return
    fi

    read -r -p "Default gateway: " gateway
    if ! is_valid_ipv4 "$gateway"; then
        echo -e "${RED}Invalid gateway address.${RESET}"
        pause
        return
    fi

    echo
    read -r -p "DNS servers, separated by spaces [automatic]: " dns_input

    if [[ -n "$dns_input" ]]; then
        read -r -a dns_servers <<< "$dns_input"

        local dns
        for dns in "${dns_servers[@]}"; do
            if ! is_valid_ipv4 "$dns"; then
                echo -e "${RED}Invalid DNS server: ${dns}${RESET}"
                pause
                return
            fi
        done
    fi

    echo
    echo -e "${YELLOW}New configuration:${RESET}"
    echo "  Service : $service"
    echo "  IP      : $ip"
    echo "  Mask    : $mask"
    echo "  Gateway : $gateway"
    echo "  DNS     : ${dns_input:-Automatic}"
    echo
    echo -e "${RED}Warning: an incorrect configuration can disconnect this Mac.${RESET}"
    read -r -p "Apply these settings? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if ! sudo /usr/sbin/networksetup -setmanual \
        "$service" "$ip" "$mask" "$gateway"; then
        echo -e "${RED}Could not apply the static IPv4 configuration.${RESET}"
        pause
        return
    fi

    if [[ ${#dns_servers[@]} -gt 0 ]]; then
        if ! sudo /usr/sbin/networksetup -setdnsservers \
            "$service" "${dns_servers[@]}"; then
            echo -e "${RED}IPv4 was changed, but DNS configuration failed.${RESET}"
            pause
            return
        fi
    else
        sudo /usr/sbin/networksetup -setdnsservers "$service" Empty
    fi

    echo -e "${GREEN}Static network configuration applied.${RESET}"
    log_event INFO "Applied static configuration to $service: IP=$ip MASK=$mask GW=$gateway DNS=${dns_input:-Automatic}"

    echo
    echo -e "${CYAN}Checking connectivity...${RESET}"
    /bin/sleep 2

    if connectivity_check "$gateway"; then
        echo -e "${GREEN}Connectivity check passed.${RESET}"
    else
        echo -e "${RED}Connectivity check failed.${RESET}"
        read -r -p "Restore the previous configuration now? [Y/n]: " rollback
        rollback=${rollback:-Y}

        if [[ "$rollback" =~ ^[Yy]$ ]]; then
            restore_saved_configuration
            return
        fi
    fi

    pause
}

set_custom_dns() {
    local service dns_input
    local -a dns_servers=()

    service=$(get_active_service_for_config) || {
        echo
        echo -e "${RED}Could not determine the active network service.${RESET}"
        pause
        return
    }

    backup_current_configuration "$service"
    echo
    read -r -p "DNS servers, separated by spaces: " dns_input

    if [[ -z "$dns_input" ]]; then
        echo -e "${YELLOW}No DNS servers entered.${RESET}"
        pause
        return
    fi

    read -r -a dns_servers <<< "$dns_input"

    local dns
    for dns in "${dns_servers[@]}"; do
        if ! is_valid_ipv4 "$dns"; then
            echo -e "${RED}Invalid DNS server: ${dns}${RESET}"
            pause
            return
        fi
    done

    if sudo /usr/sbin/networksetup -setdnsservers \
        "$service" "${dns_servers[@]}"; then
        echo -e "${GREEN}DNS servers updated for '${service}'.${RESET}"
    else
        echo -e "${RED}Could not update DNS servers.${RESET}"
    fi

    pause
}

set_automatic_dns() {
    local service

    service=$(get_active_service_for_config) || {
        echo
        echo -e "${RED}Could not determine the active network service.${RESET}"
        pause
        return
    }

    backup_current_configuration "$service"

    if sudo /usr/sbin/networksetup -setdnsservers "$service" Empty; then
        echo -e "${GREEN}Automatic DNS enabled for '${service}'.${RESET}"
    else
        echo -e "${RED}Could not enable automatic DNS.${RESET}"
    fi

    pause
}


show_success_banner() {
    local message="$1"

    echo
    echo -e "${GREEN}${BOLD}✓ ${message}${RESET}"
    echo -e "${GRAY}Returning to the dashboard...${RESET}"
    /bin/sleep 1
}


print_tnt_ascii_logo() {
    local width="$1"
    local logo_width=27
    local pad

    pad=$(( (width - logo_width) / 2 ))
    (( pad < 0 )) && pad=0

    printf "%*s%s\n" "$pad" "" "TTTTTTT  NN   NN  TTTTTTT"
    printf "%*s%s\n" "$pad" "" "   TT    NNN  NN     TT   "
    printf "%*s%s\n" "$pad" "" "   TT    NN N NN     TT   "
    printf "%*s%s\n" "$pad" "" "   TT    NN  NNN     TT   "
    printf "%*s%s\n" "$pad" "" "   TT    NN   NN     TT   "
    printf "%*s%s\n" "$pad" "" "   TT    NN   NN     TT   "
}


show_splash_screen() {
    clear

    local cols width
    local subtitle="Troubleshooting Network Tool"
    local loading="Loading network information..."

    cols=$(get_terminal_columns)
    (( cols < 84 )) && cols=84
    width=$((cols - 1))

    printf "%b" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b\n\n" "$RESET"

    print_tnt_ascii_logo "$width"

    echo
    printf "%*s%b%s%b\n" $(( (width - ${#subtitle}) / 2 )) "" "$CYAN" "$subtitle" "$RESET"
    printf "%*s%b%s%b\n" $(( (width - ${#loading}) / 2 )) "" "$GRAY" "$loading" "$RESET"
    echo

    printf "%b" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b\n" "$RESET"
}



show_about_screen() {
    local width
    local title="Troubleshooting Network Tool"
    local version="2.4.5"
    local author="by Marko Racić"
    local website="https://marko.racic.rs"
    local platform="macOS/Bash"

    clear

    width=$(( $(get_terminal_columns) - 1 ))
    (( width < 76 )) && width=76

    printf "%b" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b\n\n" "$RESET"

    print_tnt_ascii_logo "$width"

    echo
    printf "%*s%s\n" $(( (width - ${#title}) / 2 )) "" "$title"
    printf "%*s%s\n" $(( (width - ${#version}) / 2 )) "" "$version"
    printf "%*s%s\n" $(( (width - ${#author}) / 2 )) "" "$author"
    printf "%*s%s\n" $(( (width - ${#website}) / 2 )) "" "$website"
    printf "%*s%s\n" $(( (width - ${#platform}) / 2 )) "" "$platform"

    echo
    printf "%b" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b\n\n" "$RESET"

    local prompt="Press B to return"
    printf "%*s%b%s%b\n" \
        $(( (width - ${#prompt}) / 2 )) "" \
        "$GRAY" "$prompt" "$RESET"

    while true; do
        local key=""
        IFS= read -r -s -n 1 key < /dev/tty || true

        case "$key" in
            [Bb]|[Qq]|$'\e')
                return
                ;;
        esac
    done
}

show_backup_summary() {
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo -e "${YELLOW}No saved network configuration backup exists.${RESET}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$BACKUP_FILE"

    local info dns config ip mask router
    info=$(printf '%s' "$INFO_B64" | /usr/bin/base64 --decode 2>/dev/null || true)
    dns=$(printf '%s' "$DNS_B64" | /usr/bin/base64 --decode 2>/dev/null || true)

    config=$(extract_info_value "$info" "Configuration")
    ip=$(extract_info_value "$info" "IP address")
    mask=$(extract_info_value "$info" "Subnet mask")
    router=$(extract_info_value "$info" "Router")

    if printf '%s\n' "$info" | /usr/bin/grep -qi "DHCP Configuration"; then
        config="DHCP"
    fi

    echo -e "${CYAN}${BOLD}RESTORE CONFIGURATION${RESET}"
    echo
    echo "Service : ${SERVICE:-Unavailable}"
    echo "Mode    : ${config:-Unknown}"

    if [[ "$config" != "DHCP" ]]; then
        echo "IP      : ${ip:-Unavailable}"
        echo "Mask    : ${mask:-Unavailable}"
        echo "Gateway : ${router:-Unavailable}"
    fi

    if [[ -z "$dns" || "$dns" == *"There aren't any DNS Servers set"* ]]; then
        echo "DNS     : Automatic"
    else
        echo "DNS     : $(printf '%s\n' "$dns" | /usr/bin/paste -sd ', ' -)"
    fi

    echo
    echo "Created : ${CREATED_AT:-Unknown}"
    return 0
}

restore_saved_configuration_confirmed() {
    clear

    if ! show_backup_summary; then
        echo
        echo -e "${GRAY}Press any key to return${RESET}"
        IFS= read -r -s -n 1 _
        return
    fi

    echo
    echo -e "${YELLOW}Press Y to restore, or any other key to cancel.${RESET}"

    IFS= read -r -s -n 1 confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        restore_saved_configuration
        show_success_banner "Saved configuration restored successfully."
    fi
}

network_configuration_menu() {
    while true; do
        draw_common_screen_header "NETWORK CONFIGURATION"

        local interface service mode mask
        interface="$SCREEN_INTERFACE"
        service="$SCREEN_SERVICE"
        mode=$(get_ip_mode "$service" "$interface")
        mask=$(get_subnet_mask "$interface")

        printf "%-19s %s\n" "IP configuration" "${mode:-Unknown}"
        printf "%-19s %s\n" "Subnet mask" "${mask:-Unavailable}"

        echo
        local width
        width=$(( $(get_terminal_columns) - 1 ))
        (( width < 76 )) && width=76

        printf "%b" "$CYAN"
        repeat_char "$width" "-"
        printf "%b\n\n" "$RESET"

        echo "1  Enable DHCP + automatic DNS"
        echo "2  Set static IP, subnet, gateway and DNS"
        echo "3  Change DNS servers only"
        echo "4  Restore automatic DNS"
        echo "5  Restore saved configuration"
        echo "6  Run self-test"
        echo "B  Back"
        echo
        echo -e "${GRAY}Press a key${RESET}"

        local config_choice
        IFS= read -r -s -n 1 config_choice

        case "$config_choice" in
            1)
                set_dhcp_mode
                show_success_banner "DHCP and automatic DNS enabled."
                return
                ;;
            2)
                set_static_mode
                show_success_banner "Static network configuration completed."
                return
                ;;
            3)
                set_custom_dns
                show_success_banner "DNS configuration updated."
                return
                ;;
            4)
                set_automatic_dns
                show_success_banner "Automatic DNS restored."
                return
                ;;
            5)
                restore_saved_configuration_confirmed
                return
                ;;
            6)
                run_self_test
                ;;
            [Bb]|[Qq]|0|$'\e')
                return
                ;;
            *)
                echo
                echo -e "${RED}Invalid option.${RESET}"
                /bin/sleep 0.6
                ;;
        esac
    done
}





collect_screen_context() {
    local interface service ip gateway dns vpn

    interface=$(get_active_interface)
    service=$(get_network_service "$interface")

    if [[ -z "$service" ]]; then
        service=$(get_last_service)
    fi

    if [[ -z "$service" ]]; then
        service=$(get_backup_service)
    fi

    if [[ -z "$interface" && -n "$service" ]]; then
        interface=$(get_interface_for_service "$service")
    fi

    ip=$(get_private_ip "$interface")
    gateway=$(get_gateway "$service")
    dns=$(get_dns_servers "$service" | /usr/bin/head -n 1)
    vpn=$(get_vpn_status)

    SCREEN_SERVICE="${service:-Unavailable}"
    SCREEN_INTERFACE="${interface:-Unavailable}"
    SCREEN_IP="${ip:-Unavailable}"
    SCREEN_GATEWAY="${gateway:-Unavailable}"
    SCREEN_DNS="${dns:-Unavailable}"
    SCREEN_VPN="${vpn:-Disconnected}"
}

screen_status_state() {
    local kind="$1"
    local value="$2"

    case "$kind" in
        service|interface)
            [[ -n "$value" && "$value" != "Unavailable" ]] && echo ok || echo bad
            ;;
        ip)
            if [[ "$value" == 169.254.* ]]; then
                echo warn
            elif [[ -n "$value" && "$value" != "Unavailable" ]]; then
                echo ok
            else
                echo bad
            fi
            ;;
        gateway|dns)
            [[ -n "$value" && "$value" != "Unavailable" ]] && echo ok || echo bad
            ;;
        vpn)
            [[ "$value" == "Disconnected" ]] && echo warn || echo ok
            ;;
        *)
            echo none
            ;;
    esac
}

screen_status_line() {
    local state="$1"
    local label="$2"
    local value="$3"
    local color

    color=$(status_color "$state")
    printf "%b●%b %-17s %s\n" "$color" "$RESET" "$label" "$value"
}

draw_common_screen_header() {
    local title="$1"
    local target="${2:-}"
    local cols width heading pad

    collect_screen_context

    cols=$(get_terminal_columns)
    (( cols < 76 )) && cols=76
    width=$((cols - 1))
    heading="TNT ${APP_VERSION} — ${title}"
    pad=$(( (width - ${#heading}) / 2 ))
    (( pad < 0 )) && pad=0

    clear

    printf "%b" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b\n" "$RESET"

    printf "%*s%s\n" "$pad" "" "$heading"

    printf "%b" "$CYAN"
    repeat_char "$width" "-"
    printf "%b\n" "$RESET"

    screen_status_line "$(screen_status_state service "$SCREEN_SERVICE")" \
        "Network service" "$SCREEN_SERVICE"
    screen_status_line "$(screen_status_state interface "$SCREEN_INTERFACE")" \
        "Interface" "$SCREEN_INTERFACE"
    screen_status_line "$(screen_status_state ip "$SCREEN_IP")" \
        "IP address" "$SCREEN_IP"
    screen_status_line "$(screen_status_state gateway "$SCREEN_GATEWAY")" \
        "Gateway" "$SCREEN_GATEWAY"
    screen_status_line "$(screen_status_state dns "$SCREEN_DNS")" \
        "DNS" "$SCREEN_DNS"
    screen_status_line "$(screen_status_state vpn "$SCREEN_VPN")" \
        "VPN" "$SCREEN_VPN"

    if [[ -n "$target" ]]; then
        printf "%b" "$CYAN"
        repeat_char "$width" "-"
        printf "%b\n" "$RESET"
        printf "%-19s %s\n" "Target" "$target"
    fi

    printf "%b" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b\n\n" "$RESET"
}

diagnostic_status_state() {
    local kind="$1"
    local value="$2"

    case "$kind" in
        interface)
            [[ -n "$value" && "$value" != "Unavailable" ]] && echo ok || echo bad
            ;;
        ip)
            if [[ "$value" == 169.254.* ]]; then
                echo warn
            elif [[ -n "$value" && "$value" != "Unavailable" ]]; then
                echo ok
            else
                echo bad
            fi
            ;;
        gateway|dns)
            [[ -n "$value" && "$value" != "Unavailable" ]] && echo ok || echo bad
            ;;
        vpn)
            [[ "$value" == "Disconnected" ]] && echo warn || echo ok
            ;;
        *)
            echo none
            ;;
    esac
}

diagnostic_status_line() {
    local state="$1"
    local label="$2"
    local value="$3"
    local color

    color=$(status_color "$state")
    printf "%b●%b %-10s %s\n" "$color" "$RESET" "$label" "$value"
}

diagnostic_collect_context() {
    collect_screen_context
    DIAG_INTERFACE="$SCREEN_INTERFACE"
    DIAG_IP="$SCREEN_IP"
    DIAG_GATEWAY="$SCREEN_GATEWAY"
    DIAG_DNS="$SCREEN_DNS"
    DIAG_VPN="$SCREEN_VPN"
}





resolve_target_ipv4() {
    local target="$1"
    local result

    result=$(/usr/bin/dig +short A "$target" 2>/dev/null |
        /usr/bin/awk '/^[0-9]+\./ {print; exit}')

    if [[ -z "$result" ]] && is_valid_ipv4 "$target"; then
        result="$target"
    fi

    printf '%s\n' "${result:-Unavailable}"
}


run_interruptible_command() {
    local description="$1"
    shift

    echo -e "${GRAY}Running... Press Q or Esc to stop.${RESET}"
    echo

    "$@" &
    local command_pid=$!

    while /bin/kill -0 "$command_pid" >/dev/null 2>&1; do
        local key=""

        if IFS= read -r -s -n 1 -t 1 key < /dev/tty; then
            case "$key" in
                [Qq]|$'\e')
                    /bin/kill -INT "$command_pid" >/dev/null 2>&1 || true
                    /bin/sleep 0.2
                    /bin/kill "$command_pid" >/dev/null 2>&1 || true
                    break
                    ;;
            esac
        fi
    done

    wait "$command_pid" 2>/dev/null || true
    echo
    echo -e "${GRAY}${description} finished.${RESET}"
}






end_diagnostics_scroll_region() {
    # Restore normal whole-window scrolling.
    printf '\033[r'
    printf '\033[999;1H'
}


diagnostics_terminal_rows() {
    local rows
    rows=$(/bin/stty size 2>/dev/null | /usr/bin/awk '{print $1}')
    if [[ -z "$rows" || ! "$rows" =~ ^[0-9]+$ ]]; then
        rows=50
    fi
    printf '%s\n' "$rows"
}


diagnostics_output_start_row() {
    echo 29
}

begin_diagnostics_scroll_region() {
    local rows first_scroll_row
    rows=$(diagnostics_terminal_rows)
    first_scroll_row=$(diagnostics_output_start_row)

    if (( rows < first_scroll_row + 6 )); then
        first_scroll_row=$((rows - 6))
    fi
    (( first_scroll_row < 16 )) && first_scroll_row=16

    printf '\033[%d;%dr' "$first_scroll_row" "$rows"
    printf '\033[%d;1H' "$first_scroll_row"
}

clear_diagnostics_result_area() {
    local rows start row
    rows=$(diagnostics_terminal_rows)
    start=$(diagnostics_output_start_row)
    (( rows < start )) && start=16

    row="$start"
    while (( row <= rows )); do
        printf '\033[%d;1H\033[2K' "$row"
        row=$((row + 1))
    done
    printf '\033[%d;1H' "$start"
}


draw_diagnostics_fixed_screen() {
    local cols width title row pad
    row=1

    end_diagnostics_scroll_region
    /bin/stty sane < /dev/tty 2>/dev/null || true
    collect_screen_context

    cols=$(get_terminal_columns)
    (( cols < 76 )) && cols=76
    width=$((cols - 1))
    title="TNT ${APP_VERSION} — DIAGNOSTICS"

    clear

    printf '\033[%d;1H%b' "$row" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b" "$RESET"
    row=$((row + 1))

    pad=$(( (width - ${#title}) / 2 ))
    (( pad < 0 )) && pad=0
    printf '\033[%d;1H%*s%s' "$row" "$pad" "" "$title"
    row=$((row + 1))

    printf '\033[%d;1H%b' "$row" "$CYAN"
    repeat_char "$width" "-"
    printf "%b" "$RESET"
    row=$((row + 1))

    printf '\033[%d;1H' "$row"
    screen_status_line "$(screen_status_state service "$SCREEN_SERVICE")" \
        "Network service" "$SCREEN_SERVICE"
    row=$((row + 1))

    printf '\033[%d;1H' "$row"
    screen_status_line "$(screen_status_state interface "$SCREEN_INTERFACE")" \
        "Interface" "$SCREEN_INTERFACE"
    row=$((row + 1))

    printf '\033[%d;1H' "$row"
    screen_status_line "$(screen_status_state ip "$SCREEN_IP")" \
        "IP address" "$SCREEN_IP"
    row=$((row + 1))

    printf '\033[%d;1H' "$row"
    screen_status_line "$(screen_status_state gateway "$SCREEN_GATEWAY")" \
        "Gateway" "$SCREEN_GATEWAY"
    row=$((row + 1))

    printf '\033[%d;1H' "$row"
    screen_status_line "$(screen_status_state dns "$SCREEN_DNS")" \
        "DNS" "$SCREEN_DNS"
    row=$((row + 1))

    printf '\033[%d;1H' "$row"
    screen_status_line "$(screen_status_state vpn "$SCREEN_VPN")" \
        "VPN" "$SCREEN_VPN"
    row=$((row + 1))

    printf '\033[%d;1H%b' "$row" "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b" "$RESET"

    printf '\033[12;1H1  Ping'
    printf '\033[13;1H2  Traceroute'
    printf '\033[14;1H3  DNS Lookup'
    printf '\033[15;1H4  Reverse DNS'
    printf '\033[16;1H5  Flush DNS Cache'
    printf '\033[17;1H6  Renew DHCP Lease'
    printf '\033[18;1H7  TCP Port Test'
    printf '\033[19;1H8  IP Information'
    printf '\033[20;1HB  Back'

    printf '\033[22;1H%b' "$CYAN"
    repeat_char "$width" "-"
    printf "%b" "$RESET"

    printf '\033[23;1H%bPress a key%b' "$GRAY" "$RESET"

    for row in 24 25 26 27 28; do
        printf '\033[%d;1H\033[2K' "$row"
    done

    clear_diagnostics_result_area
    printf '\033[23;1H'
}


draw_diagnostics_output_header() {
    local title="$1"
    local target="${2:-}"
    local width
    width=$(( $(get_terminal_columns) - 1 ))
    (( width < 76 )) && width=76
    printf '\033[25;1H\033[2K'
    printf '\033[25;1H%b' "$CYAN$BOLD"
    repeat_char "$width" "="
    printf "%b" "$RESET"
    printf '\033[26;1H\033[2K'
    if [[ -n "$target" ]]; then
        printf '\033[26;1H%s — %s' "$title" "$target"
    else
        printf '\033[26;1H%s' "$title"
    fi
    printf '\033[27;1H\033[2K'
    printf '\033[27;1H%b' "$CYAN"
    repeat_char "$width" "-"
    printf "%b" "$RESET"
    printf '\033[28;1H\033[2K'
    clear_diagnostics_result_area
    begin_diagnostics_scroll_region
}



finish_inline_diagnostic() {
    local ignored=""
    end_diagnostics_scroll_region
    printf '\033[28;1H\033[2K'
    printf '\033[28;1H%bPress any key to return to Diagnostics.%b' "$GRAY" "$RESET"
    /bin/stty sane < /dev/tty 2>/dev/null || true
    IFS= read -r -s -n 1 ignored < /dev/tty || true
}



prompt_below_diagnostics_menu() {
    local prompt_label="$1"
    DIAGNOSTIC_INPUT=""
    end_diagnostics_scroll_region
    /bin/stty sane < /dev/tty 2>/dev/null || true
    printf '\033[23;1H\033[2K'
    printf '\033[24;1H\033[2K'
    printf '\033[24;1H'
    IFS= read -r -p "${prompt_label}: " DIAGNOSTIC_INPUT < /dev/tty || true
}

diagnostic_ping() {
    local target resolved

    prompt_below_diagnostics_menu "Host or IP"
    target="$DIAGNOSTIC_INPUT"
    if [[ -z "$target" ]]; then
        end_diagnostics_scroll_region
        return
    fi

    resolved=$(resolve_target_ipv4 "$target")

    draw_diagnostics_output_header "PING" "$target"
    printf "%-19s %s\n" "Resolved IPv4" "$resolved"
    echo

    run_interruptible_command "Ping" /sbin/ping "$target"
    finish_inline_diagnostic
}

diagnostic_traceroute() {
    local target

    prompt_below_diagnostics_menu "Host or IP"
    target="$DIAGNOSTIC_INPUT"
    if [[ -z "$target" ]]; then
        end_diagnostics_scroll_region
        return
    fi

    draw_diagnostics_output_header "TRACEROUTE" "$target"

    run_interruptible_command \
        "Traceroute" \
        /usr/sbin/traceroute -n "$target"

    finish_inline_diagnostic
}

print_dns_section() {
    local label="$1"
    local values="$2"

    [[ -z "$values" ]] && return

    echo
    echo -e "${CYAN}${BOLD}${label}${RESET}"
    printf '%s\n' "$values"
}

diagnostic_dns_lookup() {
    local target resolver
    local a aaaa cname mx ns txt

    prompt_below_diagnostics_menu "Hostname"
    target="$DIAGNOSTIC_INPUT"
    if [[ -z "$target" ]]; then
        end_diagnostics_scroll_region
        return
    fi

    draw_diagnostics_output_header "DNS LOOKUP" "$target"

    a=$(/usr/bin/dig +short A "$target" 2>/dev/null)
    aaaa=$(/usr/bin/dig +short AAAA "$target" 2>/dev/null)
    cname=$(/usr/bin/dig +short CNAME "$target" 2>/dev/null)
    mx=$(/usr/bin/dig +short MX "$target" 2>/dev/null |
        /usr/bin/sort -n)
    ns=$(/usr/bin/dig +short NS "$target" 2>/dev/null)
    txt=$(/usr/bin/dig +short TXT "$target" 2>/dev/null)

    print_dns_section "IPv4 (A)" "$a"
    print_dns_section "IPv6 (AAAA)" "$aaaa"
    print_dns_section "CNAME" "$cname"
    print_dns_section "Mail Servers (MX)" "$mx"
    print_dns_section "Name Servers (NS)" "$ns"
    print_dns_section "TXT" "$txt"

    if [[ -z "$a$aaaa$cname$mx$ns$txt" ]]; then
        echo
        echo -e "${YELLOW}No DNS records were returned.${RESET}"
    fi

    resolver=$(get_dns_servers "$SCREEN_SERVICE" | /usr/bin/head -n 1)
    echo
    echo -e "${GRAY}Resolver: ${resolver:-System default}${RESET}"

    finish_inline_diagnostic
}

diagnostic_reverse_dns() {
    local ip hostname forward

    prompt_below_diagnostics_menu "IP address"
    ip="$DIAGNOSTIC_INPUT"
    if [[ -z "$ip" ]]; then
        end_diagnostics_scroll_region
        return
    fi

    draw_diagnostics_output_header "REVERSE DNS" "$ip"

    hostname=$(/usr/bin/dig +short -x "$ip" 2>/dev/null |
        /usr/bin/head -n 1 |
        /usr/bin/sed 's/\.$//')

    if [[ -z "$hostname" ]]; then
        echo
        echo -e "${YELLOW}No PTR record found.${RESET}"
    else
        echo
        echo -e "${CYAN}${BOLD}Hostname${RESET}"
        echo "$hostname"

        forward=$(/usr/bin/dig +short A "$hostname" 2>/dev/null)
        echo
        echo -e "${CYAN}${BOLD}Forward lookup${RESET}"

        if printf '%s\n' "$forward" | /usr/bin/grep -Fxq "$ip"; then
            echo -e "${GREEN}${ip} ✓${RESET}"
        elif [[ -n "$forward" ]]; then
            printf '%s\n' "$forward"
            echo -e "${YELLOW}PTR does not forward-confirm to the original IP.${RESET}"
        else
            echo -e "${YELLOW}No forward A record found.${RESET}"
        fi
    fi

    finish_inline_diagnostic
}





is_valid_tcp_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

diagnostic_tcp_port_test() {
    local input host port resolved output started ended elapsed status

    prompt_below_diagnostics_menu "Host:port"
    input="$DIAGNOSTIC_INPUT"

    if [[ -z "$input" ]]; then
        end_diagnostics_scroll_region
        return
    fi

    # Parse the final colon as the port separator. This supports normal
    # hostnames and IPv4 addresses, which are the intended inputs here.
    if [[ "$input" != *:* ]]; then
        printf '\033[23;1H\033[2K'
        printf '\033[23;1H%bUse the format host:port, for example example.com:443.%b' \
            "$YELLOW" "$RESET"
        /bin/sleep 1.5
        return
    fi

    host="${input%:*}"
    port="${input##*:}"

    if [[ -z "$host" ]] || ! is_valid_tcp_port "$port"; then
        printf '\033[23;1H\033[2K'
        printf '\033[23;1H%bInvalid host or TCP port.%b' "$RED" "$RESET"
        /bin/sleep 1.5
        return
    fi

    resolved=$(resolve_target_ipv4 "$host")
    draw_diagnostics_output_header "TCP PORT TEST" "${host}:${port}"

    printf "%-19s %s\n" "Resolved IPv4" "$resolved"
    printf "%-19s %s\n" "TCP port" "$port"
    printf "%-19s %s\n" "Timeout" "5 seconds"
    echo

    started=$(/bin/date +%s)

    if output=$(/usr/bin/nc -vz -G 5 "$host" "$port" 2>&1); then
        status=0
    else
        status=$?
    fi

    ended=$(/bin/date +%s)
    elapsed=$((ended - started))

    printf '%s\n' "$output"
    echo

    if (( status == 0 )); then
        echo -e "${GREEN}${BOLD}● Connection successful${RESET}"
    else
        echo -e "${RED}${BOLD}● Connection failed${RESET}"
    fi

    printf "%-19s %ss\n" "Elapsed" "$elapsed"

    finish_inline_diagnostic
}



json_value_simple() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" |
        /usr/bin/sed -nE 's/.*"'$key'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' |
        /usr/bin/head -n 1
}

json_number_simple() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" |
        /usr/bin/sed -nE 's/.*"'$key'"[[:space:]]*:[[:space:]]*(-?[0-9.]+).*/\1/p' |
        /usr/bin/head -n 1
}

diagnostic_ip_information() {
    local input target_ip response
    local country region city isp asn timezone lat lon ip_type success

    prompt_below_diagnostics_menu "IP address or host (Enter = Public IP)"
    input="$DIAGNOSTIC_INPUT"

    if [[ -z "$input" ]]; then
        target_ip="$PUBLIC_IP"
    elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        target_ip="$input"
    else
        target_ip=$(resolve_target_ipv4 "$input")
    fi

    if [[ -z "$target_ip" || "$target_ip" == "Unavailable" ]]; then
        printf '\033[24;1H\033[2K'
        printf '\033[24;1H%bUnable to resolve IP address.%b' "$RED" "$RESET"
        /bin/sleep 1.5
        return
    fi

    draw_diagnostics_output_header "IP INFORMATION" "$target_ip"

    response=$(/usr/bin/curl -4 -fsS --max-time 6 \
        "https://ipwho.is/${target_ip}?fields=success,ip,type,country,region,city,latitude,longitude,connection,timezone" \
        2>/dev/null || true)

    if [[ -z "$response" ]]; then
        echo -e "${RED}${BOLD}● IP information service unavailable${RESET}"
        echo
        echo "Could not retrieve data from ipwho.is."
        finish_inline_diagnostic
        return
    fi

    success=$(printf '%s' "$response" | /usr/bin/grep -o '"success":[^,}]*' | /usr/bin/head -n1)
    if [[ "$success" == *"false"* ]]; then
        echo -e "${RED}${BOLD}● Lookup failed${RESET}"
        echo
        printf '%s\n' "$response"
        finish_inline_diagnostic
        return
    fi

    ip_type=$(json_value_simple "$response" "type")
    country=$(json_value_simple "$response" "country")
    region=$(json_value_simple "$response" "region")
    city=$(json_value_simple "$response" "city")
    lat=$(json_number_simple "$response" "latitude")
    lon=$(json_number_simple "$response" "longitude")
    isp=$(printf '%s' "$response" | /usr/bin/sed -nE 's/.*"connection"[[:space:]]*:[[:space:]]*\{[^}]*"isp"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | /usr/bin/head -n 1)
    asn=$(printf '%s' "$response" | /usr/bin/sed -nE 's/.*"connection"[[:space:]]*:[[:space:]]*\{[^}]*"asn"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | /usr/bin/head -n 1)
    timezone=$(printf '%s' "$response" | /usr/bin/sed -nE 's/.*"timezone"[[:space:]]*:[[:space:]]*\{[^}]*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | /usr/bin/head -n 1)

    [[ -z "$ip_type" ]] && ip_type="Unknown"
    [[ -z "$country" ]] && country="Unavailable"
    [[ -z "$region" ]] && region="Unavailable"
    [[ -z "$city" ]] && city="Unavailable"
    [[ -z "$isp" ]] && isp="Unavailable"
    [[ -z "$asn" ]] && asn="Unavailable"
    [[ -z "$timezone" ]] && timezone="Unavailable"
    [[ -z "$lat" ]] && lat="Unavailable"
    [[ -z "$lon" ]] && lon="Unavailable"

    printf "%-19s %s\n" "IP address" "$target_ip"
    printf "%-19s %s\n" "Type" "$ip_type"
    printf "%-19s %s\n" "Country" "$country"
    printf "%-19s %s\n" "Region" "$region"
    printf "%-19s %s\n" "City" "$city"
    printf "%-19s %s\n" "ISP" "$isp"
    if [[ "$asn" != "Unavailable" ]]; then
        printf "%-19s AS%s\n" "ASN" "$asn"
    else
        printf "%-19s %s\n" "ASN" "$asn"
    fi
    printf "%-19s %s\n" "Timezone" "$timezone"
    printf "%-19s %s, %s\n" "Coordinates" "$lat" "$lon"
    echo
    echo -e "${GRAY}Geolocation is approximate and based on public IP data.${RESET}"
    finish_inline_diagnostic
}

diagnostics_menu() {
    while true; do
        draw_diagnostics_fixed_screen

        local diagnostic_choice=""
        /bin/stty sane < /dev/tty 2>/dev/null || true
        printf '\033[23;1H'

        IFS= read -r -s -n 1 diagnostic_choice < /dev/tty || diagnostic_choice=""

        case "$diagnostic_choice" in
            1) diagnostic_ping ;;
            2) diagnostic_traceroute ;;
            3) diagnostic_dns_lookup ;;
            4) diagnostic_reverse_dns ;;
            5) flush_dns ;;
            6) renew_dhcp ;;
            7) diagnostic_tcp_port_test ;;
            8) diagnostic_ip_information ;;
            [Bb]|[Qq]|$'\e')
                end_diagnostics_scroll_region
                return
                ;;
            "")
                ;;
            *)
                printf '\033[24;1H\033[2K'
                printf '\033[24;1H%bInvalid option.%b' "$RED" "$RESET"
                /bin/sleep 0.5
                ;;
        esac
    done
}

read_main_menu_choice() {
    local footer="© Marko Racić 2026 • https://marko.racic.rs"
    local cols footer_pad timestamp timestamp_pad
    local watched_interface current_interface
    local idle_seconds=0
    local refresh_after
    local age age_color age_text

    watched_interface=$(get_active_interface)
    refresh_after=$(get_refresh_seconds)

    draw_status_footer() {
        cols=$(get_terminal_columns)

        age=$(refresh_age_seconds)
        age_color=$(refresh_age_color "$age")
        age_text=$(format_refresh_age "$age")

        timestamp="● Updated ${LAST_REFRESH_TIME} • ${age_text}"
        timestamp_pad=$(( (cols - ${#timestamp}) / 2 ))
        (( timestamp_pad < 0 )) && timestamp_pad=0

        footer_pad=$(( (cols - ${#footer}) / 2 ))
        (( footer_pad < 0 )) && footer_pad=0

        # Refresh information directly below the actions menu.
        printf "%*s%b%s%b\n" "$timestamp_pad" "" "$age_color$BOLD" "$timestamp" "$RESET"

        # One blank row, then the footer.
        printf "\n"
        printf "%*s%b%s%b\n" "$footer_pad" "" "$GRAY" "$footer" "$RESET"
    }

    draw_status_footer

    while true; do
        if IFS= read -r -s -n 1 -t 1 choice; then
            printf "\033[2K\r"
            return
        fi

        idle_seconds=$((idle_seconds + 1))
        current_interface=$(get_active_interface)

        if [[ "$current_interface" != "$watched_interface" ]]; then
            choice="__adapter_changed__"
            printf "\033[2K\r"
            return
        fi

        if (( refresh_after > 0 && idle_seconds >= refresh_after )); then
            choice="__auto_refresh__"
            printf "\033[2K\r"
            return
        fi

        # Redraw the three-line status area only.
        printf "\033[3A"
        draw_status_footer
    done
}
flush_dns() {
    echo
    echo -e "${CYAN}Flushing macOS DNS caches...${RESET}"

    if sudo /usr/bin/dscacheutil -flushcache &&
       sudo /usr/bin/killall -HUP mDNSResponder; then
        echo -e "${GREEN}DNS cache flushed successfully.${RESET}"
        log_event INFO "DNS cache flushed"
    else
        echo -e "${RED}DNS flush failed.${RESET}"
    fi

    pause
}

renew_dhcp() {
    local interface
    interface=$(get_active_interface)

    [[ -z "$interface" ]] && {
        echo -e "${RED}No active interface detected.${RESET}"
        pause
        return
    }

    echo
    echo -e "${CYAN}Renewing DHCP lease on $interface...${RESET}"

    if sudo /usr/sbin/ipconfig set "$interface" DHCP; then
        echo -e "${GREEN}DHCP lease renewal requested.${RESET}"
        log_event INFO "DHCP lease renewal requested on $interface"
    else
        echo -e "${RED}DHCP renewal failed.${RESET}"
    fi

    pause
}

ping_gateway() {
    local gateway
    gateway=$(get_gateway)

    [[ -z "$gateway" ]] && {
        echo -e "${RED}No default gateway detected.${RESET}"
        pause
        return
    }

    echo
    echo -e "${CYAN}Pinging gateway $gateway...${RESET}"
    /sbin/ping "$gateway"
    pause
}

ping_custom() {
    local host

    echo
    read -r -p "Enter IP address or hostname: " host
    [[ -z "$host" ]] && return

    echo
    echo -e "${CYAN}Pinging $host...${RESET}"
    /sbin/ping "$host"
    pause
}

copy_network_info() {
    collect_info

    {
        echo "MAC address: ${ACTIVE_MAC:-Unavailable}"
        echo "Network Toolbox Report"
        echo "Active interface: ${ACTIVE_IF:-Unavailable}"
        echo "Network service: ${SERVICE:-Unavailable}"
        echo "IP configuration: ${IP_MODE:-Unknown}"
        echo "IPv4 address: ${PRIVATE_IP:-Unavailable}"
        echo "Subnet mask: ${SUBNET:-Unavailable}"
        echo "IPv6 address: ${IPV6:-Unavailable}"
        echo "Default gateway: ${GATEWAY:-Unavailable}"
        echo "Public IPv4: ${PUBLIC_IP:-Unavailable}"
        echo "Wi-Fi interface: ${WIFI_IF:-Unavailable}"
        echo "SSID: $SSID"
        echo "VPN: $VPN"
        echo "Network location: $LOCATION"
        echo "macOS: $MACOS"
        echo "Host: $HOST"
        echo "User: $USER_NAME"
        echo "Uptime: $UPTIME"
        echo "DNS servers:"
        printf '%s\n' "$DNS_SERVERS"
    } | /usr/bin/pbcopy

    echo
    echo -e "${GREEN}Network information copied to clipboard.${RESET}"
    pause
}

open_network_settings() {
    /usr/bin/open "x-apple.systempreferences:com.apple.Network-Settings.extension" 2>/dev/null || true
    echo
    echo -e "${GREEN}Network Settings opened.${RESET}"
    pause
}

quit_toolbox() {
    clear
    cleanup_toolbox

    /usr/bin/osascript >/dev/null 2>&1 <<'APPLESCRIPT' &
tell application "Terminal"
    delay 0.2
    if (count of windows) > 0 then close front window
end tell
APPLESCRIPT

    exit 0
}

show_splash_screen
/bin/sleep 0.8

while true; do
    show_dashboard
    read_main_menu_choice

    case "$choice" in
        "__auto_refresh__")
            ;;
        "__adapter_changed__")
            echo
            echo -e "${CYAN}Active network adapter changed. Refreshing...${RESET}"
            /bin/sleep 0.4
            ;;
        1)
            ;;
        2)
            diagnostics_menu
            ;;
        3)
            network_configuration_menu
            ;;
        4)
            open_network_settings
            ;;
        [Cc])
            copy_network_info
            ;;
        [Rr])
            toggle_refresh_mode
            echo
            echo -e "${CYAN}Refresh interval changed to ${REFRESH_MODE}.${RESET}"
            /bin/sleep 0.8
            ;;
        [Aa])
            show_about_screen
            ;;
        [Qq]|9)
            quit_toolbox
            ;;
        *)
            echo -e "${RED}Invalid option.${RESET}"
            /bin/sleep 0.6
            ;;
    esac
done
