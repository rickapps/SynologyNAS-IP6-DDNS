#!/bin/bash
#
# update-ddns.sh — update a dynamic-DNS provider's AAAA record with this
# host's current public IPv6 address, but only when it has changed since
# the last successful update.
#
# Intended to run on a Synology NAS itself (via DSM Task Scheduler), since
# DSM's own DDNS client can update third-party providers' IPv4 records but
# not their IPv6 ones.
#
# Works with any provider that exposes a "DynDNS2-style" update API: a
# single GET request that returns a short text response such as
# good/nochg/badauth/OK. The request URL and what counts as success are
# both defined in the config file — this script has no provider-specific
# code in it.
#
# Usage:
#   update-ddns.sh /path/to/provider.conf
#
# See ddns.conf.example (Dynu) and examples/ (other providers) for the
# config file format.

set -uo pipefail

CONFIG_FILE="${1:-}"
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Usage: $0 /path/to/provider.conf" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${DDNS_URL_TEMPLATE:?DDNS_URL_TEMPLATE not set in $CONFIG_FILE}"
: "${DDNS_SUCCESS_PATTERN:?DDNS_SUCCESS_PATTERN not set in $CONFIG_FILE}"

DDNS_USERNAME="${DDNS_USERNAME:-}"
DDNS_PASSWORD="${DDNS_PASSWORD:-}"
DDNS_TOKEN="${DDNS_TOKEN:-}"
DDNS_HOSTNAME="${DDNS_HOSTNAME:-}"
DDNS_GROUP="${DDNS_GROUP:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.last_ipv6"
LOCK_FILE="$SCRIPT_DIR/.update-ddns.lock"
LOG_FILE="$SCRIPT_DIR/update-ddns.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# URL-encode a value using curl itself, so this doesn't depend on
# python/perl/jq being present on the NAS.
urlencode() {
    local encoded
    encoded="$(curl -Gso /dev/null -w '%{url_effective}' --data-urlencode "x=$1" "http://x/")"
    printf '%s' "${encoded#*\?x=}"
}

# Prevent overlapping runs (e.g. a hung previous run) from racing each other.
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: another instance is already running"
    exit 1
fi

# Ask an external echo service what our IPv6 address looks like from the
# outside, rather than parsing local interfaces. That avoids having to pick
# the right address out of several local candidates (link-local,
# privacy/temporary SLAAC addresses, Docker bridge addresses, etc.) — it's
# simply the address the world sees us as.
CURRENT_IP="$(curl -6 -fsS --max-time 10 https://api6.ipify.org)"
if [ -z "$CURRENT_IP" ] || [[ "$CURRENT_IP" != *:* ]]; then
    log "ERROR: could not determine current IPv6 address (no IPv6 connectivity, or api6.ipify.org unreachable/returned unexpected data: '$CURRENT_IP')"
    exit 1
fi

LAST_IP=""
[ -f "$STATE_FILE" ] && LAST_IP="$(cat "$STATE_FILE")"

if [ "$CURRENT_IP" = "$LAST_IP" ]; then
    # No change - nothing to do.
    exit 0
fi

UPDATE_URL="$DDNS_URL_TEMPLATE"
UPDATE_URL="${UPDATE_URL//%USERNAME%/$(urlencode "$DDNS_USERNAME")}"
UPDATE_URL="${UPDATE_URL//%PASSWORD%/$(urlencode "$DDNS_PASSWORD")}"
UPDATE_URL="${UPDATE_URL//%TOKEN%/$(urlencode "$DDNS_TOKEN")}"
UPDATE_URL="${UPDATE_URL//%HOSTNAME%/$(urlencode "$DDNS_HOSTNAME")}"
UPDATE_URL="${UPDATE_URL//%GROUP%/$(urlencode "$DDNS_GROUP")}"
UPDATE_URL="${UPDATE_URL//%IP%/$(urlencode "$CURRENT_IP")}"

# Pass the URL to curl via a temporary config file rather than a
# command-line argument, so credentials embedded in it don't show up in
# `ps` output while curl is running.
CURL_CONF="$(mktemp)"
chmod 600 "$CURL_CONF"
trap 'rm -f "$CURL_CONF"' EXIT
printf 'url = "%s"\n' "$UPDATE_URL" > "$CURL_CONF"

RESPONSE="$(curl -fsS --max-time 15 -K "$CURL_CONF")"
CURL_STATUS=$?

if [ $CURL_STATUS -ne 0 ]; then
    log "ERROR: curl failed contacting DDNS provider (exit code $CURL_STATUS)"
    exit 1
fi

log "Provider response for $CURRENT_IP: $RESPONSE"

if [[ "$RESPONSE" =~ $DDNS_SUCCESS_PATTERN ]]; then
    # Only remember this IP as "done" once the provider has confirmed it.
    echo "$CURRENT_IP" > "$STATE_FILE"
    exit 0
else
    log "ERROR: provider rejected update: $RESPONSE"
    exit 1
fi
