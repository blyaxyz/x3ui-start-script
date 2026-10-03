#!/bin/bash
#################### x-ui-pro-refactor @ github.com/mozaroc #############################
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }
umask 077

# ─── Output helpers ──────────────────────────────────────────────────────────
msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────
check_os() {
    local os_id os_version
    os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
    os_version=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release 2>/dev/null)

    case "${os_id}" in
        ubuntu)
            [[ "$os_version" == "24.04" || "$os_version" == "26.04" ]] && return 0
            ;;
        debian)
            [[ "$os_version" == "12" || "$os_version" == "13" ]] && return 0
            ;;
    esac

    msg_err "Unsupported OS: ${os_id} ${os_version}"
    echo -e "\nThis script supports:\n  Ubuntu 24.04 / 26.04\n  Debian 12 / 13"
    echo -e "\nPlease reinstall your server with one of the supported OS versions and try again."
    exit 1
}

check_cpu() {
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)

    if echo "$cpu_model" | grep -qi 'QEMU'; then
        msg_err "QEMU virtual CPU detected!"
        echo -e "\nYour VPS is running with an emulated QEMU processor."
        echo -e "Please contact your hosting provider and ask them to switch the CPU type"
        echo -e "to \e[1;33mhost-passthrough\e[0m (expose real CPU model to the VM)."
        echo -e "\nThis is required for correct operation of the Xray core."
        exit 1
    fi
}

check_os
check_cpu

# ─── Constants ───────────────────────────────────────────────────────────────
XUIDB="/etc/x-ui/x-ui.db"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ASSET_DIR="${ASSET_DIR:-${SCRIPT_DIR}/assets}"

# ─── Default argument values ─────────────────────────────────────────────────
domain=""
reality_domain=""
UNINSTALL="x"
INSTALL="y"
AUTODOMAIN="n"

# ─── Stop & clean previous install (called from main, after domain validation) ─
clean_previous_install() {
    systemctl stop x-ui 2>/dev/null || true
    if [[ -f "$XUIDB" ]]; then
        local backup_dir
        backup_dir="/root/3x-ui-pro-backups/$(date +%Y%m%d-%H%M%S)"
        install -d -m 700 "$backup_dir"
        install -m 600 "$XUIDB" "$backup_dir/x-ui.db"
        msg_inf "Existing database backed up to ${backup_dir}/x-ui.db"
    fi
    rm -f /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
    # Remove only files owned by this installer. Other nginx sites belong to
    # the administrator and must survive a panel reinstall.
    rm -f /etc/nginx/sites-enabled/00-maps.conf \
          /etc/nginx/sites-enabled/80.conf \
          "/etc/nginx/sites-enabled/${domain}" \
          "/etc/nginx/sites-enabled/${reality_domain}"
    rm -f /etc/nginx/sites-available/00-maps.conf \
          /etc/nginx/sites-available/80.conf \
          "/etc/nginx/sites-available/${domain}" \
          "/etc/nginx/sites-available/${reality_domain}" \
          /etc/nginx/stream-enabled/stream.conf \
          /etc/nginx/snippets/includes.conf
}

verify_local_assets() {
    local manifest="${ASSET_DIR}/SHA256SUMS"
    [[ -r "$manifest" ]] || { msg_err "Missing asset manifest: $manifest"; exit 1; }
    (cd "$ASSET_DIR" && sha256sum -c SHA256SUMS) \
        || { msg_err "Local asset verification failed."; exit 1; }
}

# ─── Port / path generators ──────────────────────────────────────────────────
get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

# Matches the panel's host group_id format (16 lowercase alphanumerics)
gen_group_id() {
    head -c 4096 /dev/urandom | tr -dc 'a-z0-9' | head -c 16
    echo
}

check_free() {
    nc -z 127.0.0.1 "$1" &>/dev/null
    return $?
}

make_port() {
    while true; do
        local PORT
        PORT=$(get_port)
        if ! check_free "$PORT"; then
            echo "$PORT"
            break
        fi
    done
}

# ─── Generate ports & paths (done once at startup) ───────────────────────────
sub_port=$(make_port)
panel_port=$(make_port)
ws_port=$(make_port)
trojan_port=$(make_port)

sub_path=$(gen_random_string 10)
json_path=$(gen_random_string 10)
panel_path=$(gen_random_string 10)
ws_path=$(gen_random_string 10)
trojan_path=$(gen_random_string 10)
xhttp_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)
diag_path="/net-$(gen_random_string 12)/"
diag_token=$(gen_random_string 16)
mtr_backend_port=$(make_port)

# ─── Argument parsing ────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
    case "$1" in
        -install)          INSTALL="$2";           shift 2 ;;
        -subdomain)        domain="$2";            shift 2 ;;
        -reality_domain)   reality_domain="$2";    shift 2 ;;
        -ONLY_CF_IP_ALLOW) msg_err "-ONLY_CF_IP_ALLOW is not implemented; refusing to ignore it."; exit 2 ;;
        -version)          PANEL_VERSION="$2";     shift 2 ;;
        -uninstall)        UNINSTALL="$2";         shift 2 ;;
        *)                 shift 1 ;;
    esac
done

# ─── Detect package manager ───────────────────────────────────────────────────
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
uninstall_xui() {
    printf 'y\n' | x-ui uninstall 2>/dev/null || true
    rm -rf /etc/x-ui/ /usr/local/x-ui/
    rm -f  /usr/bin/x-ui
    rm -rf /var/www/diagnostics/ /var/www/subpage/
    rm -f /var/www/html/index.html
    rm -f /etc/nginx/stream-enabled/stream.conf \
          /etc/nginx/sites-enabled/00-maps.conf \
          /etc/nginx/sites-enabled/80.conf \
          /etc/nginx/sites-available/00-maps.conf \
          /etc/nginx/sites-available/80.conf \
          /etc/nginx/snippets/includes.conf \
          /etc/cron.d/3x-ui-pro
    if [[ -n "$domain" ]]; then
        rm -f "/etc/nginx/sites-enabled/${domain}" "/etc/nginx/sites-available/${domain}"
    fi
    if [[ -n "$reality_domain" ]]; then
        rm -f "/etc/nginx/sites-enabled/${reality_domain}" "/etc/nginx/sites-available/${reality_domain}"
    fi
    systemctl stop mtr-backend 2>/dev/null || true
    systemctl disable mtr-backend 2>/dev/null || true
    rm -f /etc/systemd/system/mtr-backend.service
    rm -rf /usr/local/lib/3x-ui-pro/
    systemctl daemon-reload 2>/dev/null || true
}

if [[ ${UNINSTALL} == *"y"* ]]; then
    uninstall_xui
    clear && msg_ok "Completely Uninstalled!" && exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# GET SERVER IP
# ─────────────────────────────────────────────────────────────────────────────
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"

get_server_ip() {
    IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
    IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
    [[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')
    [[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com | tr -d '[:space:]')
}

# Early IP fetch for auto-domain
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')


# ─────────────────────────────────────────────────────────────────────────────
# DOMAIN VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_domains() {
    while true; do
        [[ -n "$domain" ]] && break
        echo -en "Enter available subdomain (sub.domain.tld): " && read -r domain
    done
    domain=$(echo "$domain" | tr -d '[:space:]')
    domain=${domain,,}
    if [[ ${#domain} -gt 253 || ! "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
        msg_err "Invalid panel domain: ${domain}"
        exit 1
    fi
    SubDomain=$(echo "$domain"   | sed 's/^[^ ]* \|\..*//g')
    MainDomain=$(echo "$domain"  | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] && MainDomain=${domain}

    while true; do
        [[ -n "$reality_domain" ]] && break
        echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read -r reality_domain
    done
    reality_domain=$(echo "$reality_domain" | tr -d '[:space:]')
    reality_domain=${reality_domain,,}
    if [[ ${#reality_domain} -gt 253 || ! "$reality_domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
        msg_err "Invalid REALITY domain: ${reality_domain}"
        exit 1
    fi
    RealitySubDomain=$(echo "$reality_domain" | sed 's/^[^ ]* \|\..*//g')
    RealityMainDomain=$(echo "$reality_domain" | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] && RealityMainDomain=${reality_domain}

    if [[ "$domain" == "$reality_domain" ]]; then
        msg_err "Panel domain and REALITY domain must be different! Got: ${domain}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    if [[ ${INSTALL} == *"y"* ]]; then
        local version
        version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
        [[ "$version" == "20" || "$version" == "22" ]] && echo "System: Ubuntu $version"

        $Pak -y update
        $Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd mtr python3 libcap2-bin openssl
        systemctl daemon-reload && systemctl enable --now nginx
    fi

    apt-get install -yqq --no-install-recommends ca-certificates
}

# ─────────────────────────────────────────────────────────────────────────────
# SSL CERTIFICATES
# ─────────────────────────────────────────────────────────────────────────────
get_ssl_certs() {
    systemctl stop nginx 2>/dev/null || true

    if [[ ${AUTODOMAIN} == *"y"* ]]; then
        local resolve_ok=true
        for d in "$domain" "$reality_domain"; do
            local a
            a=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
            if [[ "$a" != "$IP4" ]]; then
                msg_err "Auto-domain $d does not resolve to $IP4. Fix DNS and retry."
                resolve_ok=false
            fi
        done
        [[ $resolve_ok == false ]] && exit 1
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$domain"
    if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$domain SSL could not be generated! Check Domain/IP." && exit 1
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$reality_domain"
    if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$reality_domain SSL could not be generated! Check Domain/IP." && exit 1
    fi

    mkdir -p /root/cert/${domain}
    chmod 755 /root/cert/*
    ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
    ln -sf /etc/letsencrypt/live/${domain}/privkey.pem   /root/cert/${domain}/privkey.pem
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE NGINX
# ─────────────────────────────────────────────────────────────────────────────
configure_nginx() {
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

    grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* \
        || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
    grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* \
        || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
    grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* \
        || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
    sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

    # HTTP → HTTPS redirect
    cat > /etc/nginx/sites-available/80.conf <<EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
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
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${sub_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
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
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /assets  { proxy_pass https://127.0.0.1:${sub_port}; }
    location /assets/ { proxy_pass https://127.0.0.1:${sub_port}; }

    #Subscription (json)
    location /${json_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /${json_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
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
    cat > /etc/nginx/sites-available/00-maps.conf <<EOF
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
    root /var/www/html/;
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

    # Reality domain vhost (plain TLS at 9443, no proxy_protocol)
    cat > "/etc/nginx/sites-available/${reality_domain}" <<EOF
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 9443 ssl${http2_listen};
    listen [::]:9443 ssl${http2_listen};
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${reality_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${reality_domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${reality_domain}\$)            { return 444; }
    if (\$scheme ~* https)                                  { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                        { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Activate configs
    if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
        ln -sf "/etc/nginx/sites-available/00-maps.conf"       /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/${domain}"          /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/${reality_domain}"  /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/80.conf"            /etc/nginx/sites-enabled/
    else
        msg_err "${domain} nginx config not found!" && exit 1
    fi

    if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
        msg_err "nginx config check failed!" && exit 1
    fi

    systemctl start nginx
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
    /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"
    /usr/local/x-ui/x-ui migrate
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
    local tag_version archive_url archive arch
    apt-get update && apt-get install -y -q wget curl tar tzdata

    cd /usr/local/ || exit 1
    arch=$(_arch)

    if [[ -n "$PANEL_VERSION" ]]; then
        tag_version="v${PANEL_VERSION#v}"
        [[ "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { msg_err "Invalid 3x-ui version: ${PANEL_VERSION}"; exit 1; }
    else
        tag_version=$(resolve_latest_panel_tag) \
            || { msg_err "Failed to resolve latest stable 3x-ui version."; exit 1; }
    fi

    echo "Installing 3x-ui ${tag_version} ..."
    archive="/usr/local/x-ui-linux-${arch}.tar.gz"
    archive_url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-${arch}.tar.gz"
    curl -fLR --retry 5 --retry-delay 3 --connect-timeout 15 \
        --speed-limit 1 --speed-time 300 -o "$archive" "$archive_url" \
        || { rm -f "$archive"; msg_err "3x-ui archive download failed."; exit 1; }
    [[ -s "$archive" ]] || { rm -f "$archive"; msg_err "Downloaded archive is empty."; exit 1; }
    verify_panel_archive "$archive_url" "$archive"

    # Do not destroy a working installation until the replacement archive and
    # all local assets have passed integrity checks.
    clean_previous_install

    tar zxvf "$archive"
    rm -f "$archive"

    cd x-ui || exit 1
    [[ -s x-ui && -s x-ui.sh ]] \
        || { msg_err "Release archive is missing x-ui or x-ui.sh."; exit 1; }
    chmod +x x-ui x-ui.sh

    if [[ "$arch" == "armv5" || "$arch" == "armv6" || "$arch" == "armv7" ]]; then
        mv "bin/xray-linux-${arch}" bin/xray-linux-arm32
        chmod +x bin/xray-linux-arm32
    else
        chmod +x "bin/xray-linux-${arch}"
    fi

    # Install the CLI bundled in the checksum-verified release archive.
    install -m 755 x-ui.sh /usr/bin/x-ui

    _panel_initial_config

    cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui

    msg_ok "3x-ui ${tag_version} installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE X-UI DATABASE
# ─────────────────────────────────────────────────────────────────────────────
configure_xui_db() {
    if [[ ! -f $XUIDB ]]; then
        msg_err "x-ui.db not found — panel may not be installed." && exit 1
    fi

    x-ui stop 2>/dev/null || true

    local output private_key public_key emoji_flag xray_bin
    # install_panel follows the upstream arm32 binary naming convention.
    xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm32"
    output=$("$xray_bin" x25519)
    private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
    public_key=$(echo "$output"  | grep "^Password"   | awk '{print $3}')
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
UPDATE "settings" SET "value" = '/${sub_path}/' WHERE "key" = 'subPath';
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subURI",              '${sub_uri}');
UPDATE "settings" SET "value" = '/${json_path}/' WHERE "key" = 'subJsonPath';
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonURI",          '${json_uri}');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subClashEnable",      'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subEnableRouting",    'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subEnable",           'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webListen",           '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webDomain",           '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webCertFile",         '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("webKeyFile",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("sessionMaxAge",       '60');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("pageSize",            '50');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("expireDiff",          '0');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("trafficDiff",         '0');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("remarkModel",         '-ieo');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotEnable",         'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotToken",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotProxy",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotAPIServer",      '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotChatId",         '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgRunTime",           '@daily');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotBackup",         'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgBotLoginNotify",    'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgCpu",               '80');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("tgLang",              'en-US');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("timeLocation",        'Europe/Moscow');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("secretEnable",        'false');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subDomain",           '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subCertFile",         '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subKeyFile",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subUpdates",          '12');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subEncrypt",          'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subShowInfo",         'true');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonFragment",     '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonNoises",       '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonMux",          '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("subJsonRules",        '');
INSERT OR REPLACE INTO "settings" ("key","value") VALUES ("datepicker",          'gregorian');

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} reality','1','0','','8443','vless',
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
    "target": "127.0.0.1:9443",
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
    '1','0','0','0','${emoji_flag} ws','1','0','','${ws_port}','vless',
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
    '1','0','0','0','${emoji_flag} trojan-grpc','1','0','','${trojan_port}','trojan',
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
        -webBasePath "${panel_path}"

    /usr/local/x-ui/x-ui cert \
        -webCert    "/root/cert/${domain}/fullchain.pem" \
        -webCertKey "/root/cert/${domain}/privkey.pem"

    x-ui start
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
    mkdir -p /var/www/html
    if install -m 644 "${ASSET_DIR}/fake-site/index.html" /var/www/html/index.html; then
        chown -R www-data:www-data /var/www/html 2>/dev/null || true
        chmod 644 /var/www/html/index.html
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
    [[ -f "${testfiles}/test-15k.bin"  ]] || dd if=/dev/zero bs=1024    count=15   of="${testfiles}/test-15k.bin"  status=none
    [[ -f "${testfiles}/test-17k.bin"  ]] || dd if=/dev/zero bs=1024    count=17   of="${testfiles}/test-17k.bin"  status=none
    [[ -f "${testfiles}/test-100m.bin" ]] || dd if=/dev/zero bs=1048576 count=100  of="${testfiles}/test-100m.bin" status=none
    [[ -f "${testfiles}/test-1g.bin"   ]] || dd if=/dev/zero bs=1048576 count=1024 of="${testfiles}/test-1g.bin"   status=none
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

    msg_ok "Network diagnostics installed at https://${domain}/${panel_path}/diag (panel login required)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM TUNING (BBR + kernel params)
# ─────────────────────────────────────────────────────────────────────────────
tune_system() {
    local params=(
        "net.core.default_qdisc=fq"
        "net.ipv4.tcp_congestion_control=bbr"
        "fs.file-max=2097152"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_window_scaling=1"
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
        "net.ipv4.tcp_rmem=4096 87380 16777216"
        "net.ipv4.tcp_wmem=4096 65536 16777216"
    )
    for p in "${params[@]}"; do
        grep -qxF "$p" /etc/sysctl.conf || echo "$p" >> /etc/sysctl.conf
    done
    sysctl -p
}

# ─────────────────────────────────────────────────────────────────────────────
# CRON JOBS
# ─────────────────────────────────────────────────────────────────────────────
setup_cron() {
    # A dedicated file is idempotent and never rewrites the administrator's
    # root crontab. Certbot decides whether a certificate is due for renewal.
    cat > /etc/cron.d/3x-ui-pro <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 3,15 * * * root certbot renew --quiet --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
EOF
    chmod 644 /etc/cron.d/3x-ui-pro
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
setup_firewall() {
    local ssh_port="22"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port=${SSH_CONNECTION##* }
    fi
    [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=22
    ufw allow "${ssh_port}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw --force enable
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW RESULTS
# ─────────────────────────────────────────────────────────────────────────────
show_results() {
    clear
    if systemctl is-active --quiet x-ui; then
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
        echo -e "Username:  ${config_username}\n"
        echo -e "Password:  ${config_password}\n"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Network Diagnostics (panel login required): https://${domain}/${panel_path}/diag\n"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Please save this screen!"
    else
        nginx -t
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_err "x-ui or nginx check failed. Try on a clean Linux install."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    validate_domains
    verify_local_assets
    install_packages
    get_server_ip
    install_panel
    get_ssl_certs

    configure_nginx
    configure_xui_db
    install_clash_sub
    install_fake_site
    install_diagnostics
    tune_system
    setup_cron
    setup_firewall

    if ! systemctl is-enabled --quiet x-ui; then
        systemctl daemon-reload && systemctl enable x-ui.service
    fi
    x-ui restart

    show_results
}

main
