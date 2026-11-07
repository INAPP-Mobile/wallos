# Wallos on Railway — wrapper around the pinned upstream image.
#
# Why a wrapper at all (house style: bake constants, keep the deploy
# form zero-field, and survive Railway's root-owned volumes):
# - PORT: upstream nginx listens on a hardcoded :80 in BOTH
#   /etc/nginx/nginx.conf and /etc/nginx/http.d/default.conf (verified
#   in ellite/Wallos v5.10.4). Railway injects PORT at runtime, so
#   entrypoint.sh rewrites both listen lines to $PORT on every boot,
#   before handing off to the upstream startup.sh. The rewrite runs
#   first, so startup.sh's own IPv6 sed (which only matches ":80")
#   becomes a harmless no-op instead of clobbering the port.
#   IPv6-disabled kernels get an IPv4-only listen line, mirroring
#   the upstream guard.
# - USER root: the stock image already runs as root
#   (php:8.3-fpm-alpine, no USER directive) and startup.sh does
#   groupmod/usermod + chown, so the root-owned Railway volume is
#   writable with no change. The wrapper states USER root explicitly
#   so a future upstream non-root switch cannot silently break it.
# - DATA: Railway allows one volume per service, but Wallos persists
#   TWO directories: /var/www/html/db (SQLite) and
#   /var/www/html/images/uploads/logos (custom logos). Both live
#   under the single volume at /data (/data/db, /data/logos) and are
#   symlinked back into the webroot before startup.sh runs. The
#   volume dirs are chowned to www-data (uid 82, the upstream
#   default PUID) so php-fpm can write; startup.sh's later
#   chown -R /var/www/html does not follow the symlinks, so the
#   ownership survives, and its chmod -R on db/ (trailing slash)
#   dereferences harmlessly.
# - FIRST RUN: the database is created by upstream
#   createdatabase.php on first boot (through the symlink, so it
#   lands on the volume); the first account is created in the web
#   UI and becomes the admin. No email step, no seeded password.
# - TZ: baked to UTC; override as a service variable after deploy
#   if you want container-local time in another zone. Wallos also
#   has a per-user timezone setting in its admin UI.
# - No Docker HEALTHCHECK: rely on Railway's external
#   healthcheckPath (/health.php). The Alpine base ships curl, but
#   the in-image HEALTHCHECK is dropped in favour of the platform
#   probe, per house style.
#
# Upstream: Wallos v5.10.4 (GPL-3.0), image pinned by manifest
# digest, verified 2026-11-07 via the Docker Hub API
# (multi-arch manifest-list digest below). NOTE: the FROM uses the
# digest WITHOUT a tag — Railpack 0.43.0 fails to detect a Dockerfile
# whose FROM carries both a tag and a digest (redeploys die in the
# plan phase with "could not determine how to build"); the
# digest-only form builds under both the Dockerfile builder and
# Railpack (verified 2026-11-05 — TimeTagger's digest-only FROM is
# the precedent).

# bellamy/wallos:5.10.4
FROM bellamy/wallos@sha256:78b73a32ae24bcca67d6f4b96ca76fe29ee8da5e8df1769df1e612a4e776c904

USER root

COPY entrypoint.sh /railway-entrypoint.sh
RUN chmod +x /railway-entrypoint.sh

# Baked constants (see header): container timezone; the data dirs
# are symlinked onto the /data volume by the entrypoint.
ENV TZ=UTC

# Documentation only: Railway routes to $PORT at runtime (see
# entrypoint.sh); 80 is the upstream default the image would use
# without the wrapper's nginx remap.
EXPOSE 80

CMD ["/railway-entrypoint.sh"]
