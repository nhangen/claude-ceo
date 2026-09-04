#!/bin/bash
# ceo-analytics.sh — Weekly Search Console fix list, ordered by product revenue.
#
# Traffic is the revenue lever on this stack: payment happens off-site through a
# Zoho/Stripe link, so no GA4 purchase event exists and per-query attribution is
# not computable. What *is* actionable is the top of the funnel, which is what
# Search Console measures. So this reports traffic and orders it by the revenue
# rank of the page it points at — it never claims a query earned a dollar.
#
# Deliberately absent, and each absence is load-bearing:
#   - No WooCommerce /orders read. That endpoint returns customer names, emails
#     and street addresses, and this writes into a Syncthing-synced vault.
#   - No revenue figure of its own. norx-operations owns that number, reconciled
#     across Woo/Zoho/Stripe/Mercury; a second source of truth would contradict
#     it weekly.
#   - No alerts/ state file and no inbox line. Those come after a threshold has
#     proven it fires rarely (ceo-automated-writers-are-playbooks).
#
# Invoked by ceo-cron.sh when the analytics playbook (runner:script) fires.

set -euo pipefail

# BASH_SOURCE, not $0: tests source this file to reach _gsc_parse_body
# directly, and $0 under `source` is the caller's path, not this file's.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=ceo-config.sh
source "$SCRIPT_DIR/ceo-config.sh"

ceo_load_config || { echo "ERROR: CEO config not found" >&2; exit 1; }
ceo_pin_home_or_warn || true
ceo_augment_path

VAULT="$CEO_VAULT"
CEO_DIR="$VAULT/CEO"
REPORT_DIR="$CEO_DIR/reports/analytics"
TODAY="${CEO_ANALYTICS_TODAY:-$(date +%Y-%m-%d)}"
REPORT_FILE="$REPORT_DIR/$TODAY.md"

# Site list is config, not code: this playbook is not NRX-specific. The money
# site is weighted by product revenue; the others are reported unweighted.
SITES="${CEO_ANALYTICS_SITES:-https://norxpeptides.com/,https://deconpinn.com/}"
MONEY_SITE="${CEO_ANALYTICS_MONEY_SITE:-https://norxpeptides.com/}"

# url<TAB>revenue_rank, lowest rank = best seller. Written by whatever owns the
# ledger (today: by hand from norx-operations' aggregate product totals). Its
# absence is reported in full rather than silently degrading to an
# impressions ordering — an unranked list looks identical to a ranked one.
RANK_FILE="${CEO_ANALYTICS_RANK_FILE:-$REPORT_DIR/product-revenue.tsv}"

# Search Console reports on a 2-3 day lag, so "this week" ends 3 days back.
# Comparing a fresh window against a settled one manufactures a decline.
LAG_DAYS="${CEO_ANALYTICS_LAG_DAYS:-3}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Global, and the trap reads it defensively. An EXIT trap runs after the
# function that declared its variables has returned, so a `local tmp` here made
# the cleanup dereference an out-of-scope name under `set -u` — every otherwise
# successful run exited 1, which ceo-cron records as a failed playbook.
_WORKDIR=""
trap 'rm -rf "${_WORKDIR:-}"' EXIT

# --- date helpers -------------------------------------------------------------
# BSD and GNU date disagree on relative-date syntax and neither errors on the
# other's flags in a way worth guessing at, so pick by probing.
_days_ago() {
  local n="$1"
  if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"${n}"d +%Y-%m-%d
  else
    date -d "$n days ago" +%Y-%m-%d
  fi
}

# --- auth ---------------------------------------------------------------------
# Three separate secrets, three separate exposures: the private key never
# touches a temp file (piped to openssl on a process-substitution fd below),
# the signed assertion and the bearer token never appear in curl's argv
# (stdin/`--config`, not `-d`/`-H`, since argv is readable via `ps` by any
# process on the box), and no response body is logged. See no-secrets-in-logs.
_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

_access_token() {
  local keyfile="${GA_SERVICE_ACCOUNT_JSON:-}"
  : "${keyfile:?GA_SERVICE_ACCOUNT_JSON not set; see docs/playbooks/analytics.md}"
  [ -f "$keyfile" ] || { echo "ERROR: service account key not found: $keyfile" >&2; return 1; }

  local iss now exp header claims unsigned sig assertion resp token
  iss=$(jq -r '.client_email' "$keyfile")
  now=$(date +%s); exp=$((now + 3600))
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)
  claims=$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/webmasters.readonly","aud":"https://oauth2.googleapis.com/token","exp":%s,"iat":%s}' \
    "$iss" "$exp" "$now" | _b64url)
  unsigned="$header.$claims"

  # The PEM goes to openssl on a fd, never a temp file another process could read.
  sig=$(printf '%s' "$unsigned" \
    | openssl dgst -sha256 -sign <(jq -r '.private_key' "$keyfile") \
    | _b64url)
  assertion="$unsigned.$sig"

  # The assertion (a signed JWT) goes to curl via `--data-urlencode assertion@-`
  # on stdin, not as `assertion=$assertion` on argv — argv is readable by any
  # process on the box via `ps`, and that was the actual exposure here, not
  # the key file (see the comment above `_b64url`). Because the assertion
  # arrives on stdin, `resp` (no `2>&1`) is the response body alone — it
  # cannot echo the assertion back, so withholding it hid the one thing that
  # distinguishes a revoked key from clock skew from a malformed key file:
  # Google's `error_description` (e.g. "Invalid JWT Signature").
  resp=$(printf '%s' "$assertion" | curl -sS --fail-with-body -X POST https://oauth2.googleapis.com/token \
    -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
    --data-urlencode assertion@-) || {
    local tokerr
    tokerr=$(printf '%s' "$resp" | jq -r '.error_description // .error // empty' 2>/dev/null)
    echo "ERROR: token request failed: ${tokerr:-no error detail in response}" >&2
    return 1
  }
  token=$(printf '%s' "$resp" | jq -r '.access_token // empty')
  [ -n "$token" ] || { echo "ERROR: no access_token in token response" >&2; return 1; }
  printf '%s' "$token"
}

# --- data seam ----------------------------------------------------------------
# _gsc_query <site> <start> <end> <dimension> -> TSV: key clicks impressions ctr position
#
# CEO_ANALYTICS_FIXTURE_DIR replaces the network call with recorded responses.
# The seam is here rather than around the whole report so the ranking, delta and
# rendering logic under test is the same code that runs in production
# (test-the-fix-not-the-investigation).
_gsc_query() {
  local site="$1" start="$2" end="$3" dim="$4"
  local body resp

  if [ -n "${CEO_ANALYTICS_FIXTURE_DIR:-}" ]; then
    local slug
    slug=$(printf '%s' "$site" | tr -cd 'a-zA-Z0-9')
    local f="$CEO_ANALYTICS_FIXTURE_DIR/$slug-$start-$dim.tsv"
    [ -f "$f" ] && cat "$f"
    return 0
  fi

  body=$(jq -nc --arg s "$start" --arg e "$end" --arg d "$dim" \
    '{startDate:$s,endDate:$e,dimensions:[$d],rowLimit:250}')
  # The bearer token goes in via `--config <(...)`, not `-H` on argv: a
  # `-H "Authorization: Bearer $TOKEN"` argument is readable by any process on
  # the box via `ps`, and process substitution hands curl a fd path instead
  # (`/dev/fd/N`), which carries no secret itself. A Google OAuth bearer token
  # is base64url (alnum, -, _, .) and never contains `"` or `\`, but the
  # escape guards the config-file syntax anyway rather than assuming that holds.
  local cfg_token
  cfg_token=$(printf '%s' "$ACCESS_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')
  resp=$(curl -sS --fail-with-body -X POST \
    "https://searchconsole.googleapis.com/webmasters/v3/sites/$(_urlencode "$site")/searchAnalytics/query" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$cfg_token")) \
    || { echo "ERROR: Search Console query failed for $site ($dim): $resp" >&2; return 1; }

  _gsc_parse_body "$resp" "$site" "$dim"
}

_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# _gsc_parse_body <json> <site> <dim> -> TSV rows, or a failure to stderr.
# A 200 response can still carry a Search Console error payload
# ({"error":{"code":403,...}}); `.rows[]?` on that emits nothing and returns
# 0, so the report silently printed "- none" for a query that actually
# failed. `.rows: []` is a legitimate empty week and must still succeed.
_gsc_parse_body() {
  local resp="$1" site="$2" dim="$3" err
  err=$(printf '%s' "$resp" | jq -r '.error.message? // empty' 2>/dev/null)
  if [ -n "$err" ]; then
    echo "ERROR: Search Console returned an error for $site ($dim): $err" >&2
    return 1
  fi
  printf '%s' "$resp" | jq -e 'has("rows")' >/dev/null 2>&1 || {
    echo "ERROR: Search Console response for $site ($dim) has no rows field" >&2
    return 1
  }
  printf '%s' "$resp" | jq -r '.rows[]? | [.keys[0], .clicks, .impressions, .ctr, .position] | @tsv'
}

# _valid_rows <file> -> the file's rows that are exactly 5 tab-separated fields
# with numeric metrics, in order. `IFS=$'\t' read` collapses *consecutive* tabs
# because tab is IFS whitespace, so a row with a null metric
# ("page\t\t500\t0.01\t7") silently shifts every later field left and every
# consumer misreads impressions as clicks. awk -F'\t' does not collapse, so a
# short or malformed row is rejected outright here instead of half-read by
# each of the four consumers individually. Blank lines (an empty fixture) are
# not malformed and are dropped without counting against the reject total.
_valid_rows() {
  local file="$1"
  awk -F'\t' -v f="$file" '
    NF == 0 { next }
    NF != 5 { bad++; next }
    $2 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    $3 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    $4 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    $5 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    { print }
    END { if (bad > 0) printf "WARN: rejected %d malformed row(s) in %s\n", bad, f > "/dev/stderr" }
  ' "$file"
}

# --- ranking ------------------------------------------------------------------
# Rank of the page a finding points at. 0 = unranked (never sold, or no rank
# file, or present but not in it). Lower is better, so unranked sorts last via
# the 9999 substitution. A rank file that HAS an entry for this url but a
# garbage rank column is a distinct, third case: not "unranked", a data
# problem, and it must fail rather than return 0 and look unranked.
_rank_of() {
  local url="$1" val
  [ -f "$RANK_FILE" ] || { printf '0'; return 0; }
  val=$(awk -F'\t' -v u="$url" '$1==u {print $2; found=1; exit} END{if(!found) print 0}' "$RANK_FILE") || {
    echo "ERROR: failed to read revenue rank file $RANK_FILE" >&2
    return 1
  }
  case "$val" in
    ''|*[!0-9]*)
      echo "ERROR: non-numeric revenue rank '$val' for $url in $RANK_FILE" >&2
      return 1
      ;;
  esac
  printf '%s' "$val"
}

_sort_key() { local r="$1"; [ "$r" = "0" ] && printf '9999' || printf '%s' "$r"; }

# --- findings -----------------------------------------------------------------
# _clicks_lost <cur.tsv> <prior.tsv> [weighted=1] -> rank_key url cur_clicks prior_clicks delta
# Emits only real declines. A page absent from the prior window is new, not
# down, so it is skipped rather than counted as a fall from zero.
#
# `weighted` gates the _rank_of call rather than leaving it unconditional: a
# non-money site's disclosure says "findings are unweighted", but a page URL
# on that site could still coincidentally match an entry in the (money-site)
# rank file, and an unconditional call would print a revenue rank the
# disclosure right above it just said didn't apply.
_clicks_lost() {
  local cur="$1" prior="$2" weighted="${3:-1}" url c p d rk
  while IFS=$'\t' read -r url c _ _ _; do
    [ -n "$url" ] || continue
    p=$(_valid_rows "$prior" | awk -F'\t' -v u="$url" '$1==u {print $2; exit}')
    [ -n "$p" ] || continue
    d=$(awk -v a="$c" -v b="$p" 'BEGIN{printf "%.0f", a-b}')
    [ "$d" -lt 0 ] || continue
    if [ "$weighted" = 1 ]; then
      rk=$(_rank_of "$url") || return 1
    else
      rk=0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(_sort_key "$rk")" "$url" "$c" "$p" "$d"
  done < <(_valid_rows "$cur") | sort -t$'\t' -k1,1n -k5,5n
}

# Position 5-20 with impressions and a weak click rate: the title/meta tag list.
# Above 5 there is little headroom; past 20 nobody scrolls that far.
_ctr_opportunities() {
  local cur="$1" q c i ctr pos
  while IFS=$'\t' read -r q c i ctr pos; do
    [ -n "$q" ] || continue
    awk -v p="$pos" -v i="$i" -v ctr="$ctr" \
      'BEGIN{exit !(p>=5 && p<=20 && i>=100 && ctr<0.02)}' || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$q" "$c" "$ctr" "$pos"
  done < <(_valid_rows "$cur") | sort -t$'\t' -k1,1nr
}

# Impressions but no clicks at all — a listing people see and refuse.
# `weighted` gates _rank_of for the same reason it does in _clicks_lost above.
_zero_click_pages() {
  local cur="$1" weighted="${2:-1}" url c i rk
  while IFS=$'\t' read -r url c i _ _; do
    [ -n "$url" ] || continue
    [ "${c%%.*}" -eq 0 ] 2>/dev/null || continue
    awk -v i="$i" 'BEGIN{exit !(i>=50)}' || continue
    if [ "$weighted" = 1 ]; then
      rk=$(_rank_of "$url") || return 1
    else
      rk=0
    fi
    printf '%s\t%s\t%s\n' "$(_sort_key "$rk")" "$url" "$i"
  done < <(_valid_rows "$cur") | sort -t$'\t' -k1,1n -k3,3nr
}

_new_queries() {
  local cur="$1" prior="$2" q i
  while IFS=$'\t' read -r q _ i _ _; do
    [ -n "$q" ] || continue
    # Exact field match, matching _clicks_lost's idiom above. `grep -qF` is
    # unanchored, so a new query that is a SUFFIX of last week's query read as
    # returning and was dropped: "alpha peptide" vanished because "buy alpha
    # peptide" ranked last week. That is the ordinary shape of query data.
    _valid_rows "$prior" | awk -F'\t' -v q="$q" '$1==q {found=1; exit} END{exit !found}' && continue
    printf '%s\t%s\n' "$i" "$q"
  done < <(_valid_rows "$cur") | sort -t$'\t' -k1,1nr | head -10
}

# --- report -------------------------------------------------------------------
# Each finder's output is captured into a variable and its exit status is
# checked explicitly, rather than consumed with `while ... done < <(finder)`.
# A process-substitution consumer never sees the substituted command's exit
# status — bash simply discards it — so a finder that fails partway (e.g.
# _rank_of hitting a malformed rank file) used to have its own internal
# `set -e`/pipefail failure swallowed here, and the report printed whatever
# partial output had already been produced as if it were complete.
_render_site() {
  local site="$1" pc="$2" pp="$3" qc="$4" qp="$5"
  local weighted=0 n out
  [ "$site" = "$MONEY_SITE" ] && weighted=1

  printf '## %s\n\n' "$site"
  if [ "$weighted" = 1 ] && [ ! -f "$RANK_FILE" ]; then
    printf 'Findings are **unranked** — no product-revenue file at `%s`, so this is ordered by traffic, not dollars.\n\n' \
      "${RANK_FILE/#$VAULT\//}"
  elif [ "$weighted" = 0 ]; then
    printf 'No commerce on this site; findings are unweighted.\n\n'
  fi

  printf '### Pages losing clicks\n\n'
  n=0
  out=$(_clicks_lost "$pc" "$pp" "$weighted") || { echo "ERROR: clicks-lost findings failed for $site" >&2; return 1; }
  if [ -n "$out" ]; then
    while IFS=$'\t' read -r rk url c p d; do
      n=$((n + 1))
      printf -- '- %s — %s clicks (was %s, %s)%s\n' "$url" "$c" "$p" "$d" \
        "$([ "$rk" != 9999 ] && printf ' — revenue rank %s' "$rk")"
    done <<< "$out"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'

  printf '### Title/meta opportunities (position 5-20, weak click rate)\n\n'
  n=0
  out=$(_ctr_opportunities "$qc") || { echo "ERROR: CTR-opportunity findings failed for $site" >&2; return 1; }
  if [ -n "$out" ]; then
    while IFS=$'\t' read -r i q c ctr pos; do
      n=$((n + 1))
      printf -- '- `%s` — position %.1f, %s impressions, %s clicks, CTR %.2f%%\n' \
        "$q" "$pos" "$i" "$c" "$(awk -v c="$ctr" 'BEGIN{print c*100}')"
    done <<< "$out"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'

  printf '### Pages with impressions and zero clicks\n\n'
  n=0
  out=$(_zero_click_pages "$pc" "$weighted") || { echo "ERROR: zero-click findings failed for $site" >&2; return 1; }
  if [ -n "$out" ]; then
    while IFS=$'\t' read -r rk url i; do
      n=$((n + 1))
      printf -- '- %s — %s impressions, 0 clicks%s\n' "$url" "$i" \
        "$([ "$rk" != 9999 ] && printf ' — revenue rank %s' "$rk")"
    done <<< "$out"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'

  printf '### New queries this week, by impressions\n\n'
  n=0
  out=$(_new_queries "$qc" "$qp") || { echo "ERROR: new-query findings failed for $site" >&2; return 1; }
  if [ -n "$out" ]; then
    while IFS=$'\t' read -r i q; do
      n=$((n + 1))
      printf -- '- `%s` — %s impressions\n' "$q" "$i"
    done <<< "$out"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'
}

main() {
  local cur_end cur_start prior_end prior_start
  cur_end=$(_days_ago "$LAG_DAYS")
  cur_start=$(_days_ago $((LAG_DAYS + 6)))
  prior_end=$(_days_ago $((LAG_DAYS + 7)))
  prior_start=$(_days_ago $((LAG_DAYS + 13)))

  ACCESS_TOKEN=""
  if [ -z "${CEO_ANALYTICS_FIXTURE_DIR:-}" ]; then
    ACCESS_TOKEN=$(_access_token) || return 1
  fi

  _WORKDIR=$(mktemp -d)
  local tmp="$_WORKDIR"

  {
    printf -- '---\ndate: %s\ntype: report\ntags: [analytics, search-console]\nsource: ceo-analytics\n---\n\n' "$TODAY"
    printf '# Search Console — week of %s\n\n' "$cur_start"
    printf 'This week %s → %s, compared against %s → %s. Search Console lags ~%s days.\n\n' \
      "$cur_start" "$cur_end" "$prior_start" "$prior_end" "$LAG_DAYS"
    printf 'Traffic only. No revenue figure is computed here and no query is credited with a sale — payment happens off-site, so that attribution does not exist. Findings on the money site are ordered by the revenue rank of the page they point at.\n\n'

    local site slug
    while IFS=',' read -r -d, site || [ -n "$site" ]; do
      site="${site#"${site%%[![:space:]]*}"}"; site="${site%"${site##*[![:space:]]}"}"
      [ -n "$site" ] || continue
      slug=$(printf '%s' "$site" | tr -cd 'a-zA-Z0-9')
      _gsc_query "$site" "$cur_start"   "$cur_end"   page  > "$tmp/$slug-pc.tsv"
      _gsc_query "$site" "$prior_start" "$prior_end" page  > "$tmp/$slug-pp.tsv"
      _gsc_query "$site" "$cur_start"   "$cur_end"   query > "$tmp/$slug-qc.tsv"
      _gsc_query "$site" "$prior_start" "$prior_end" query > "$tmp/$slug-qp.tsv"
      _render_site "$site" \
        "$tmp/$slug-pc.tsv" "$tmp/$slug-pp.tsv" "$tmp/$slug-qc.tsv" "$tmp/$slug-qp.tsv"
    done < <(printf '%s,' "$SITES")
  } > "$tmp/report.md"

  if [ "$DRY_RUN" = 1 ]; then
    cat "$tmp/report.md"
    printf '\n(dry run — not written to %s)\n' "${REPORT_FILE/#$VAULT\//}" >&2
    return 0
  fi

  mkdir -p "$REPORT_DIR"
  mv "$tmp/report.md" "$REPORT_FILE"
  printf 'ok %s\n' "${REPORT_FILE/#$VAULT\//}"
}

# Tests source this file to reach internal functions (_gsc_parse_body,
# _gsc_query) directly; only run the report when actually executed.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
