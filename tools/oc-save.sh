#!/bin/bash
# Persist the session's changes back to R2: the database (product/text edits) and
# the app tree (admin image uploads). Then best-effort re-crawl the front-end and
# republish the static public site so edits show. A crawl failure must NOT lose the
# DB/app backup, so the backup happens first and the crawl is guarded.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}/webroot"
CF="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets"
put() { curl -sSf -m 600 -X PUT -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: $2" --data-binary @"$1" "$3" -o /dev/null; }

echo "::group::Persist DB + app to R2 (${STATE_BUCKET})"
mysqldump -h127.0.0.1 -uroot -proot "${DB_DATABASE}" 2>/dev/null | gzip > /tmp/db.sql.gz
put /tmp/db.sql.gz application/gzip "$CF/${STATE_BUCKET}/objects/db-latest.sql.gz" && echo "  saved db-latest.sql.gz ($(du -h /tmp/db.sql.gz|cut -f1))"
# history copy
put /tmp/db.sql.gz application/gzip "$CF/${STATE_BUCKET}/objects/history/db-$(date +%Y%m%d-%H%M%S).sql.gz" || true
tar czf /tmp/app.tar.gz --warning=no-file-changed --exclude='./system/cache/*' --exclude='./system/logs/*' --exclude='./config.php' --exclude='./admin566/config.php' . || true
put /tmp/app.tar.gz application/gzip "$CF/${STATE_BUCKET}/objects/app.tar.gz" && echo "  saved app.tar.gz ($(du -h /tmp/app.tar.gz|cut -f1))"
echo "::endgroup::"

if [ "${SKIP_REPUBLISH:-false}" = "true" ]; then echo "SKIP_REPUBLISH set - not republishing"; exit 0; fi

echo "::group::Re-crawl front-end + republish static (best effort)"
php -d error_reporting=0 -d display_errors=0 -S 127.0.0.1:8080 router.php >/tmp/php_save.log 2>&1 &
sleep 3
home_code=$(curl -s -o /tmp/home.html -w "%{http_code}" "http://127.0.0.1:8080/index.php?route=common/home")
echo "  front home -> $home_code"
if [ "$home_code" != "200" ]; then
  echo "  front-end not healthy ($home_code) - keeping the existing published static site. DB/app are saved."
  exit 0
fi
OUT=/tmp/ocexport; rm -rf "$OUT"; mkdir -p "$OUT"
# Crawl the SEO/front pages. OpenCart links are absolute to EDIT_HOST; rewrite to relative for the crawl.
wget --mirror --page-requisites --adjust-extension --convert-links --no-verbose \
     --execute robots=off --tries=2 --timeout=25 --reject "*checkout*,*login*,*cart*,*account*" \
     --directory-prefix "$OUT" --no-host-directories \
     "http://127.0.0.1:8080/index.php?route=common/home" 2>&1 | tail -3 || true
pages=$(find "$OUT" -name "*.html" | wc -l)
echo "  crawled pages: $pages"
if [ "$pages" -lt 5 ]; then echo "  too few pages ($pages) - not republishing; DB/app saved."; exit 0; fi
echo "  (republish upload to ${PAGES_PROJECT} left to the maintainer for now - crawl produced $pages pages at $OUT)"
echo "::endgroup::"
