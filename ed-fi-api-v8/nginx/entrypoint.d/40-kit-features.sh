#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Kit start-up hook for the official nginx image. /docker-entrypoint.sh runs the files
# in /docker-entrypoint.d/ in `sort -V` order, so this runs after
# 20-envsubst-on-templates.sh has rendered /etc/nginx/templates into /etc/nginx/conf.d.
# A *.sh hook runs as a child process, so nothing exported here reaches later hooks or
# nginx; instead this script writes finished config files with the values filled in.
# A non-zero exit stops the container before nginx starts.

set -eu

ME=$(basename "$0")
CONF_DIR=/etc/nginx/conf.d
KIT_DIR="$CONF_DIR/kit"
HTTP_RATE_LIMIT_CONF="$CONF_DIR/kit-rate-limit.conf"
PROXY_SNIPPET="$CONF_DIR/snippets/kit-proxy.conf"
LOG_DIR=/var/log/nginx/kit
SSL_DIR=/ssl

log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$ME: $*"
    fi
}

fail() {
    echo "$ME: ERROR: $*" >&2
    exit 1
}

# matches VALUE EXTENDED_REGEX
matches() {
    printf '%s\n' "$1" | grep -Eq "$2"
}

# bool NAME VALUE -> prints true or false (case-insensitive), or fails
bool() {
    value=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        true | false) printf '%s' "$value" ;;
        *) fail "$1 must be 'true' or 'false' (got '$2'). Fix it in .env and start again." ;;
    esac
}

# --- Settings and defaults ----------------------------------------------------------

DMS_PATH_BASE=${DMS_PATH_BASE:-api}
DATA_V3_REWRITE_ENABLED=$(bool DATA_V3_REWRITE_ENABLED "${DATA_V3_REWRITE_ENABLED:-true}")
RATE_LIMIT_ENABLED=$(bool RATE_LIMIT_ENABLED "${RATE_LIMIT_ENABLED:-false}")
RATE_LIMIT_RATE=${RATE_LIMIT_RATE:-50r/s}
RATE_LIMIT_BURST=${RATE_LIMIT_BURST:-100}
CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-100m}
PROXY_CONNECT_TIMEOUT=${PROXY_CONNECT_TIMEOUT:-5s}
PROXY_SEND_TIMEOUT=${PROXY_SEND_TIMEOUT:-300s}
PROXY_READ_TIMEOUT=${PROXY_READ_TIMEOUT:-300s}

# --- Validation ---------------------------------------------------------------------

for name in DMS_PATH_BASE CMS_PATH_BASE; do
    eval "value=\${$name:-}"
    if [ -n "$value" ] && ! matches "$value" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        fail "$name must be a single path segment such as 'api' (got '$value')."
    fi
done

matches "$RATE_LIMIT_RATE" '^[1-9][0-9]*r/[sm]$' ||
    fail "RATE_LIMIT_RATE must look like '50r/s' or '600r/m' (got '$RATE_LIMIT_RATE')."
matches "$RATE_LIMIT_BURST" '^[0-9]+$' ||
    fail "RATE_LIMIT_BURST must be a whole number such as 100, or 0 for no burst (got '$RATE_LIMIT_BURST')."
matches "$CLIENT_MAX_BODY_SIZE" '^[0-9]+[kKmMgG]?$' ||
    fail "CLIENT_MAX_BODY_SIZE must be an nginx size such as 100m (got '$CLIENT_MAX_BODY_SIZE')."
for name in PROXY_CONNECT_TIMEOUT PROXY_SEND_TIMEOUT PROXY_READ_TIMEOUT; do
    eval "value=\$$name"
    matches "$value" '^[1-9][0-9]*(ms|s|m|h)?$' ||
        fail "$name must be an nginx time such as 300s or 5m (got '$value')."
done

[ -f "$CONF_DIR/default.conf" ] ||
    fail "$CONF_DIR/default.conf is missing. Mount the kit's nginx/templates at /etc/nginx/templates."

# The template step silently leaves ${NAME} in place when NAME is not set.
# shellcheck disable=SC2016 # a literal ${NAME} is the pattern
unrendered=$(grep -ho '\${[A-Za-z_][A-Za-z0-9_]*}' "$CONF_DIR/default.conf" "$PROXY_SNIPPET" \
    2>/dev/null | sort -u | tr '\n' ' ' || true)
if [ -n "$unrendered" ]; then
    fail "nginx templates still contain ${unrendered}- set these in the nginx service's" \
        "environment in compose.yml."
fi

for file in server.crt server.key; do
    [ -r "$SSL_DIR/$file" ] ||
        fail "TLS file $SSL_DIR/$file not found. From the ed-fi-api-v8 directory run" \
            "./ssl/generate-certificate.sh (or ./ssl/generate-certificate.ps1), then start again."
done

# --- Write the feature files ---------------------------------------------------------

mkdir -p "$KIT_DIR" "$LOG_DIR"
# The container file system survives a restart, so clear files from an earlier start.
rm -f "$KIT_DIR"/*.conf "$HTTP_RATE_LIMIT_CONF"

cat > "$KIT_DIR/00-limits.conf" <<EOF
# Written by $ME
client_max_body_size $CLIENT_MAX_BODY_SIZE;
proxy_connect_timeout $PROXY_CONNECT_TIMEOUT;
proxy_send_timeout $PROXY_SEND_TIMEOUT;
proxy_read_timeout $PROXY_READ_TIMEOUT;
EOF

if [ "$DATA_V3_REWRITE_ENABLED" = true ]; then
    cat > "$KIT_DIR/10-data-v3.conf" <<EOF
# Written by $ME (DATA_V3_REWRITE_ENABLED=true)
# Legacy ODS/API path: /data/v3/<rest> -> /$DMS_PATH_BASE/data/<rest>. The query string is kept.
location /data/v3/ {
    set \$kit_service dms;
    set \$kit_upstream dms:8080;
    set \$kit_data_v3_rewrite true;
    rewrite ^/data/v3/(.*)\$ /$DMS_PATH_BASE/data/\$1 break;
    include $PROXY_SNIPPET;
}
EOF
else
    cat > "$KIT_DIR/10-data-v3.conf" <<EOF
# Written by $ME (DATA_V3_REWRITE_ENABLED=false)
location /data/v3 {
    default_type application/problem+json;
    return 404 '{
  "type": "urn:ed-fi:kit:data-v3-rewrite-disabled",
  "title": "Not Found",
  "status": 404,
  "detail": "The /data/v3 compatibility rewrite is disabled (DATA_V3_REWRITE_ENABLED=false).",
  "hint": "Use the native Ed-Fi API v8 path /$DMS_PATH_BASE/data/..."
}
';
}
EOF
fi

if [ "$RATE_LIMIT_ENABLED" = true ]; then
    # limit_req_zone is only valid at http level, so it goes into conf.d/ itself.
    # Only DMS routes (including /data/v3) are limited; an empty key is not counted.
    cat > "$HTTP_RATE_LIMIT_CONF" <<EOF
# Written by $ME (RATE_LIMIT_ENABLED=true)
map \$kit_service \$kit_rate_limit_key {
    dms     \$binary_remote_addr;
    default "";
}
limit_req_zone \$kit_rate_limit_key zone=kit_rate_limit:10m rate=$RATE_LIMIT_RATE;
limit_req_status 429;
limit_req_log_level warn;
EOF
    # nginx rejects burst=0, so a burst of 0 means "no burst parameter".
    burst=""
    if [ "$RATE_LIMIT_BURST" -gt 0 ]; then
        burst=" burst=$RATE_LIMIT_BURST nodelay"
    fi
    cat > "$KIT_DIR/20-rate-limit.conf" <<EOF
# Written by $ME (RATE_LIMIT_ENABLED=true)
limit_req zone=kit_rate_limit$burst;
EOF
fi

log "data_v3_rewrite=$DATA_V3_REWRITE_ENABLED rate_limit=$RATE_LIMIT_ENABLED" \
    "(rate=$RATE_LIMIT_RATE burst=$RATE_LIMIT_BURST) client_max_body_size=$CLIENT_MAX_BODY_SIZE" \
    "proxy_read_timeout=$PROXY_READ_TIMEOUT"
