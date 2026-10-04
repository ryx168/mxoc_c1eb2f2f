#!/bin/bash
# Persist the session's changes back to R2: the database (product/text edits) and
# the app tree (admin image uploads). Then re-crawl the front-end and republish the
# static public site to Cloudflare Pages so edits actually show. A crawl/publish
# failure must NOT lose the DB/app backup, so the backup happens first and the
# republish is fully guarded (and never overwrites the live site with too few pages).
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}/webroot"
CF="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets"
put() { curl -sSf -m 600 -X PUT -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: $2" --data-binary @"$1" "$3" -o /dev/null; }

echo "::group::Persist DB + app to R2 (${STATE_BUCKET})"
mysqldump -h127.0.0.1 -uroot -proot "${DB_DATABASE}" 2>/dev/null | gzip > /tmp/db.sql.gz
put /tmp/db.sql.gz application/gzip "$CF/${STATE_BUCKET}/objects/db-latest.sql.gz" && echo "  saved db-latest.sql.gz ($(du -h /tmp/db.sql.gz|cut -f1))"
# history copy
put /tmp/db.sql.gz application/gzip "$CF/${STATE_BUCKET}/objects/history/db-$(date +%Y%m%d-%H%M%S).sql.gz" || true
tar czf /tmp/app.tar.gz --warning=no-file-changed --exclude='./system/cache/*' --exclude='./system/logs/*' --exclude='./config.php' --exclude='./admin*/config.php' . || true
put /tmp/app.tar.gz application/gzip "$CF/${STATE_BUCKET}/objects/app.tar.gz" && echo "  saved app.tar.gz ($(du -h /tmp/app.tar.gz|cut -f1))"
echo "::endgroup::"

if [ "${SKIP_REPUBLISH:-false}" = "true" ]; then echo "SKIP_REPUBLISH set - not republishing"; exit 0; fi

echo "::group::Re-crawl front-end + republish static"
CRAWL="http://127.0.0.1:8080"
# OpenCart builds every link from HTTP_SERVER/HTTPS_SERVER in config.php. During a
# session those point at EDIT_HOST so the admin works behind the tunnel - but then
# the front-end links are all absolute to EDIT_HOST and wget (same-host only) follows
# NONE of them, so the crawl saw just the 1 home page. For the crawl, repoint both to
# the local server so links are same-host and the whole catalog is followed.
# config.php is ephemeral (rewritten every boot by oc-boot.sh, and excluded from
# app.tar.gz above), so mutating it here never affects saved state.
sed -i "s#define('HTTP_SERVER'.*#define('HTTP_SERVER', '$CRAWL/');#; s#define('HTTPS_SERVER'.*#define('HTTPS_SERVER', '$CRAWL/');#" config.php

# The session's php -S (if any) may linger past a cancel; take the port cleanly.
pkill -f "php -.*-S 127.0.0.1:8080" 2>/dev/null || true
sleep 1
php -d error_reporting=0 -d display_errors=0 -S 127.0.0.1:8080 router.php >/tmp/php_save.log 2>&1 &
sleep 3
home_code=$(curl -s -o /tmp/home.html -w "%{http_code}" "$CRAWL/")
echo "  front home -> $home_code"
if [ "$home_code" != "200" ]; then
  echo "  front-end not healthy ($home_code) - keeping the existing published site. DB/app are saved."
  tail -5 /tmp/php_save.log 2>/dev/null
  exit 0
fi

OUT=/tmp/ocexport; rm -rf "$OUT"; mkdir -p "$OUT"
# Mirror the whole linked front-end. Query-URL stores (SEO off) become
# index.php%3Froute=...html files; SEO stores become keyword .html files - both
# match how the live mirror was originally built (it keeps the account/checkout
# shells too). Reject only the sort/pagination permutations that would explode the
# crawl without adding real pages.
wget --mirror --page-requisites --adjust-extension --convert-links --no-verbose \
     --execute robots=off --tries=2 --timeout=25 \
     --reject-regex '(sort=|order=|[?&]limit=|[?&]page=)' \
     --directory-prefix "$OUT" --no-host-directories \
     "$CRAWL/" 2>&1 | tail -3 || true

# Query-URL stores: wget saves files with a literal '?' and single-encoded '%2F',
# but its own --convert-links hrefs point at the fully-encoded '%3F'/'%252F' form -
# and Cloudflare Pages serves the query mirror directly only when the on-disk name
# IS that encoded form (otherwise it 308-redirects). Rename files to match the hrefs
# (encode '%'->'%25' first, then '?'->'%3F'); SEO '.html' files have no '?' and are
# left untouched. This reproduces the original live mirror's naming exactly.
( cd "$OUT" && find . -depth -name '*[?]*' | while IFS= read -r f; do
    d=$(dirname "$f"); b=$(basename "$f")
    nb=$(printf '%s' "$b" | sed 's/%/%25/g; s/?/%3F/g')
    [ "$b" != "$nb" ] && mv -f "$f" "$d/$nb"
  done )

pages=$(find "$OUT" -name "*.html" | wc -l)
echo "  crawled pages: $pages"
MIN_PAGES="${MIN_PAGES:-5}"
if [ "$pages" -lt "$MIN_PAGES" ]; then
  echo "  too few pages ($pages < $MIN_PAGES) - NOT republishing (safety guard); DB/app saved."
  exit 0
fi

BR="${PUBLISH_BRANCH:-main}"   # main = production (live custom domain); any other = a preview deploy
echo "  deploying $pages pages to Pages project '${PAGES_PROJECT}' (branch: $BR)"
npm i -g wrangler@4.120.1 >/tmp/wr-install.log 2>&1 || sudo npm i -g wrangler@4.120.1 >/tmp/wr-install.log 2>&1 || { echo "  wrangler install failed:"; tail -5 /tmp/wr-install.log; }
if CLOUDFLARE_API_TOKEN="$CF_API_TOKEN" CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID" \
   wrangler pages deploy "$OUT" --project-name "${PAGES_PROJECT}" --branch "$BR" --commit-dirty=true >/tmp/pdeploy.log 2>&1; then
  echo "  republished OK ($pages pages -> $PAGES_PROJECT, branch $BR)"
  grep -oE 'https://[a-z0-9-]+\.pages\.dev' /tmp/pdeploy.log | tail -1 | sed 's/^/  url: /'
else
  echo "  republish deploy FAILED (DB + app are still safely saved):"; tail -20 /tmp/pdeploy.log
fi
echo "::endgroup::"
