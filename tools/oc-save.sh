#!/bin/bash
# Persist the session's changes back to R2 (DB + app), then refresh the public
# static site so admin edits show.
#
# IMPORTANT architecture note: the public site is NOT a Pages asset deployment -
# it is the 2022 wget mirror living in the R2 bucket named like PAGES_PROJECT
# (e.g. lilychan-ca / maxtec-inc-com), served by that Pages project's _worker.js
# (query-URL -> R2-key mapping). So republish = re-render each page that already
# exists in that bucket and overwrite the SAME key. We never invent keys and never
# touch the Pages/worker deployment, so the worker's mapping can't break. (A brand
# new product would need a new key + the page relinked - not handled here; edits to
# existing products/pages are, which is the whole point.)
#
# A crawl/publish problem must never lose the DB/app backup, so the backup is first
# and the refresh is fully guarded.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}/webroot"
CFOBJ="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/r2/buckets"
put() { curl -sSf -m 600 -X PUT -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: $2" --data-binary @"$1" "$3" -o /dev/null; }

echo "::group::Persist DB + app to R2 (${STATE_BUCKET})"
mysqldump -h127.0.0.1 -uroot -proot "${DB_DATABASE}" 2>/dev/null | gzip > /tmp/db.sql.gz
put /tmp/db.sql.gz application/gzip "$CFOBJ/${STATE_BUCKET}/objects/db-latest.sql.gz" && echo "  saved db-latest.sql.gz ($(du -h /tmp/db.sql.gz|cut -f1))"
put /tmp/db.sql.gz application/gzip "$CFOBJ/${STATE_BUCKET}/objects/history/db-$(date +%Y%m%d-%H%M%S).sql.gz" || true
tar czf /tmp/app.tar.gz --warning=no-file-changed --exclude='./system/cache/*' --exclude='./system/logs/*' --exclude='./config.php' --exclude='./admin*/config.php' . || true
put /tmp/app.tar.gz application/gzip "$CFOBJ/${STATE_BUCKET}/objects/app.tar.gz" && echo "  saved app.tar.gz ($(du -h /tmp/app.tar.gz|cut -f1))"
echo "::endgroup::"

if [ "${SKIP_REPUBLISH:-false}" = "true" ]; then echo "SKIP_REPUBLISH set - not republishing"; exit 0; fi

echo "::group::Refresh public static pages in R2"
CONTENT_BUCKET="${CONTENT_BUCKET:-$PAGES_PROJECT}"
CRAWL="http://127.0.0.1:8080"
# OpenCart builds links/base from HTTP_SERVER/HTTPS_SERVER; during a session they
# point at EDIT_HOST. Repoint to the local server so the pages render with the same
# base the mirror expects (config.php is ephemeral - rewritten each boot, excluded
# from app.tar.gz above - so this never affects saved state).
sed -i "s#define('HTTP_SERVER'.*#define('HTTP_SERVER', '$CRAWL/');#; s#define('HTTPS_SERVER'.*#define('HTTPS_SERVER', '$CRAWL/');#" config.php
pkill -f "php -.*-S 127.0.0.1:8080" 2>/dev/null || true
sleep 1
php -d error_reporting=0 -d display_errors=0 -S 127.0.0.1:8080 router.php >/tmp/php_save.log 2>&1 &
sleep 3
home_code=$(curl -s -o /tmp/home_fp.html -w "%{http_code}" "$CRAWL/")
echo "  front home -> $home_code ($(wc -c </tmp/home_fp.html) bytes)"
if [ "$home_code" != "200" ] || [ "$(wc -c </tmp/home_fp.html)" -lt 500 ]; then
  echo "  front-end not healthy - keeping the existing published site. DB/app are saved."
  tail -5 /tmp/php_save.log 2>/dev/null
  exit 0
fi

if [ "${REPUBLISH_MODE:-refresh}" = "full" ]; then
  # FULL re-crawl: wget-mirror the live front-end (internally-consistent links,
  # correct UTF-8 filenames on this UTF-8 runner) and upload EVERY file to the R2
  # content bucket under the worker's key scheme (relpath, '?'->'%3F'). Additive -
  # never deletes existing keys. Use this to repair an incomplete/mojibake mirror
  # (e.g. maxtec's missing deep-catalog pages).
  OUT=/tmp/ocmirror; rm -rf "$OUT"; mkdir -p "$OUT"
  echo "  full crawl (wget --mirror) ..."
  wget --mirror --page-requisites --adjust-extension --convert-links --no-verbose \
       --execute robots=off --tries=2 --timeout=25 \
       --reject-regex '(sort=|order=|[?&]limit=|[?&]page=|route=checkout|route=account|route=product/compare)' \
       --directory-prefix "$OUT" --no-host-directories "$CRAWL/" 2>/tmp/wget.log || true
  echo "  files crawled: $(find "$OUT" -type f | wc -l)  ($(find "$OUT" -name '*.html' | wc -l) html)"
  CF_API_TOKEN="$CF_API_TOKEN" CONTENT_BUCKET="$CONTENT_BUCKET" CF_ACCOUNT_ID="$CF_ACCOUNT_ID" \
  OUT="$OUT" DRY_RUN="${DRY_RUN:-false}" python3 - <<'PYF'
import os,sys,urllib.request,urllib.parse,unicodedata,mimetypes,concurrent.futures as cf
TOK=os.environ["CF_API_TOKEN"];ACC=os.environ["CF_ACCOUNT_ID"];BUCK=os.environ["CONTENT_BUCKET"]
OUT=os.environ["OUT"];DRY=os.environ.get("DRY_RUN")=="true"
API="https://api.cloudflare.com/client/v4/accounts/%s/r2/buckets/%s/objects"%(ACC,BUCK)
def key_of(rel):
    # wget saved '?' literally and '/' in query as %2F; the worker/key scheme uses
    # '?'->'%3F' and keeps '/' (real dir sep) and '%2F'. Just encode the '?'.
    k=rel.replace("?","%3F")
    return unicodedata.normalize("NFC",k)
def put(rel):
    full=os.path.join(OUT,rel)
    with open(full,"rb") as f: body=f.read()
    if len(body)==0: return "empty"
    k=key_of(rel)
    ct=mimetypes.guess_type(k)[0] or "application/octet-stream"
    if k.endswith(".html"): ct="text/html; charset=utf-8"
    if DRY: return "would"
    u=API+"/"+urllib.parse.quote(k,safe="")
    r=urllib.request.Request(u,data=body,method="PUT",headers={"Authorization":"Bearer "+TOK,"Content-Type":ct})
    try:
        urllib.request.urlopen(r,timeout=120); return "put"
    except Exception as e:
        return "fail"
rels=[]
for root,_,files in os.walk(OUT):
    for fn in files:
        rels.append(os.path.relpath(os.path.join(root,fn),OUT).replace(os.sep,"/"))
print("  uploading %d files%s ..."%(len(rels)," (DRY)" if DRY else ""))
from collections import Counter
c=Counter()
with cf.ThreadPoolExecutor(max_workers=8) as ex:
    for r in ex.map(put,rels): c[r]+=1
print("  upload: put=%d would=%d empty=%d fail=%d"%(c["put"],c["would"],c["empty"],c["fail"]))
PYF
  echo "::endgroup::"
  echo "republish(full) done for ${CONTENT_BUCKET}"
  exit 0
fi

CF_API_TOKEN="$CF_API_TOKEN" CONTENT_BUCKET="$CONTENT_BUCKET" CF_ACCOUNT_ID="$CF_ACCOUNT_ID" \
CRAWL="$CRAWL" DRY_RUN="${DRY_RUN:-false}" MAX_KEYS="${MAX_KEYS:-0}" python3 - <<'PY'
import os, sys, json, hashlib, urllib.request, urllib.parse, concurrent.futures as cf

TOK   = os.environ["CF_API_TOKEN"]
ACC   = os.environ["CF_ACCOUNT_ID"]
BUCK  = os.environ["CONTENT_BUCKET"]
CRAWL = os.environ["CRAWL"]
DRY   = os.environ.get("DRY_RUN","false") == "true"
MAXK  = int(os.environ.get("MAX_KEYS","0") or 0)
API   = "https://api.cloudflare.com/client/v4/accounts/%s/r2/buckets/%s/objects" % (ACC, BUCK)

import re
def title_of(b):
    m = re.search(br"<title>(.*?)</title>", b, re.I|re.S)
    return (m.group(1).decode("utf-8","replace").strip() if m else "")[:60]

with open("/tmp/home_fp.html","rb") as f: HOME = f.read()
HOME_MD5 = hashlib.md5(HOME).hexdigest()

def api_url(key):
    return API + "/" + urllib.parse.quote(key, safe="")

def list_keys():
    keys, cur = [], None
    while True:
        u = API + "?per_page=1000" + (("&cursor="+urllib.parse.quote(cur,safe="")) if cur else "")
        req = urllib.request.Request(u, headers={"Authorization":"Bearer "+TOK})
        d = json.load(urllib.request.urlopen(req, timeout=90))
        for o in (d.get("result") or []):
            k = o["key"]
            if k.endswith(".html"): keys.append(k)
        ri = d.get("result_info") or {}
        if ri.get("is_truncated") and ri.get("cursor"): cur = ri["cursor"]
        else: break
    return keys

HOME_KEYS = {"index.html", "index.php%3Froute=common%2Fhome.html"}
def key_to_path(k):
    if k in HOME_KEYS: return ""           # the home page
    u = k[:-5] if k.endswith(".html") else k
    for a,b in (("%3F","?"),("%3f","?"),("%2F","/"),("%2f","/")): u = u.replace(a,b)
    return u

def fetch(path):
    # keep URL structure, percent-encode unicode/space
    url = CRAWL + "/" + urllib.parse.quote(path, safe="/?&=:+,")
    req = urllib.request.Request(url, headers={"User-Agent":"oc-republish"})
    with urllib.request.urlopen(req, timeout=40) as r:
        return r.getcode(), r.read()

def put(key, body):
    req = urllib.request.Request(api_url(key), data=body, method="PUT",
            headers={"Authorization":"Bearer "+TOK, "Content-Type":"text/html; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.getcode()

# not-found fingerprint: ask OpenCart for a route that cannot exist
try:
    _, nfb = fetch("index.php?route=zz_nonexistent/zz_" + hashlib.md5(b"x").hexdigest())
    NF_MD5 = hashlib.md5(nfb).hexdigest(); NF_TITLE = title_of(nfb).lower()
except Exception:
    NF_MD5 = ""; NF_TITLE = "\x00"
print("  home='%s'  not_found='%s'" % (title_of(HOME), NF_TITLE))

keys = list_keys()
if MAXK: keys = keys[:MAXK]
print("  html keys in %s: %d%s" % (BUCK, len(keys), "  (DRY RUN)" if DRY else ""))

samples = []
def work(k):
    path = key_to_path(k)
    try:
        code, body = fetch(path)
    except Exception:
        return ("skip_fetch", k, 0, "")
    t = title_of(body); md5 = hashlib.md5(body).hexdigest()
    if code != 200 or len(body) < 300:
        return ("skip_fetch", k, code, t)
    if md5 == HOME_MD5 and k not in HOME_KEYS:
        return ("skip_home", k, code, t)
    if (NF_MD5 and md5 == NF_MD5) or ("not found" in t.lower()) or ("404" in t):
        return ("skip_notfound", k, code, t)
    if not DRY:
        try: put(k, body)
        except Exception: return ("put_fail", k, code, t)
    return ("updated", k, code, t)

stats = {}
with cf.ThreadPoolExecutor(max_workers=4) as ex:
    for res in ex.map(work, keys):
        st = res[0]; stats[st] = stats.get(st,0)+1
        if len(samples) < 24: samples.append(res)

print("  refreshed=%d  skip_fetch=%d  skip_home=%d  skip_notfound=%d  put_fail=%d" % (
    stats.get("updated",0), stats.get("skip_fetch",0), stats.get("skip_home",0),
    stats.get("skip_notfound",0), stats.get("put_fail",0)))
print("  --- sample (status | code | title | key) ---")
for st,k,code,t in samples:
    print("    %-13s %s | %-22s | %s" % (st, code, (t or "")[:22], k[:70]))
if keys and stats.get("updated",0) == 0:
    print("  WARNING: no pages refreshed - investigate")
PY
echo "::endgroup::"
echo "republish done for ${CONTENT_BUCKET}"
