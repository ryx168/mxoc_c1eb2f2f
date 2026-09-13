#!/bin/bash
# Restore the OpenCart 1.5.4 app + DB from R2 and write runner configs.
# OpenCart 1.5.4 uses ext/mysql (DB_DRIVER=mysql) -> requires PHP 5.6, and a
# MySQL 5.7 service (native_password) that the old client can authenticate to.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}/webroot"
rm -rf "$ROOT"; mkdir -p "$ROOT"; cd "$ROOT"
CF="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets/${STATE_BUCKET}/objects"

echo "::group::Restore state from R2"
curl -sSf -H "Authorization: Bearer ${CF_API_TOKEN}" "$CF/app.tar.gz" -o app.tar.gz
tar xzf app.tar.gz && rm -f app.tar.gz
curl -sSf -H "Authorization: Bearer ${CF_API_TOKEN}" "$CF/db-latest.sql.gz" -o db.sql.gz
echo "  app + db restored; top: $(ls | tr '\n' ' ')"
echo "::endgroup::"

echo "::group::Database"
for i in $(seq 1 45); do
  mysql -h127.0.0.1 -uroot -proot -e "SELECT 1" >/dev/null 2>&1 && break
  echo "  waiting for mysql ($i)"; sleep 2
done
mysql -h127.0.0.1 -uroot -proot -e "CREATE DATABASE IF NOT EXISTS ${DB_DATABASE} CHARACTER SET utf8 COLLATE utf8_general_ci;"
zcat db.sql.gz | mysql -h127.0.0.1 -uroot -proot "${DB_DATABASE}" && echo "  imported db"
rm -f db.sql.gz
echo "  products: $(mysql -h127.0.0.1 -uroot -proot -N -e "SELECT COUNT(*) FROM ${DB_DATABASE}.${DB_PREFIX}product" 2>/dev/null)"
echo "::endgroup::"

echo "::group::Write configs"
EH="${EDIT_HOST}"
common_dirs() {
cat <<EOF
define('DIR_SYSTEM', '$ROOT/system/');
define('DIR_DATABASE', '$ROOT/system/database/');
define('DIR_CONFIG', '$ROOT/system/config/');
define('DIR_IMAGE', '$ROOT/image/');
define('DIR_CACHE', '$ROOT/system/cache/');
define('DIR_DOWNLOAD', '$ROOT/download/');
define('DIR_LOGS', '$ROOT/system/logs/');
define('DB_DRIVER', 'mysql');
define('DB_HOSTNAME', '127.0.0.1');
define('DB_USERNAME', 'root');
define('DB_PASSWORD', 'root');
define('DB_DATABASE', '${DB_DATABASE}');
define('DB_PREFIX', '${DB_PREFIX}');
EOF
}
cat > config.php <<EOF
<?php
define('HTTP_SERVER', 'https://$EH/');
define('HTTPS_SERVER', 'https://$EH/');
define('DIR_APPLICATION', '$ROOT/catalog/');
define('DIR_LANGUAGE', '$ROOT/catalog/language/');
define('DIR_TEMPLATE', '$ROOT/catalog/view/theme/');
$(common_dirs)
EOF
AD="${ADMIN_DIR:-admin566}"
cat > "$AD/config.php" <<EOF
<?php
define('HTTP_SERVER', 'https://$EH/$AD/');
define('HTTPS_SERVER', 'https://$EH/$AD/');
define('HTTP_CATALOG', 'https://$EH/');
define('HTTPS_CATALOG', 'https://$EH/');
define('HTTP_IMAGE', 'https://$EH/image/');
define('HTTPS_IMAGE', 'https://$EH/image/');
define('DIR_APPLICATION', '$ROOT/$AD/');
define('DIR_LANGUAGE', '$ROOT/$AD/language/');
define('DIR_TEMPLATE', '$ROOT/$AD/view/template/');
define('DIR_CATALOG', '$ROOT/catalog/');
$(common_dirs)
EOF
mkdir -p system/cache system/logs download image
chmod -R 777 system/cache system/logs download image 2>/dev/null || true
echo "  wrote config.php + $AD/config.php"
echo "::endgroup::"

# Router for php -S: serve real static files directly; route the rest to the right
# index.php ($AD for the admin, front otherwise). php -S has no .htaccess. SSL is
# terminated at the tunnel, so present the request to OpenCart as HTTPS or the admin
# bounces login <-> home forever.
cat > router.php <<PHP
<?php
\$_SERVER['HTTPS'] = 'on';
\$_SERVER['SERVER_PORT'] = 443;
\$path = parse_url(\$_SERVER['REQUEST_URI'], PHP_URL_PATH);
\$file = __DIR__ . \$path;
if (\$path !== '/' && is_file(\$file) && substr(\$path, -4) !== '.php') { return false; }
if (preg_match('#^/$AD(/|\$)#', \$path)) {
    chdir(__DIR__ . '/$AD');
    \$_SERVER['SCRIPT_NAME'] = '/$AD/index.php';
    require __DIR__ . '/$AD/index.php';
    return true;
}
chdir(__DIR__);
\$_SERVER['SCRIPT_NAME'] = '/index.php';
require __DIR__ . '/index.php';
return true;
PHP
echo "BOOT_OK ROOT=$ROOT ADMIN=$AD"
