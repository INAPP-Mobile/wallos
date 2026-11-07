#!/bin/sh
# Wallos Railway wrapper entrypoint (Alpine /bin/sh; the upstream
# image is php:8.3-fpm-alpine with nginx, php-fpm and dcron).
#
# What it does, in order:
# - PORT: Railway injects PORT at runtime. Upstream nginx listens on
#   a hardcoded :80 in /etc/nginx/nginx.conf and
#   /etc/nginx/http.d/default.conf (verified in ellite/Wallos
#   v5.10.4). Rewrite both listen lines to $PORT on every boot.
#   IPv6-disabled kernels get an IPv4-only listen line, mirroring
#   the upstream guard in startup.sh (which then becomes a no-op:
#   its own sed only matches ":80"). Fail loud if the remap did
#   not land — a server listening on the wrong port is a silent
#   dead deploy.
# - DATA: one Railway volume at /data holds both persistent dirs:
#   /data/db (SQLite) and /data/logos (custom subscription logos).
#   Symlink them back into the webroot, preserving any files the
#   image already ships in those dirs (db/wallos.empty.db) by
#   copying them onto the volume first, only when the volume side
#   is empty. Chown the volume dirs to www-data (uid 82, the
#   upstream default PUID) so php-fpm can write.
# - STEADY STATE: exec the upstream startup.sh, exactly as the
#   image does (it creates/migrates the database, runs the daily
#   cronjobs once, then waits on php-fpm + nginx + crond). The
#   image ENTRYPOINT (dumb-init) stays in front for signal
#   handling.

set -e

PORT_VALUE="${PORT:-80}"
NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_DEFAULT="/etc/nginx/http.d/default.conf"

# --- PORT remap -------------------------------------------------------
if [ -e /proc/net/if_inet6 ]; then
  LISTEN_REPLACEMENT="listen [::]:${PORT_VALUE} ipv6only=off;"
else
  echo "Wallos: IPv6 not available, configuring nginx to listen on IPv4 only"
  LISTEN_REPLACEMENT="listen ${PORT_VALUE};"
fi

for conf in "$NGINX_CONF" "$NGINX_DEFAULT"; do
  if [ -f "$conf" ]; then
    # The listen lines carry variable whitespace; -E with a class
    # matches them all. The ${PORT_VALUE} expansion is inserted
    # literally and never re-expanded.
    sed -E -i "s/listen[[:space:]]+\[::\]:80 ipv6only=off;/${LISTEN_REPLACEMENT}/" "$conf"
  fi
done

if ! grep -q "listen.*${PORT_VALUE}" "$NGINX_CONF"; then
  echo "Wallos: ERROR nginx port remap failed in $NGINX_CONF; refusing to start."
  exit 1
fi

# --- Volume symlinks --------------------------------------------------
DATA_DIR="/data"
WEBROOT="/var/www/html"

mkdir -p "$DATA_DIR/db" "$DATA_DIR/logos"

# Move a directory's shipped contents onto the volume (first boot
# only — the volume side must be empty), then replace the webroot
# dir with a symlink to the volume dir.
link_dir() {
  src="$1"   # webroot dir, e.g. /var/www/html/db
  dest="$2"  # volume dir, e.g. /data/db
  if [ -L "$src" ]; then
    return 0
  fi
  if [ -d "$src" ]; then
    # Copy shipped files only when the volume side is empty, so a
    # redeploy never overwrites live data.
    if [ -z "$(ls -A "$dest" 2>/dev/null)" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
      cp -a "$src/." "$dest/"
    fi
    rm -rf "$src"
  fi
  mkdir -p "$(dirname "$src")"
  ln -s "$dest" "$src"
}

link_dir "$WEBROOT/db" "$DATA_DIR/db"
link_dir "$WEBROOT/images/uploads/logos" "$DATA_DIR/logos"

# php-fpm runs as www-data (uid 82 by default); the volume must be
# writable by it. startup.sh's later chown -R /var/www/html does
# not follow symlinks, so this ownership survives.
chown -R www-data:www-data "$DATA_DIR"

if [ ! -w "$DATA_DIR/db" ] || [ ! -w "$DATA_DIR/logos" ]; then
  echo "Wallos: ERROR $DATA_DIR is not writable for www-data; refusing to start."
  exit 1
fi

echo "Wallos: nginx on :${PORT_VALUE}, data on $DATA_DIR (volume)"
exec /var/www/html/startup.sh
