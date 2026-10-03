#!/usr/bin/env bash
#################### x-ui-pro-refactor @ github.com/mozaroc #############################
# A surprisingly common invocation is `sh start-script.sh`. Dash ignores the
# shebang and later breaks Bash arrays/[[...]]. Re-exec the actual file in Bash.
if [ -z "${BASH_VERSION:-}" ]; then
    if [ -r "$0" ]; then
        exec /usr/bin/env bash "$0" "$@"
    fi
    printf '%s\n' "This installer requires Bash. Run: sudo bash start-script.sh" >&2
    exit 1
fi

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }
umask 077
set -Euo pipefail

# ─── Output helpers ──────────────────────────────────────────────────────────
msg_ok()  { printf '\033[1;42m %b \033[0m\n' "$*"; }
msg_err() { printf '\033[1;41m %b \033[0m\n' "$*" >&2; }
msg_inf() { printf '\033[1;34m%b\033[0m\n' "$*"; }
die()     { msg_err "$*"; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
read_os_release_value() {
    local key="$1" file="${OS_RELEASE_FILE:-/etc/os-release}"
    awk -F= -v wanted="$key" '
        $1 == wanted {
            value = substr($0, index($0, "=") + 1)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]\r]+$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$file" 2>/dev/null
}

check_os() {
    local os_id os_version os_major supported="false"
    local os_file="${OS_RELEASE_FILE:-/etc/os-release}"

    if [[ ! -r "$os_file" ]]; then
        msg_err "Cannot read OS metadata: ${os_file}"
        exit 1
    fi

    os_id=$(read_os_release_value ID)
    os_version=$(read_os_release_value VERSION_ID)
    os_id=$(printf '%s' "$os_id" | tr '[:upper:]' '[:lower:]')
    # Accept VERSION_ID=12, VERSION_ID="12", and provider variants such as
    # 12.7 or "12 (bookworm)". CRLF files are also normalized here.
    os_id=$(printf '%s' "$os_id" | tr -d '[:space:]\r')
    os_version=$(printf '%s' "$os_version" | tr -d '\r' | awk '{print $1}')
    os_major=${os_version%%.*}

    case "${os_id}" in
        ubuntu)
            [[ "$os_version" =~ ^(20\.04|22\.04|24\.04|26\.04)(\.[0-9]+)?$ ]] && supported="true"
            ;;
        debian|raspbian)
            [[ "$os_major" =~ ^(11|12|13)$ ]] && supported="true"
            ;;
    esac

    if [[ "$supported" == "true" ]]; then
        msg_inf "Detected supported OS: ${os_id} ${os_version}"
        return 0
    fi

    # Useful for compatible derivatives and newer releases, but never silently
    # claim they were tested. apt-get and systemd are hard requirements below.
    if [[ "${ALLOW_UNSUPPORTED_OS:-0}" == "1" ]] \
       && command -v apt-get >/dev/null 2>&1 \
       && command -v systemctl >/dev/null 2>&1; then
        msg_inf "Warning: continuing on untested OS '${os_id} ${os_version}' because ALLOW_UNSUPPORTED_OS=1."
        return 0
    fi

    msg_err "Unsupported OS: id='${os_id:-unknown}' version='${os_version:-unknown}'"
    printf '\n%s\n%s\n%s\n%s\n%s\n' \
        "Supported systems:" \
        "  Ubuntu 20.04 / 22.04 / 24.04 / 26.04" \
        "  Debian 11 / 12 / 13" \
        "  Raspbian 11 / 12 / 13" \
        "For an apt/systemd-compatible derivative, retry with ALLOW_UNSUPPORTED_OS=1."
    exit 1
}

check_cpu() {
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- || true)

    if echo "$cpu_model" | grep -qi 'QEMU'; then
        msg_inf "Warning: generic QEMU CPU detected. Xray should work, but host-passthrough may improve performance."
    fi
}

# ─── Constants ───────────────────────────────────────────────────────────────
XUIDB="/etc/x-ui/x-ui.db"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ASSET_DIR="${ASSET_DIR:-${SCRIPT_DIR}/assets}"
STATE_DIR="/etc/3x-ui-pro"
STATE_FILE="${STATE_DIR}/state.env"
SYSCTL_FILE="/etc/sysctl.d/99-3x-ui-pro.conf"
NGINX_BEGIN="# BEGIN 3X-UI-PRO MANAGED BLOCK"
NGINX_END="# END 3X-UI-PRO MANAGED BLOCK"

# ─── Default argument values ─────────────────────────────────────────────────
domain=""
reality_domain=""
UNINSTALL="no"
INSTALL="yes"
PANEL_VERSION=""
IP4=""
IP6=""
SSH_PORT="${SSH_PORT:-}"
WORK_DIR=""
ROLLBACK_DIR=""
ROLLBACK_ACTIVE=0
NGINX_STOPPED_BY_US=0
PANEL_TAG=""
LAST_ERROR=""
sub_port=""
panel_port=""
ws_port=""
trojan_port=""
mtr_backend_port=""
sub_path=""
json_path=""
panel_path=""
ws_path=""
trojan_path=""
xhttp_path=""
config_username=""
config_password=""
diag_path=""
diag_token=""

usage() {
    cat <<'EOF'
Usage: sudo bash start-script.sh [options]
  -subdomain DOMAIN             Panel domain owned by you
  -reality_target HOST          External TLS 1.3 camouflage host
  -reality_domain HOST          Legacy alias for -reality_target
  -version X.Y.Z                Pin a 3x-ui release (minimum 3.5.0)
  -install yes|no               Install missing OS packages (default: yes)
  -uninstall yes                Remove this installation
  --help                        Show this help

Environment: PANEL_SHA256, SSH_PORT, ALLOW_UNSUPPORTED_OS=1,
SKIP_REALITY_TARGET_CHECK=1, SKIP_FIREWALL=1.
EOF
}

need_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != -* ]] \
        || die "Option $1 requires a value."
}

normalize_bool() {
    local normalized
    normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$normalized" in
        y|yes|true|1) echo yes ;;
        n|no|false|0) echo no ;;
        *) return 1 ;;
    esac
}

while (($#)); do
    case "$1" in
        -install)
            need_value "$@"
            INSTALL=$(normalize_bool "$2") || die "-install accepts only yes/no."
            shift 2
            ;;
        -subdomain)
            need_value "$@"; domain="$2"; shift 2
            ;;
        -reality_domain|-reality_target)
            need_value "$@"; reality_domain="$2"; shift 2
            ;;
        -version)
            need_value "$@"; PANEL_VERSION="$2"; shift 2
            ;;
        -uninstall)
            need_value "$@"
            UNINSTALL=$(normalize_bool "$2") || die "-uninstall accepts only yes/no."
            shift 2
            ;;
        -ONLY_CF_IP_ALLOW)
            die "-ONLY_CF_IP_ALLOW is not implemented; refusing to ignore it."
            ;;
        -h|--help) usage; exit 0 ;;
        --) shift; (($# == 0)) || die "Unexpected positional arguments: $*" ;;
        -*) die "Unknown option: $1" ;;
        *)  die "Unexpected positional argument: $1" ;;
    esac
done

if [[ "$UNINSTALL" != "yes" ]]; then
    check_os
    check_cpu
fi

valid_hostname() {
    local value
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [[ ${#value} -le 253 \
       && "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

read_state_value() {
    local key="$1"
    [[ -r "$STATE_FILE" ]] || return 1
    sed -n "s/^${key}=//p" "$STATE_FILE" | head -n1
}

remove_nginx_managed_block() {
    local file="/etc/nginx/nginx.conf" tmp
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    awk -v begin="$NGINX_BEGIN" -v end="$NGINX_END" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        $0 == "stream { include /etc/nginx/stream-enabled/*.conf; }" {next}
        $0 == "worker_rlimit_nofile 16384;" {next}
        !skip {print}
    ' "$file" > "$tmp"
    sed -i '1s|^load_module /usr/lib/nginx/modules/ngx_stream_module.so; ||' "$tmp"
    install -m 644 "$tmp" "$file"
    rm -f "$tmp"
}

# ─── Existing installation backup ────────────────────────────────────────────
backup_existing_database() {
    [[ -f "$XUIDB" ]] || return 0
    local backup_dir
    backup_dir="/root/3x-ui-pro-backups/$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$backup_dir"
    install -m 600 "$XUIDB" "$backup_dir/x-ui.db"
    msg_inf "Existing database backed up to ${backup_dir}/x-ui.db"
}

verify_local_assets() {
    local manifest="${ASSET_DIR}/SHA256SUMS"
    [[ -r "$manifest" ]] || { msg_err "Missing asset manifest: $manifest"; exit 1; }
    (cd "$ASSET_DIR" && sha256sum -c SHA256SUMS) \
        || { msg_err "Local asset verification failed."; exit 1; }
}

# ─── Port / path generators ──────────────────────────────────────────────────
get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 50000 + 10000 ))
}

gen_random_string() {
    local length="$1" value
    value=$(openssl rand -hex "$(((length + 1) / 2))")
    printf '%s\n' "${value:0:length}"
}

# Matches the panel's host group_id format (16 lowercase alphanumerics)
gen_group_id() {
    openssl rand -hex 8
}

port_in_use() {
    local port="$1"
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

make_port() {
    local destination="$1" port attempts=0 used
    while true; do
        port=$(get_port)
        used=" ${RESERVED_PORTS[*]:-} "
        if ! port_in_use "$port" && [[ "$used" != *" ${port} "* ]]; then
            RESERVED_PORTS+=("$port")
            printf -v "$destination" '%s' "$port"
            return 0
        fi
        ((++attempts < 500)) || die "Could not allocate a free local port."
    done
}

generate_install_values() {
    RESERVED_PORTS=(7443 8443)
    make_port sub_port
    make_port panel_port
    make_port ws_port
    make_port trojan_port
    make_port mtr_backend_port
    sub_path=$(gen_random_string 16)
    json_path=$(gen_random_string 16)
    panel_path=$(gen_random_string 16)
    ws_path=$(gen_random_string 16)
    trojan_path=$(gen_random_string 16)
    xhttp_path=$(gen_random_string 16)
    config_username=$(gen_random_string 16)
    config_password=$(gen_random_string 24)
    diag_path="/net-$(gen_random_string 20)/"
    diag_token=$(gen_random_string 32)
}

# ─── Package/service requirements ────────────────────────────────────────────
if ! command -v apt-get >/dev/null 2>&1; then
    msg_err "This build currently requires an apt-based system (apt-get not found)."
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    msg_err "systemd is required (systemctl not found)."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
uninstall_xui() {
    local installed_domain=""
    installed_domain=$(read_state_value DOMAIN || true)
    if [[ -n "$domain" ]]; then
        domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
        valid_hostname "$domain" || die "Invalid panel domain: $domain"
        if [[ -n "$installed_domain" && "$domain" != "$installed_domain" ]]; then
            die "Refusing to remove vhost '$domain': installed domain is '$installed_domain'."
        fi
        installed_domain="$domain"
    fi
    [[ -z "$installed_domain" ]] || valid_hostname "$installed_domain" \
        || die "State file contains an invalid domain; remove it manually after inspection."

    systemctl stop x-ui mtr-backend 2>/dev/null || true
    systemctl disable x-ui mtr-backend 2>/dev/null || true
    rm -rf /etc/x-ui/ /usr/local/x-ui/
    rm -f  /usr/bin/x-ui
    rm -rf /var/www/diagnostics/ /var/www/subpage/ /var/www/3x-ui-pro-cover/
    rm -f /etc/nginx/stream-enabled/stream.conf \
          /etc/nginx/sites-enabled/00-maps.conf \
          /etc/nginx/sites-enabled/80.conf \
          /etc/nginx/sites-enabled/3x-ui-pro-maps.conf \
          /etc/nginx/sites-enabled/3x-ui-pro-http.conf \
          /etc/nginx/sites-available/00-maps.conf \
          /etc/nginx/sites-available/80.conf \
          /etc/nginx/sites-available/3x-ui-pro-maps.conf \
          /etc/nginx/sites-available/3x-ui-pro-http.conf \
          /etc/nginx/snippets/includes.conf \
          /etc/cron.d/3x-ui-pro \
          /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx \
          /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services \
          "$SYSCTL_FILE"
    if [[ -n "$installed_domain" ]]; then
        rm -f "/etc/nginx/sites-enabled/${installed_domain}" \
              "/etc/nginx/sites-available/${installed_domain}"
    fi
    rm -f /etc/systemd/system/mtr-backend.service
    rm -rf /usr/local/lib/3x-ui-pro/
    remove_nginx_managed_block
    rm -rf "$STATE_DIR"
    systemctl daemon-reload 2>/dev/null || true
    systemctl is-active --quiet nginx && systemctl reload nginx 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
}

if [[ "$UNINSTALL" == "yes" ]]; then
    uninstall_xui
    msg_ok "3x-ui-pro components were removed. Existing firewall rules were preserved."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# GET SERVER IP
# ─────────────────────────────────────────────────────────────────────────────
valid_ipv4() {
    local ip="$1" a b c d
    IFS=. read -r a b c d <<< "$ip"
    [[ -n "${d:-}" && ${#a} -le 3 && ${#b} -le 3 && ${#c} -le 3 && ${#d} -le 3 \
       && "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ \
       && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

get_server_ip() {
    IP4=$(curl -4fsS --connect-timeout 5 --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)
    valid_ipv4 "$IP4" || IP4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    valid_ipv4 "$IP4" || die "Could not determine a valid public/server IPv4 address."
    IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
    if [[ -z "$IP6" || "$IP6" != *:* ]]; then
        IP6=$(curl -6fsS --connect-timeout 5 --max-time 10 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)
    fi
    [[ "$IP6" == *:* ]] || IP6=""
}


# ─────────────────────────────────────────────────────────────────────────────
# DOMAIN VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_domains() {
    if [[ ! -t 0 && -z "$domain" ]]; then
        die "Non-interactive installation requires -subdomain DOMAIN."
    fi
    while true; do
        [[ -n "$domain" ]] && break
        printf '%s' "Enter your panel domain (DNS must point to this VPS): "
        read -r domain
    done
    domain=$(echo "$domain" | tr -d '[:space:]')
    domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    if ! valid_hostname "$domain"; then
        msg_err "Invalid panel domain: ${domain}"
        exit 1
    fi

    if [[ ! -t 0 && -z "$reality_domain" ]]; then
        die "Non-interactive installation requires -reality_target HOST."
    fi
    while true; do
        [[ -n "$reality_domain" ]] && break
        printf '%s' "Enter REALITY camouflage target (public TLS hostname, e.g. www.microsoft.com): "
        read -r reality_domain
    done
    reality_domain=$(echo "$reality_domain" | tr -d '[:space:]')
    reality_domain=$(printf '%s' "$reality_domain" | tr '[:upper:]' '[:lower:]')
    if ! valid_hostname "$reality_domain"; then
        msg_err "Invalid REALITY camouflage hostname: ${reality_domain}"
        exit 1
    fi

    if [[ "$domain" == "$reality_domain" ]]; then
        msg_err "Panel domain and external REALITY target must be different: ${domain}"
        exit 1
    fi
}

validate_reality_target() {
    if [[ "${SKIP_REALITY_TARGET_CHECK:-0}" == "1" ]]; then
        msg_inf "Warning: REALITY target validation skipped by operator request."
        return 0
    fi

    local resolved tls_output cert_file
    resolved=$(getent ahosts "$reality_domain" 2>/dev/null | awk '{print $1}' | sort -u)
    if [[ -z "$resolved" ]]; then
        msg_err "REALITY target does not resolve: ${reality_domain}"
        exit 1
    fi
    if printf '%s\n' "$resolved" | grep -Fxq -- "$IP4" \
       || { [[ -n "${IP6:-}" ]] && printf '%s\n' "$resolved" | grep -Fxq -- "$IP6"; }; then
        msg_err "REALITY target resolves to this VPS. Choose an external TLS website to avoid a forwarding loop."
        exit 1
    fi

    tls_output=$(mktemp)
    cert_file=$(mktemp)
    if ! timeout 15 openssl s_client -connect "${reality_domain}:443" \
        -servername "$reality_domain" -tls1_3 -alpn h2 < /dev/null \
        >"$tls_output" 2>/dev/null; then
        rm -f "$tls_output" "$cert_file"
        msg_err "REALITY target failed a TLS 1.3 handshake: ${reality_domain}:443"
        exit 1
    fi
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        "$tls_output" | sed -n '1,/-----END CERTIFICATE-----/p' > "$cert_file"
    if ! openssl x509 -in "$cert_file" -noout -checkhost "$reality_domain" >/dev/null 2>&1; then
        rm -f "$tls_output" "$cert_file"
        msg_err "REALITY target certificate does not cover ${reality_domain}."
        exit 1
    fi
    if ! grep -Fq 'ALPN protocol: h2' "$tls_output"; then
        msg_inf "Warning: ${reality_domain} did not negotiate HTTP/2; choose another target for better camouflage."
    fi
    rm -f "$tls_output" "$cert_file"
    msg_ok "REALITY camouflage target validated: ${reality_domain}:443"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    local -a packages=(curl wget jq bash sudo certbot sqlite3 ufw mtr-tiny
        python3 libcap2-bin openssl ca-certificates iproute2 tar coreutils cron kmod)
    if [[ "$INSTALL" == "yes" ]]; then
        msg_inf "Refreshing OS package metadata..."
        DEBIAN_FRONTEND=noninteractive apt-get update
    fi
    if apt-cache show libnginx-mod-stream >/dev/null 2>&1; then
        packages+=(nginx libnginx-mod-stream)
    elif apt-cache show nginx-full >/dev/null 2>&1; then
        packages+=(nginx-full)
    elif [[ "$INSTALL" == "yes" ]]; then
        die "No nginx stream module package is available for this OS."
    fi

    if [[ "$INSTALL" == "yes" ]]; then
        msg_inf "Installing required OS packages..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
    fi

    local cmd
    for cmd in curl wget jq nginx certbot sqlite3 ufw mtr python3 openssl ss tar systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command is missing: $cmd (use -install yes)."
    done
    systemctl daemon-reload
    systemctl enable nginx
}

# ─────────────────────────────────────────────────────────────────────────────
# SSL CERTIFICATES
# ─────────────────────────────────────────────────────────────────────────────
get_ssl_certs() {
    local cert_dir="/etc/letsencrypt/live/${domain}" resolved4 cert key
    cert="${cert_dir}/fullchain.pem"
    key="${cert_dir}/privkey.pem"
    resolved4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
    [[ -n "$resolved4" ]] || die "Panel domain does not have an IPv4 DNS record: $domain"
    if ! grep -Fxq "$IP4" <<< "$resolved4"; then
        msg_inf "Warning: $domain does not resolve directly to detected IPv4 $IP4 (a reverse proxy/CDN may be in use)."
    fi

    if systemctl is-active --quiet nginx; then
        NGINX_STOPPED_BY_US=1
        systemctl stop nginx
    fi

    if ! certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email --keep-until-expiring -d "$domain"; then
        ((NGINX_STOPPED_BY_US == 0)) || systemctl start nginx || true
        NGINX_STOPPED_BY_US=0
        die "Certificate issuance failed for $domain. Verify DNS and inbound TCP/80."
    fi

    ((NGINX_STOPPED_BY_US == 0)) || systemctl start nginx
    NGINX_STOPPED_BY_US=0
    [[ -s "$cert" && -s "$key" ]] || die "Certbot succeeded but certificate files are missing for $domain."
    openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 \
        || die "Certificate does not cover $domain."
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 \
        || die "Certificate for $domain expires in less than 24 hours."

    install -d -m 700 "/root/cert/${domain}"
    ln -sfn "$cert" "/root/cert/${domain}/fullchain.pem"
    ln -sfn "$key"  "/root/cert/${domain}/privkey.pem"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE NGINX
# ─────────────────────────────────────────────────────────────────────────────
configure_nginx() {
    local previous_domain candidate candidate_name
    previous_domain=$(read_state_value DOMAIN || true)
    if [[ -n "$previous_domain" && "$previous_domain" != "$domain" ]]; then
        valid_hostname "$previous_domain" || die "Existing state contains an invalid panel domain."
        rm -f "/etc/nginx/sites-enabled/${previous_domain}" \
              "/etc/nginx/sites-available/${previous_domain}"
    fi
    # Migrate installations made before the state manifest existed. Remove
    # only vhosts carrying this installer's distinctive diagnostics marker.
    for candidate in /etc/nginx/sites-available/*; do
        [[ -f "$candidate" ]] || continue
        candidate_name=${candidate##*/}
        [[ "$candidate_name" == "$domain" ]] && continue
        if grep -Fq '# Diagnostics SSO bridge' "$candidate"; then
            rm -f "/etc/nginx/sites-enabled/${candidate_name}" "$candidate"
        fi
    done
    mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets

    # nginx >= 1.25.1 deprecates "listen ... http2" in favor of "http2 on;";
    # older versions (Debian 12 / Ubuntu 24.04) don't know the new directive
    local ngx_ver http2_listen="" http2_on=""
    ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
        http2_on="http2 on;"
    else
        http2_listen=" http2"
    fi

    # SNI-based stream: reality → 8443, domain → 7443
    cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}    xray;
    ${domain}            www;
    default              xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF

    remove_nginx_managed_block
    cat >> /etc/nginx/nginx.conf <<EOF

${NGINX_BEGIN}
stream { include /etc/nginx/stream-enabled/*.conf; }
${NGINX_END}
EOF

    # HTTP → HTTPS redirect
    cat > /etc/nginx/sites-available/3x-ui-pro-http.conf <<EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
EOF

    # Shared proxy locations for xray inbounds (included by both vhosts)
    cat > /etc/nginx/snippets/includes.conf <<EOF
    #Subscription — prefix location covers all sub-paths (assets, JS, etc.)
    location /${sub_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location = /${sub_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    # Regex takes priority over prefix: catches subscription IDs (one-level deep)
    # and routes Clash/Mihomo clients to dynamic clash.yaml generator
    location ~ ^/${sub_path}/(?<clash_sub_id>[^/]+)$ {
        if (\$hack = 1) { return 404; }
        if (\$serve_clash_yaml = 1) { rewrite ^ /__clash_api?sub_id=\$clash_sub_id last; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location /assets  { proxy_pass http://127.0.0.1:${sub_port}; }
    location /assets/ { proxy_pass http://127.0.0.1:${sub_port}; }

    #Subscription (json)
    location /${json_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location /${json_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }

    #XHTTP
    location /${xhttp_path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size      16k;
        grpc_socket_keepalive on;
        grpc_read_timeout     1h;
        grpc_send_timeout     1h;
        grpc_set_header Connection        "";
        grpc_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Port  \$server_port;
        grpc_set_header Host              \$host;
        grpc_set_header X-Forwarded-Host  \$host;
    }

    # WS inbound. Keep the upstream fixed: a client-controlled port here would
    # expose arbitrary services bound to 127.0.0.1 through nginx.
    location = /${ws_port}/${ws_path} {
        if (\$hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${ws_port};
    }

    # Trojan gRPC inbound; gRPC method suffixes make this a prefix location.
    location ^~ /${trojan_port}/${trojan_path} {
        if (\$hack = 1) { return 404; }
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        grpc_socket_keepalive on;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_pass grpc://127.0.0.1:${trojan_port};
    }

    location / { try_files \$uri \$uri/ =404; }
EOF

    # HTTP-level maps. The clash maps are consumed by the shared includes.conf
    # snippet, which is included by BOTH vhosts, so they live in their own
    # always-loaded file — never inside a single vhost, or the other vhost's
    # include would reference an undefined var ("unknown ... variable").
    cat > /etc/nginx/sites-available/3x-ui-pro-maps.conf <<EOF
# Detect Clash/Mihomo clients by User-Agent
map \$http_user_agent \$is_clash_ua {
    ~*(clash|clashx|clashn|mihomo|stash|surfboard)  1;
    default                                          0;
}
# Serve clash.yaml only when: Clash UA AND no ?provider=1 query param
# (proxy-provider refresh requests add ?provider=1 and must get the real sub)
map "\$is_clash_ua:\$arg_provider" \$serve_clash_yaml {
    "1:"    1;
    default 0;
}
EOF

    # Main domain vhost (TLS termination at 7443, proxy_protocol)
    cat > "/etc/nginx/sites-available/${domain}" <<EOF
# Managed by 3x-ui-pro. Local edits may be replaced on reinstall.
# Rate limiting zones (http context)
limit_req_zone  \$binary_remote_addr zone=diag_api:10m  rate=6r/m;
limit_req_zone  \$binary_remote_addr zone=diag_page:10m rate=30r/m;
limit_conn_zone \$binary_remote_addr zone=per_ip:10m;

# Diagnostics access: cookie issued by the SSO bridge after panel login
map \$cookie_diag_key \$diag_auth {
    "${diag_token}" 1;
    default          0;
}

server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl${http2_listen} proxy_protocol;
    listen [::]:7443 ssl${http2_listen} proxy_protocol;
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/3x-ui-pro-cover/;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    # This vhost listens on 7443 behind the SNI stream (public port 443). Without
    # this, nginx bakes :7443 into redirect Location headers (return/error_page),
    # so browsers get sent to an unreachable port. Keep redirects relative.
    absolute_redirect off;
    # Larger h2 preread window improves single-stream upload throughput
    http2_body_preread_size 128k;
    client_body_buffer_size 512k;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${domain}\$)            { return 444; }
    if (\$scheme ~* https)                          { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }

    # ── Diagnostics SSO bridge ───────────────────────────────────────────────
    # Lives under the panel path so the browser attaches the 3x-ui session
    # cookie (its Path is scoped to the panel base path). Valid panel session
    # → issue the diag cookie and redirect; otherwise → panel login page.
    # NOTE: auth_request runs in the access phase; a plain "return" here would
    # skip it (rewrite phase), hence the try_files → named-location hop.
    location = /${panel_path}/diag {
        auth_request /__diag_auth;
        # Named location (not "=302 /uri") so the deny path emits a real Location
        # header; an internal-redirect error_page returns a 302 with no Location.
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login {
        return 302 /${panel_path}/;
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800";
        return 302 ${diag_path};
    }
    location = /__diag_auth {
        internal;
        proxy_pass https://127.0.0.1:${panel_port}/${panel_path}/panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # 3x-ui answers AJAX requests with 401 instead of a login redirect
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        # auth_request emits a raw 500 to the browser if the subrequest returns
        # anything other than 2xx / 401 / 403 (a login 302, or a 502 when the
        # panel's HTTPS cert is missing). Coerce every such status to a 401 deny
        # so the main location redirects to the panel login instead of 500ing.
        # 401/403 must be listed too, else the server-level "error_page 401 =404"
        # hijacks a genuine deny into a 404 (which auth_request then 500s on).
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # ── Network diagnostics page ─────────────────────────────────────────────
    # No diag cookie yet → bounce through the SSO bridge, which checks the panel
    # session and mints the cookie, so a bookmarked diag link "just works" once
    # you're logged into the panel. (Only the HTML page redirects; the API/asset
    # sub-locations below stay 404 without the cookie.)
    location ^~ ${diag_path} {
        if (\$diag_auth = 0) { return 302 /${panel_path}/diag; }
        limit_req  zone=diag_page burst=10 nodelay;
        limit_conn per_ip 5;
        alias /var/www/diagnostics/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }

    # ── Diagnostics MTR API ──────────────────────────────────────────────────
    location ^~ ${diag_path}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        limit_req  zone=diag_api burst=2 nodelay;
        limit_conn per_ip 2;
        proxy_pass         http://127.0.0.1:${mtr_backend_port}/api/mtr;
        proxy_http_version 1.1;
        proxy_set_header   X-Real-IP       \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        # Let the backend's JSON error bodies through; the server-level
        # "proxy_intercept_errors on" would otherwise rewrite a 500 into an HTML
        # 404 and break the frontend's response.json() parse.
        proxy_intercept_errors off;
    }

    # ── LibreSpeed upload sink ───────────────────────────────────────────────
    # No limit_req: librespeed fires many short POSTs (parallel streams).
    # proxy_request_buffering off = client sees true network backpressure.
    location ^~ ${diag_path}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        access_log              off;
        limit_conn              per_ip 8;
        proxy_pass              http://127.0.0.1:${mtr_backend_port}/api/st/up;
        proxy_http_version      1.1;
        proxy_set_header        X-Real-IP       \$remote_addr;
        proxy_request_buffering off;
        client_max_body_size    64m;
        proxy_read_timeout      60s;
        proxy_send_timeout      60s;
        add_header              Cache-Control "no-store" always;
    }

    # ── LibreSpeed ping endpoint (answered by nginx, no backend hop) ─────────
    location = ${diag_path}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        access_log off;
        limit_conn per_ip 8;
        add_header Cache-Control "no-store" always;
        default_type text/plain;
        return 200 "";
    }

    # ── LibreSpeed client IP ─────────────────────────────────────────────────
    location = ${diag_path}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/st/getip;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
        add_header          Cache-Control "no-store" always;
    }

    # ── Download test files ──────────────────────────────────────────────────
    location ^~ ${diag_path}testfiles/ {
        if (\$diag_auth = 0) { return 404; }
        alias      /var/www/diagnostics/testfiles/;
        access_log off;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Content-Disposition "attachment" always;
    }

    # ── Clash YAML generator — internal, proxied here by rewrite from sub_path ────
    location = /__clash_api {
        internal;
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/clash\$is_args\$args;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Activate configs
    if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
        rm -f /etc/nginx/sites-enabled/00-maps.conf /etc/nginx/sites-enabled/80.conf
        ln -sf "/etc/nginx/sites-available/3x-ui-pro-maps.conf" /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/${domain}"          /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/3x-ui-pro-http.conf" /etc/nginx/sites-enabled/
    else
        msg_err "${domain} nginx config not found!" && exit 1
    fi

    local nginx_test
    if ! nginx_test=$(nginx -t 2>&1); then
        printf '%s\n' "$nginx_test" >&2
        die "nginx configuration check failed."
    fi
    systemctl restart nginx
    systemctl is-active --quiet nginx || die "nginx did not become active."
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PANEL (3x-ui)
# ─────────────────────────────────────────────────────────────────────────────
_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)          echo 'amd64'  ;;
        i*86|x86)                  echo '386'    ;;
        armv8*|arm64|aarch64) echo 'arm64' ;;
        armv7*|arm)           echo 'armv7'  ;;
        armv6*)               echo 'armv6'  ;;
        armv5*)               echo 'armv5'  ;;
        s390x)                     echo 's390x'  ;;
        *) echo "Unsupported CPU architecture!" && exit 1 ;;
    esac
}

_panel_initial_config() {
    (
        cd /usr/local/x-ui
        ./x-ui setting -username "bootstrap" -password "$(gen_random_string 24)" \
            -port "$panel_port" -webBasePath "bootstrap" -listenIP "127.0.0.1"
        ./x-ui migrate
    ) || die "Failed to initialize or migrate the 3x-ui database."
}

version_at_least() {
    local current=${1#v} minimum=${2#v}
    [[ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)" == "$minimum" ]]
}

resolve_latest_panel_tag() {
    local effective tag
    effective=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 60 \
        https://github.com/MHSanaei/3x-ui/releases/latest) || return 1
    tag=${effective##*/tag/}
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$tag"
}

verify_panel_archive() {
    local url="$1" archive="$2"
    local sums="${archive}.sha256"
    local code expected actual
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [[ -n "${PANEL_SHA256:-}" ]]; then
        if [[ ! "$PANEL_SHA256" =~ ^[0-9a-f]{64}$ || "$PANEL_SHA256" != "$actual" ]]; then
            rm -f "$archive"
            msg_err "3x-ui archive does not match PANEL_SHA256."
            exit 1
        fi
        msg_ok "3x-ui release matches pinned PANEL_SHA256: ${actual}"
        return 0
    fi
    code=$(curl -sSL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 60 \
        -o "$sums" -w '%{http_code}' "${url}.sha256")
    if [[ "$code" != "200" ]]; then
        rm -f "$sums" "$archive"
        msg_err "Could not download release checksum (HTTP ${code})."
        exit 1
    fi
    expected=$(awk 'NR == 1 {print $1}' "$sums")
    rm -f "$sums"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ || "$expected" != "$actual" ]]; then
        rm -f "$archive"
        msg_err "3x-ui archive checksum mismatch."
        exit 1
    fi
    msg_ok "3x-ui release checksum verified: ${actual}"
}

install_panel() {
    local tag_version archive_url archive arch stage service_file
    arch=$(_arch)

    if [[ -n "$PANEL_VERSION" ]]; then
        tag_version="v${PANEL_VERSION#v}"
        [[ "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { msg_err "Invalid 3x-ui version: ${PANEL_VERSION}"; exit 1; }
    else
        tag_version=$(resolve_latest_panel_tag) \
            || { msg_err "Failed to resolve latest stable 3x-ui version."; exit 1; }
    fi
    version_at_least "$tag_version" "v3.5.0" \
        || die "3x-ui ${tag_version} is too old; this installer requires v3.5.0 or newer."
    PANEL_TAG="$tag_version"

    echo "Installing 3x-ui ${tag_version} ..."
    stage="${WORK_DIR}/panel"
    mkdir -p "$stage/unpack"
    archive="${stage}/x-ui-linux-${arch}.tar.gz"
    archive_url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-${arch}.tar.gz"
    curl -fLR --retry 5 --retry-delay 3 --connect-timeout 15 \
        --speed-limit 1 --speed-time 300 -o "$archive" "$archive_url" \
        || { rm -f "$archive"; msg_err "3x-ui archive download failed."; exit 1; }
    [[ -s "$archive" ]] || { rm -f "$archive"; msg_err "Downloaded archive is empty."; exit 1; }
    verify_panel_archive "$archive_url" "$archive"

    if ! tar -tzf "$archive" | awk '
        /^\// {bad=1}
        { n=split($0,p,"/"); for(i=1;i<=n;i++) if(p[i]=="..") bad=1 }
        END {exit bad}
    '; then
        die "Release archive contains an unsafe path."
    fi
    tar -xzf "$archive" -C "$stage/unpack" --no-same-owner --no-same-permissions
    [[ -s "$stage/unpack/x-ui/x-ui" ]] \
        || { msg_err "Release archive is missing the x-ui binary."; exit 1; }
    [[ -d "$stage/unpack/x-ui/bin" ]] || die "Release archive is missing its bin directory."

    if [[ "$arch" == "armv5" || "$arch" == "armv6" || "$arch" == "armv7" ]]; then
        [[ -s "$stage/unpack/x-ui/bin/xray-linux-${arch}" ]] || die "Release archive is missing Xray for ${arch}."
        mv "$stage/unpack/x-ui/bin/xray-linux-${arch}" "$stage/unpack/x-ui/bin/xray-linux-arm32"
        chmod +x "$stage/unpack/x-ui/bin/xray-linux-arm32"
    else
        [[ -s "$stage/unpack/x-ui/bin/xray-linux-${arch}" ]] || die "Release archive is missing Xray for ${arch}."
        chmod +x "$stage/unpack/x-ui/bin/xray-linux-${arch}"
    fi
    chmod +x "$stage/unpack/x-ui/x-ui"

    # Everything above is non-destructive. Start a rollback transaction only
    # after the release has passed checksum, path and structure validation.
    ROLLBACK_DIR="${WORK_DIR}/rollback"
    mkdir -p "$ROLLBACK_DIR"
    [[ ! -d /etc/nginx ]] || cp -a /etc/nginx "$ROLLBACK_DIR/nginx"
    [[ ! -d /var/www/diagnostics ]] || cp -a /var/www/diagnostics "$ROLLBACK_DIR/diagnostics"
    [[ ! -d /var/www/subpage ]] || cp -a /var/www/subpage "$ROLLBACK_DIR/subpage"
    [[ ! -d /var/www/3x-ui-pro-cover ]] || cp -a /var/www/3x-ui-pro-cover "$ROLLBACK_DIR/cover"
    [[ ! -f /etc/systemd/system/x-ui.service ]] || cp -a /etc/systemd/system/x-ui.service "$ROLLBACK_DIR/x-ui.service"
    [[ ! -f /etc/systemd/system/mtr-backend.service ]] || cp -a /etc/systemd/system/mtr-backend.service "$ROLLBACK_DIR/mtr-backend.service"
    [[ ! -f /usr/bin/x-ui ]] || cp -a /usr/bin/x-ui "$ROLLBACK_DIR/x-ui-cli"
    [[ ! -f "$SYSCTL_FILE" ]] || cp -a "$SYSCTL_FILE" "$ROLLBACK_DIR/sysctl.conf"
    [[ ! -f /etc/cron.d/3x-ui-pro ]] || cp -a /etc/cron.d/3x-ui-pro "$ROLLBACK_DIR/certbot-cron"
    [[ ! -f /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx ]] \
        || cp -a /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx "$ROLLBACK_DIR/certbot-pre"
    [[ ! -f /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services ]] \
        || cp -a /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services "$ROLLBACK_DIR/certbot-post"
    [[ ! -d "$STATE_DIR" ]] || cp -a "$STATE_DIR" "$ROLLBACK_DIR/state-dir"
    [[ ! -d /usr/local/x-ui ]] || cp -a /usr/local/x-ui "$ROLLBACK_DIR/old-x-ui"
    [[ ! -d /etc/x-ui ]] || cp -a /etc/x-ui "$ROLLBACK_DIR/old-etc-x-ui"
    backup_existing_database
    ROLLBACK_ACTIVE=1
    systemctl stop x-ui 2>/dev/null || true
    rm -rf /usr/local/x-ui /etc/x-ui
    mv "$stage/unpack/x-ui" /usr/local/x-ui

    # Prefer a release-bundled full CLI. Some releases omit it, so keep a
    # local integrity-checked management wrapper as a network-free fallback.
    if [[ -s /usr/local/x-ui/x-ui.sh ]]; then
        install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    else
        install -m 755 "${ASSET_DIR}/x-ui-wrapper.sh" /usr/bin/x-ui
    fi

    _panel_initial_config

    if [[ -s /usr/local/x-ui/x-ui.service ]]; then
        service_file=/usr/local/x-ui/x-ui.service
    elif [[ -s /usr/local/x-ui/x-ui.service.debian ]]; then
        service_file=/usr/local/x-ui/x-ui.service.debian
    else
        service_file="${ASSET_DIR}/systemd/x-ui.service"
    fi
    install -m 644 "$service_file" /etc/systemd/system/x-ui.service
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
    systemctl is-active --quiet x-ui || die "x-ui did not become active after installation."

    msg_ok "3x-ui ${tag_version} installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE X-UI DATABASE
# ─────────────────────────────────────────────────────────────────────────────
configure_xui_db() {
    [[ -s "$XUIDB" ]] || die "x-ui.db not found — panel may not be installed."
    sqlite3 "$XUIDB" 'PRAGMA quick_check;' | grep -Fxq ok \
        || die "x-ui database integrity check failed."
    sqlite3 "$XUIDB" "SELECT 1 FROM settings LIMIT 1; SELECT 1 FROM inbounds LIMIT 1; SELECT 1 FROM hosts LIMIT 1;" >/dev/null \
        || die "Installed 3x-ui database schema is incompatible."

    x-ui stop 2>/dev/null || true
    local stop_attempt
    for stop_attempt in {1..10}; do
        : "$stop_attempt"
        port_in_use 8443 || break
        sleep 1
    done
    port_in_use 8443 && die "TCP port 8443 is still occupied after stopping the previous Xray instance."

    local output private_key public_key emoji_flag xray_bin
    # install_panel follows the upstream arm32 binary naming convention.
    xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm32"
    [[ -x "$xray_bin" ]] || die "Xray executable is missing for $(_arch)."
    output=$("$xray_bin" x25519) || die "Xray failed to generate a REALITY key pair."
    private_key=$(awk '/^PrivateKey:/ {print $2; exit}' <<< "$output")
    public_key=$(awk '/^Password \(PublicKey\):/ {print $3; exit}' <<< "$output")
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{40,60}$ && "$public_key" =~ ^[A-Za-z0-9_-]{40,60}$ ]] \
        || die "Unexpected Xray x25519 output; refusing to write empty/invalid keys."
    # Per-host group_id: without it the panel cannot edit or delete the host.
    # The column only exists since 3x-ui v3.5.0 (pinnable via -version), so
    # probe the migrated schema and skip it on older releases.
    local gid_col="" gid_reality="" gid_ws="" gid_xhttp="" gid_trojan=""
    if sqlite3 "$XUIDB" "PRAGMA table_info(hosts);" | grep -qw "group_id"; then
        gid_col='"group_id",'
        gid_reality="'$(gen_group_id)',"
        gid_ws="'$(gen_group_id)',"
        gid_xhttp="'$(gen_group_id)',"
        gid_trojan="'$(gen_group_id)',"
    fi
    # Avoid leaking the server address to a third-party geo-IP API merely for
    # a cosmetic flag in inbound names.
    emoji_flag="🌐"

    local sub_uri="https://${domain}/${sub_path}/"
    local json_uri="https://${domain}/${json_path}?name="

    # Prepare short IDs for REALITY
    local -a shor=()
    local _
    for _ in {1..8}; do
        shor+=("$(openssl rand -hex 8)")
    done

    if ! sqlite3 "$XUIDB" <<EOF
.bail on
BEGIN IMMEDIATE;
DELETE FROM "settings" WHERE "key" IN ("webCertFile","webKeyFile");

INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subPort",             '${sub_port}');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subListen",           '127.0.0.1');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subPath",             '/${sub_path}/');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subURI",              '${sub_uri}');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonEnable",       'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonPath",         '/${json_path}/');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonURI",          '${json_uri}');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subClashEnable",      'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subEnableRouting",    'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subEnable",           'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webListen",           '127.0.0.1');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webDomain",           '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webCertFile",         '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webKeyFile",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("sessionMaxAge",       '60');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("pageSize",            '50');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("expireDiff",          '0');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("trafficDiff",         '0');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotEnable",         'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotToken",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotProxy",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotAPIServer",      '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotChatId",         '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgRunTime",           '@daily');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotBackup",         'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgCpu",               '80');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgLang",              'en-US');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("timeLocation",        'Local');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subDomain",           '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subCertFile",         '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subKeyFile",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subUpdates",          '12');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subEncrypt",          'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonMux",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonRules",        '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("datepicker",          'gregorian');

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} reality','1','0','127.0.0.1','8443','vless',
    '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
    '{
  "network": "tcp",
  "security": "reality",
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "${reality_domain}:443",
    "serverNames": ["${reality_domain}"],
    "privateKey": "${private_key}",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}","${shor[1]}","${shor[2]}","${shor[3]}",
      "${shor[4]}","${shor[5]}","${shor[6]}","${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "firefox",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": {"type":"none"}
  }
}',
    'inbound-8443',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} ws','1','0','127.0.0.1','${ws_port}','vless',
    '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
    '{
  "network": "ws",
  "security": "none",
  "wsSettings": {
    "acceptProxyProtocol": false,
    "path": "/${ws_port}/${ws_path}",
    "host": "${domain}",
    "headers": {}
  }
}',
    'inbound-${ws_port}',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} xhttp','0','0','/dev/shm/uds2023.sock,0666','0','vless',
    '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
    '{
  "network": "xhttp",
  "security": "none",
  "xhttpSettings": {
    "path": "/${xhttp_path}",
    "host": "${domain}",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "packet-up"
  },
  "sockopt": {
    "acceptProxyProtocol": false,
    "tcpFastOpen": true,
    "mark": 0,
    "tproxy": "off",
    "tcpMptcp": true,
    "tcpNoDelay": true,
    "domainStrategy": "UseIP",
    "tcpMaxSeg": 1440,
    "dialerProxy": "",
    "tcpKeepAliveInterval": 0,
    "tcpKeepAliveIdle": 300,
    "tcpUserTimeout": 10000,
    "tcpcongestion": "bbr",
    "V6Only": false,
    "tcpWindowClamp": 600,
    "interface": ""
  }
}',
    'inbound-/dev/shm/uds2023.sock,0666:0|',
    '{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} trojan-grpc','1','0','127.0.0.1','${trojan_port}','trojan',
    '{
  "clients": [],
  "fallbacks": []
}',
    '{
  "network": "grpc",
  "security": "none",
  "grpcSettings": {
    "serviceName": "/${trojan_port}/${trojan_path}",
    "authority": "${domain}",
    "multiMode": false
  }
}',
    'inbound-${trojan_port}',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

-- Hosts supersede the legacy externalProxy arrays: one host per inbound,
-- rendered as the share-link endpoint at subscription time.
-- REALITY keeps its own TLS params (security=same); the rest front through
-- nginx at :443 with TLS.
INSERT INTO "hosts" ("inbound_id",${gid_col}"sort_order","remark","address","port","security","fingerprint","alpn")
VALUES
    ((SELECT id FROM inbounds WHERE tag='inbound-8443'),           ${gid_reality} 0, 'reality', '${domain}', 443, 'same', '',        '[]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-${ws_port}'),     ${gid_ws}      0, 'ws',      '${domain}', 443, 'tls',  'firefox', '["h2","http/1.1"]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-/dev/shm/uds2023.sock,0666:0|'), ${gid_xhttp} 0, 'xhttp', '${domain}', 443, 'tls', 'firefox', '["h2","http/1.1"]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-${trojan_port}'), ${gid_trojan}  0, 'trojan',  '${domain}', 443, 'tls',  'firefox', '["h2","http/1.1"]');
COMMIT;
EOF
    then
        msg_err "Failed to configure the 3x-ui database; transaction rolled back."
        exit 1
    fi

    /usr/local/x-ui/x-ui setting \
        -username  "${config_username}" \
        -password  "${config_password}" \
        -port      "${panel_port}"      \
        -webBasePath "${panel_path}" \
        -listenIP "127.0.0.1" \
        || die "Failed to apply panel credentials and path."

    /usr/local/x-ui/x-ui cert \
        -webCert    "/root/cert/${domain}/fullchain.pem" \
        -webCertKey "/root/cert/${domain}/privkey.pem" \
        || die "Failed to apply the panel certificate."

    x-ui restart
    systemctl is-active --quiet x-ui || die "x-ui failed after database configuration."
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL FAKE SITE
# ─────────────────────────────────────────────────────────────────────────────
install_clash_sub() {
    local clash_dir="/var/www/subpage"
    mkdir -p "${clash_dir}"
    if install -m 644 "${ASSET_DIR}/clash/clash.yaml" "${clash_dir}/clash.yaml.tpl"; then
        # Substitute deployment values; SUB_ID is filled per request.
        sed -i "s|\${DOMAIN}|${domain}|g"     "${clash_dir}/clash.yaml.tpl"
        sed -i "s|\${SUB_PATH}|${sub_path}|g" "${clash_dir}/clash.yaml.tpl"
        chown -R www-data:www-data "${clash_dir}" 2>/dev/null || true
        chmod 644 "${clash_dir}/clash.yaml.tpl"
        msg_ok "Clash subscription template installed."
    else
        msg_err "Failed to install local clash.yaml template."
        exit 1
    fi
}

install_fake_site() {
    mkdir -p /var/www/3x-ui-pro-cover
    if install -m 644 "${ASSET_DIR}/fake-site/index.html" /var/www/3x-ui-pro-cover/index.html; then
        chown -R www-data:www-data /var/www/3x-ui-pro-cover 2>/dev/null || true
        chmod 644 /var/www/3x-ui-pro-cover/index.html
        msg_ok "Local cover site installed."
    else
        msg_err "Failed to install local cover site."
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL NETWORK DIAGNOSTICS PAGE
# ─────────────────────────────────────────────────────────────────────────────
install_diagnostics() {
    local diag_webroot="/var/www/diagnostics"
    local backend_script="/usr/local/lib/3x-ui-pro/mtr-backend.py"

    # All application assets are shipped with this installer and verified
    # before the system is modified; installation needs no raw GitHub fetches.
    mkdir -p "${diag_webroot}"
    install -m 644 "${ASSET_DIR}/diagnostics/index.html" "${diag_webroot}/index.html"
    sed -i \
        -e "s|__DIAG_PATH__|${diag_path}|g" \
        -e "s|__SERVER_DOMAIN__|${domain}|g" \
        -e "s|__SERVER_IP__|${IP4}|g" \
        "${diag_webroot}/index.html"

    # LibreSpeed engine (speed test frontend, LGPL — github.com/librespeed/speedtest)
    install -m 644 "${ASSET_DIR}/diagnostics/librespeed/speedtest.js" \
        "${diag_webroot}/speedtest.js"
    install -m 644 "${ASSET_DIR}/diagnostics/librespeed/speedtest_worker.js" \
        "${diag_webroot}/speedtest_worker.js"

    # Test download files
    local testfiles="${diag_webroot}/testfiles"
    mkdir -p "${testfiles}"
    # Sparse files produce the same zero-filled network payload without
    # consuming ~1.1 GiB of physical disk space on a small VPS.
    truncate -s 15K  "${testfiles}/test-15k.bin"
    truncate -s 17K  "${testfiles}/test-17k.bin"
    truncate -s 100M "${testfiles}/test-100m.bin"
    truncate -s 1G   "${testfiles}/test-1g.bin"
    rm -f "${testfiles}/test-512m.bin"   # only used by the old single-stream speed test
    chown -R www-data:www-data "${diag_webroot}" 2>/dev/null || true

    # MTR backend Python script
    mkdir -p "$(dirname "${backend_script}")"
    install -m 755 "${ASSET_DIR}/diagnostics/mtr-backend.py" "${backend_script}"

    # Grant mtr raw socket capability (runs as restricted user, no root needed)
    # mtr-packet is the helper that actually opens the raw socket
    command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr)"        2>/dev/null || true
    command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr-packet)" 2>/dev/null || true

    # Dedicated system user for mtr-backend
    id mtr-backend &>/dev/null || \
        useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

    # Systemd service for mtr-backend
    cat > /etc/systemd/system/mtr-backend.service <<EOF
[Unit]
Description=3x-ui-pro MTR diagnostics backend
After=network.target

[Service]
Type=simple
User=mtr-backend
Group=mtr-backend
ExecStart=/usr/bin/python3 ${backend_script} --port ${mtr_backend_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RemoveIPC=yes
# mtr-packet opens raw ICMP sockets. NoNewPrivileges=yes strips the file
# capability off the mtr binary, so grant CAP_NET_RAW the systemd-native way
# (ambient caps survive NoNewPrivileges). Empty here = mtr fails with
# "Failure to open IPv4 sockets: Permission denied".
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtr-backend

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtr-backend
    systemctl restart mtr-backend
    systemctl is-active --quiet mtr-backend || die "mtr-backend did not become active."
    local health_ok=0 attempt
    for attempt in {1..10}; do
        if curl -fsS --connect-timeout 2 --max-time 3 \
            --noproxy '*' \
            "http://127.0.0.1:${mtr_backend_port}/health" >/dev/null; then
            health_ok=1
            break
        fi
        sleep 1
    done
    ((health_ok == 1)) || die "mtr-backend health check failed."

    msg_ok "Network diagnostics installed at https://${domain}/${panel_path}/diag (panel login required)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM TUNING (BBR + kernel params)
# ─────────────────────────────────────────────────────────────────────────────
tune_system() {
    local -a params=(
        "fs.file-max=2097152"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_window_scaling=1"
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
        "net.ipv4.tcp_rmem=4096 87380 16777216"
        "net.ipv4.tcp_wmem=4096 65536 16777216"
    )
    if modprobe tcp_bbr 2>/dev/null \
       && sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        params=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" "${params[@]}")
    else
        msg_inf "Warning: this kernel does not expose BBR; applying the remaining safe TCP parameters."
    fi
    {
        echo "# Managed by 3x-ui-pro. Remove this file to revert these tunables."
        printf '%s\n' "${params[@]}"
    } > "$SYSCTL_FILE"
    if ! sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        rm -f "$SYSCTL_FILE"
        msg_inf "Warning: kernel tuning is not permitted on this host; skipped without affecting the installation."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CRON JOBS
# ─────────────────────────────────────────────────────────────────────────────
setup_cron() {
    # Use Certbot's distro-managed timer/cron and install idempotent hooks.
    # The post hook always brings nginx back even when a renewal attempt fails.
    install -d -m 755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx <<'EOF'
#!/bin/sh
systemctl stop nginx
EOF
    cat > /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services <<'EOF'
#!/bin/sh
systemctl start nginx
systemctl try-restart x-ui >/dev/null 2>&1 || true
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx \
              /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services
    rm -f /etc/cron.d/3x-ui-pro
    systemctl enable --now certbot.timer 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
setup_firewall() {
    [[ "${SKIP_FIREWALL:-0}" != "1" ]] || {
        msg_inf "Firewall setup skipped because SKIP_FIREWALL=1."
        return 0
    }
    local -a ssh_ports=()
    local port sshd_bin=""
    if [[ -n "$SSH_PORT" ]]; then
        ssh_ports+=("$SSH_PORT")
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_ports+=("${SSH_CONNECTION##* }")
    else
        sshd_bin=$(command -v sshd || true)
        [[ -n "$sshd_bin" ]] || [[ ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
        if [[ -n "$sshd_bin" ]]; then
            while read -r _ port; do
                [[ "$port" =~ ^[0-9]+$ ]] && ssh_ports+=("$port")
            done < <("$sshd_bin" -T 2>/dev/null | awk '$1=="port" {print $1, $2}' || true)
        fi
    fi

    if ((${#ssh_ports[@]} == 0)); then
        if ufw status 2>/dev/null | grep -q '^Status: active'; then
            die "UFW is active but the SSH port could not be detected. Set SSH_PORT explicitly."
        fi
        msg_inf "Warning: SSH port was not detectable; UFW was not enabled. Set SSH_PORT and rerun to enable it safely."
        return 0
    fi
    for port in "${ssh_ports[@]}"; do
        if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            die "Invalid SSH port: $port"
        fi
        ufw allow "${port}/tcp"
    done
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW RESULTS
# ─────────────────────────────────────────────────────────────────────────────
rollback_install() {
    ((ROLLBACK_ACTIVE == 1)) || return 0
    msg_inf "Installation failed; restoring the previous installation..."
    systemctl stop x-ui mtr-backend nginx 2>/dev/null || true

    rm -rf /usr/local/x-ui /etc/x-ui
    [[ ! -d "$ROLLBACK_DIR/old-x-ui" ]] || mv "$ROLLBACK_DIR/old-x-ui" /usr/local/x-ui
    [[ ! -d "$ROLLBACK_DIR/old-etc-x-ui" ]] || mv "$ROLLBACK_DIR/old-etc-x-ui" /etc/x-ui

    if [[ -f "$ROLLBACK_DIR/x-ui.service" ]]; then
        cp -a "$ROLLBACK_DIR/x-ui.service" /etc/systemd/system/x-ui.service
    else
        rm -f /etc/systemd/system/x-ui.service
    fi
    if [[ -f "$ROLLBACK_DIR/mtr-backend.service" ]]; then
        cp -a "$ROLLBACK_DIR/mtr-backend.service" /etc/systemd/system/mtr-backend.service
    else
        rm -f /etc/systemd/system/mtr-backend.service
    fi
    if [[ -f "$ROLLBACK_DIR/x-ui-cli" ]]; then
        cp -a "$ROLLBACK_DIR/x-ui-cli" /usr/bin/x-ui
    else
        rm -f /usr/bin/x-ui
    fi
    if [[ -d "$ROLLBACK_DIR/nginx" ]]; then
        rm -f "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}" \
              /etc/nginx/sites-available/3x-ui-pro-maps.conf \
              /etc/nginx/sites-available/3x-ui-pro-http.conf \
              /etc/nginx/sites-enabled/3x-ui-pro-maps.conf \
              /etc/nginx/sites-enabled/3x-ui-pro-http.conf \
              /etc/nginx/stream-enabled/stream.conf \
              /etc/nginx/snippets/includes.conf
        cp -a "$ROLLBACK_DIR/nginx/." /etc/nginx/
    fi

    rm -rf /var/www/diagnostics /var/www/subpage /var/www/3x-ui-pro-cover "$STATE_DIR"
    [[ ! -d "$ROLLBACK_DIR/diagnostics" ]] || cp -a "$ROLLBACK_DIR/diagnostics" /var/www/diagnostics
    [[ ! -d "$ROLLBACK_DIR/subpage" ]] || cp -a "$ROLLBACK_DIR/subpage" /var/www/subpage
    [[ ! -d "$ROLLBACK_DIR/cover" ]] || cp -a "$ROLLBACK_DIR/cover" /var/www/3x-ui-pro-cover
    [[ ! -d "$ROLLBACK_DIR/state-dir" ]] || cp -a "$ROLLBACK_DIR/state-dir" "$STATE_DIR"
    if [[ -f "$ROLLBACK_DIR/sysctl.conf" ]]; then
        cp -a "$ROLLBACK_DIR/sysctl.conf" "$SYSCTL_FILE"
    else
        rm -f "$SYSCTL_FILE"
    fi
    rm -f /etc/cron.d/3x-ui-pro \
          /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx \
          /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services
    [[ ! -f "$ROLLBACK_DIR/certbot-cron" ]] || cp -a "$ROLLBACK_DIR/certbot-cron" /etc/cron.d/3x-ui-pro
    [[ ! -f "$ROLLBACK_DIR/certbot-pre" ]] || cp -a "$ROLLBACK_DIR/certbot-pre" /etc/letsencrypt/renewal-hooks/pre/3x-ui-pro-stop-nginx
    [[ ! -f "$ROLLBACK_DIR/certbot-post" ]] || cp -a "$ROLLBACK_DIR/certbot-post" /etc/letsencrypt/renewal-hooks/post/3x-ui-pro-restart-services

    systemctl daemon-reload 2>/dev/null || true
    [[ ! -d /usr/local/x-ui ]] || systemctl enable --now x-ui 2>/dev/null || true
    [[ ! -f /etc/systemd/system/mtr-backend.service ]] || systemctl enable --now mtr-backend 2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    ROLLBACK_ACTIVE=0
}

on_exit() {
    local status="$1"
    trap - EXIT
    set +e
    if ((status != 0)); then
        [[ -z "$LAST_ERROR" ]] || msg_err "Failure context: $LAST_ERROR"
        ((NGINX_STOPPED_BY_US == 0)) || systemctl start nginx 2>/dev/null || true
        rollback_install
    fi
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
    exit "$status"
}

commit_install() {
    ROLLBACK_ACTIVE=0
    [[ -z "$ROLLBACK_DIR" || ! -d "$ROLLBACK_DIR" ]] || rm -rf "$ROLLBACK_DIR"
}

preflight_fixed_ports() {
    local existing_state=0 port
    [[ -r "$STATE_FILE" ]] && existing_state=1
    for port in 7443 8443; do
        if port_in_use "$port" && ((existing_state == 0)); then
            die "Required local port $port is already in use on a fresh installation."
        fi
    done
}

persist_install_state() {
    install -d -m 700 "$STATE_DIR"
    local tmp="${STATE_FILE}.tmp"
    {
        printf 'DOMAIN=%s\n' "$domain"
        printf 'REALITY_TARGET=%s\n' "$reality_domain"
        printf 'PANEL_VERSION=%s\n' "$PANEL_TAG"
        printf 'PANEL_USERNAME=%s\n' "$config_username"
        printf 'PANEL_PASSWORD=%s\n' "$config_password"
        printf 'PANEL_PATH=%s\n' "$panel_path"
        printf 'PANEL_PORT=%s\n' "$panel_port"
        printf 'SUB_PATH=%s\n' "$sub_path"
        printf 'JSON_PATH=%s\n' "$json_path"
        printf 'DIAG_PATH=%s\n' "$diag_path"
    } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

health_check() {
    local -a services=(x-ui nginx mtr-backend)
    local -a ports=(443 7443 8443 "$panel_port" "$sub_port" "$ws_port" "$trojan_port" "$mtr_backend_port")
    local service port attempt http_code sub_code
    nginx -t
    for service in "${services[@]}"; do
        systemctl is-active --quiet "$service" || die "Health check failed: $service is not active."
    done
    for port in "${ports[@]}"; do
        for attempt in {1..20}; do
            : "$attempt"
            port_in_use "$port" && break
            sleep 1
        done
        port_in_use "$port" || die "Health check failed: TCP port $port is not listening."
    done
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
        --noproxy '*' --connect-timeout 5 --max-time 15 \
        --resolve "${domain}:443:127.0.0.1" "https://${domain}/${panel_path}/") \
        || die "Health check failed: panel HTTPS request could not be completed."
    [[ "$http_code" =~ ^(200|301|302|303|307|308|401|403)$ ]] \
        || die "Health check failed: panel returned HTTP $http_code."
    sub_code=$(curl -sS -o /dev/null -w '%{http_code}' \
        --noproxy '*' --connect-timeout 3 --max-time 10 "http://127.0.0.1:${sub_port}/${sub_path}/") \
        || die "Health check failed: subscription server is unreachable."
    [[ "$sub_code" != "000" && "$sub_code" != 5* ]] \
        || die "Health check failed: subscription server returned HTTP $sub_code."
}

show_results() {
    msg_inf "────────────────────────────────────────────────────────────────────────────────"
    msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
    msg_inf "REALITY camouflage target: ${reality_domain}:443\n"
    printf 'Username:  %s\nPassword:  %s\n\n' "$config_username" "$config_password"
    msg_inf "Network Diagnostics: https://${domain}/${panel_path}/diag\n"
    msg_inf "Credentials/state (root only): ${STATE_FILE}\n"
    msg_inf "────────────────────────────────────────────────────────────────────────────────"
    msg_ok "Installation completed and all health checks passed."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    WORK_DIR=$(mktemp -d /tmp/3x-ui-pro.XXXXXX)
    trap 'LAST_ERROR="line ${LINENO}: ${BASH_COMMAND}"' ERR
    trap 'on_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    validate_domains
    verify_local_assets
    install_packages
    get_server_ip
    validate_reality_target
    generate_install_values
    preflight_fixed_ports
    get_ssl_certs
    install_panel
    configure_xui_db
    install_clash_sub
    install_fake_site
    install_diagnostics
    tune_system
    setup_cron
    configure_nginx
    setup_firewall
    systemctl restart x-ui
    health_check
    persist_install_state
    commit_install
    show_results
}

main
