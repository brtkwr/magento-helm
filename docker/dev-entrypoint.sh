#!/usr/bin/env bash
# First-boot installer for the local dev stack.
#
# The published magento image ships code and vendor only - the shop itself is
# installed at runtime, exactly as the Helm chart does it. The setup:install
# flags below mirror charts/magento/templates/configmap.yaml; change them
# together or local dev stops resembling what we deploy.
set -euo pipefail

DB_HOST=${MYSQL_HOST:-db}
DB_NAME=${MYSQL_DATABASE:-magento}
DB_USER=${MYSQL_USER:-magento}
DB_PASSWORD=${MYSQL_PASSWORD:-magento}
SEARCH_HOST=${OPENSEARCH_HOST:-search}
SEARCH_PORT=${OPENSEARCH_PORT:-9200}
URL=${URL:-http://localhost/}
ADMIN_USER=${ADMIN_USER:-exampleuser}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-examplepassword123}
ADMIN_EMAIL=${ADMIN_EMAIL:-exampleuser@two.inc}
WAIT_TIMEOUT=${INSTALL_WAIT_TIMEOUT:-300}

# The Makefile waits on this file rather than on `bin/magento --version`, which
# answers long before the shop is usable.
READY=/var/www/html/var/.dev-install-complete

cd /var/www/html

log() { echo "dev-entrypoint: $*"; }

wait_for() {
  local what=$1 elapsed=0
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
      log "timed out after ${WAIT_TIMEOUT}s waiting for ${what}" >&2
      exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  log "${what} is up"
}

if [ ! -f "$READY" ]; then
  log "no completed install found, bootstrapping"
  # Probe with PDO, the driver Magento actually uses. The Debian mysql client
  # requires TLS by default and a stock mariadb container does not offer it, so
  # `mysqladmin ping` fails against a database Magento connects to perfectly
  # well - the probe has to speak the same protocol as the app, not a
  # lookalike.
  export DB_HOST DB_USER DB_PASSWORD
  wait_for "database ${DB_HOST}" php -r '
    new PDO(
      "mysql:host=".getenv("DB_HOST"),
      getenv("DB_USER"),
      getenv("DB_PASSWORD")
    );' 
  wait_for "opensearch ${SEARCH_HOST}:${SEARCH_PORT}" \
    curl -fsS "http://${SEARCH_HOST}:${SEARCH_PORT}"

  install_args=(
    --base-url="$URL"
    --db-host="$DB_HOST"
    --db-name="$DB_NAME"
    --db-user="$DB_USER"
    --db-password="$DB_PASSWORD"
    --admin-firstname='Example'
    --admin-lastname='User'
    --admin-email="$ADMIN_EMAIL"
    --admin-user="$ADMIN_USER"
    --admin-password="$ADMIN_PASSWORD"
    --language='en_US'
    --currency='USD'
    --timezone='UTC'
    --use-rewrites='1'
    --backend-frontname='admin'
    --search-engine='opensearch'
    --opensearch-host="$SEARCH_HOST"
    --opensearch-port="$SEARCH_PORT"
    --no-interaction
  )

  # setup:install rejects a non-https --base-url-secure outright, so the
  # secure pair only makes sense when the dev URL is itself https (a tunnel or
  # a proxy). Plain http://localhost gets the secure flags off instead.
  case "$URL" in
    https://*) install_args+=(--base-url-secure="$URL" --use-secure='1' --use-secure-admin='1') ;;
    *)         install_args+=(--use-secure='0' --use-secure-admin='0') ;;
  esac

  php bin/magento setup:install "${install_args[@]}"

  # 2FA locks you out of a throwaway local admin for no benefit. The chart
  # disables these on both install paths for the same reason.
  php bin/magento module:disable \
    Magento_AdminAdobeImsTwoFactorAuth Magento_TwoFactorAuth || true

  # Magento's 90-day default password lifetime counts from the sample-data
  # fixture date, so a fresh container's admin is born expired.
  php bin/magento config:set admin/security/password_lifetime 0 || true

  touch "$READY"
  log "install complete"
else
  log "existing install found, skipping bootstrap"
fi

# setup:install runs as root here, so hand the writable trees back to Apache
# before it starts serving.
chown -R www-data:www-data var generated pub/static pub/media app/etc

exec "$@"
