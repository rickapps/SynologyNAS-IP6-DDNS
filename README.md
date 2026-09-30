# SynologyNAS-IP6-DDNS

A small, dependency-free bash script that keeps a dynamic-DNS provider's
AAAA record pointed at a Synology NAS's own public IPv6 address, run from
DSM's built-in Task Scheduler.

## Why this exists

Synology DSM's built-in DDNS client can keep third-party providers (Dynu,
No-IP, etc.) updated for IPv4, but not for IPv6. If you plug that gap with
something running on another machine on your network, it publishes *that
machine's* address, not the NAS's. This script runs on the NAS itself
instead, so the address it publishes is always the NAS's own.

## How it works

- Looks up the NAS's own public IPv6 address from an external echo service
  (`api6.ipify.org`) instead of parsing local interfaces — this sidesteps
  having to pick the right address out of several local candidates
  (link-local, privacy/temporary SLAAC addresses, Docker bridge addresses,
  etc.).
- Compares it to the last address it successfully published (cached in
  `.last_ipv6` next to the script) and exits immediately if nothing
  changed.
- If it changed, builds an update URL from a template in your config file
  and sends it as a GET request, then checks the response text against a
  success pattern you define in the same file.
- Has no provider-specific code — it works with any provider that exposes
  a "DynDNS2-style" update API (a GET request that returns a short text
  response like `good`/`nochg`/`OK`). Dynu, DuckDNS, No-IP, FreeDNS, and
  others all fit this shape; only the URL template and success pattern
  change per provider.
- Uses a lock file so overlapping scheduled runs can't race each other,
  and passes the built URL to curl via a temporary config file (not a
  command-line argument), so credentials don't show up in `ps` output.
- Only marks an address as "published" after the provider's response
  actually confirms success, so a failed update gets retried on the next
  run instead of being silently skipped.

## Setup

1. Copy `update-ddns.sh` and the example config for your provider to a
   shared folder on the NAS, e.g. `/volume1/scripts/ddns/`. A shared
   folder survives DSM updates; the system partition does not.
2. Copy the matching example to `ddns.conf` in that same folder, fill in
   your real credentials, and lock it down:
   ```
   cp ddns.conf.example ddns.conf      # Dynu
   # or: cp examples/duckdns.conf.example ddns.conf
   # or: cp examples/noip.conf.example ddns.conf
   chmod 600 ddns.conf
   ```
3. In DSM, open **Task Scheduler → Create → Scheduled Task → User-defined
   script**, and set the run command to:
   ```
   /volume1/scripts/ddns/update-ddns.sh /volume1/scripts/ddns/ddns.conf
   ```
   Run it as a user with read/write access to that folder. Every 10–15
   minutes is a reasonable interval.
4. In the task's notification settings, consider enabling "Send run
   details by email only when the script terminates abnormally" — the
   script exits non-zero on any failure, so DSM will flag it for you.
5. Do one manual test run and confirm the AAAA record updates correctly
   (and, if your provider's template only touches IPv6, that it doesn't
   disturb the existing A/IPv4 record).

## Config file format

| Variable | Meaning |
|---|---|
| `DDNS_URL_TEMPLATE` | The update URL, with placeholders substituted before the request is sent. |
| `DDNS_SUCCESS_PATTERN` | An extended regex matched against the provider's response body; a match means success. |
| `DDNS_USERNAME`, `DDNS_PASSWORD`, `DDNS_TOKEN`, `DDNS_HOSTNAME`, `DDNS_GROUP` | Whichever of these your provider's template needs — leave the rest unset. |

Placeholders available in `DDNS_URL_TEMPLATE`: `%USERNAME%`, `%PASSWORD%`,
`%TOKEN%`, `%HOSTNAME%`, `%GROUP%`, and `%IP%` (the detected IPv6 address).
All values are URL-encoded automatically before substitution, so
credentials with special characters are safe to use as-is.

## Providers

- **Dynu** — [`ddns.conf.example`](ddns.conf.example). Confirmed working
  in production.
- **DuckDNS**, **No-IP** — [`examples/`](examples/). These show the
  template syntax but haven't been verified against a live account; check
  the provider's current API docs (parameter names and IPv6 support vary)
  before relying on them.

Adding another provider that follows the same GET-and-text-response
pattern just means writing a new config file — no code changes needed.

## Scope

This script only publishes IPv6 (AAAA) records — it exists specifically
to fill the gap DSM leaves for third-party IPv6 DDNS updates. It doesn't
manage IPv4/A records.

## License

GPLv3 — see [LICENSE](LICENSE).
