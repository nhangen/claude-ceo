#!/bin/bash
# ceo-analytics.sh — Weekly Search Console fix list, ordered by product revenue.
#
# Traffic is the revenue lever on this stack: payment happens off-site through a
# Zoho/Stripe link, so no GA4 purchase event exists and per-query attribution is
# not computable. What *is* actionable is the top of the funnel, which is what
# Search Console measures. So this reports traffic — it never claims a query
# earned a dollar. Page-dimension findings (pages losing clicks, pages with
# impressions and zero clicks) on the money site are ordered by the revenue
# rank of the page they point at; the two query-dimension findings (title/meta
# opportunities, new queries) have no page to rank and sort by impressions.
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
    # Keyed on start AND end: keying on start+dim alone let cur_end/prior_end
    # drift to any value (even an overlapping or same-day window) and still
    # resolve to the same fixture, so the comparison window itself had no
    # test coverage — see docs/playbooks/analytics.md and LAG_DAYS above.
    local f="$CEO_ANALYTICS_FIXTURE_DIR/$slug-$start-$end-$dim.tsv"
    # A missing fixture used to yield empty output at exit 0 — indistinguishable
    # from a legitimate empty week. This is the only ingress the whole suite
    # exercises, so that swallow could green-light an assertion about "- none"
    # that a fixture typo, not a quiet week, actually produced.
    [ -f "$f" ] || { echo "ERROR: no fixture at $f" >&2; return 1; }
    cat "$f"
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
#
# The reject/good counts are also written to "$file.rejects" (bad<TAB>good),
# overwritten every call — deterministic for a given file, so the six call
# sites calling this more than once (some in a loop) never disagree. This is
# the one place that knows a row was dropped; nothing downstream re-parses the
# input, so _render_site reads this sidecar rather than each of its six
# callers threading a reject count through separately.
_valid_rows() {
  local file="$1"
  awk -F'\t' -v f="$file" '
    NF == 0 { next }
    NF != 5 { bad++; next }
    $2 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    $3 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    $4 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    $5 !~ /^-?[0-9]+(\.[0-9]+)?$/ { bad++; next }
    { good++; print }
    END {
      if (bad > 0) printf "WARN: rejected %d malformed row(s) in %s\n", bad, f > "/dev/stderr"
      printf "%d\t%d\n", bad+0, good+0 > (f ".rejects")
    }
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

# _sort_key <raw-rank> -> a key that sorts unranked (0) last. 9999 is a sort
# device only — never treated as data past this point. A page's actual rank is
# carried separately (see the finders below), because a page genuinely ranked
# 9999 is legal input and must not render as unranked just because the sort
# key for "unranked" happens to look the same.
_sort_key() { local r="$1"; [ "$r" = "0" ] && printf '9999' || printf '%s' "$r"; }

# --- findings -----------------------------------------------------------------
# _clicks_lost <cur.tsv> <prior.tsv> [weighted=1] -> sort_key url cur_clicks prior_clicks delta raw_rank
# Emits only real declines. A page absent from the prior window is new, not
# down, so it is skipped rather than counted as a fall from zero.
#
# `weighted` gates the _rank_of call rather than leaving it unconditional: a
# non-money site's disclosure says "findings are unweighted", but a page URL
# on that site could still coincidentally match an entry in the (money-site)
# rank file, and an unconditional call would print a revenue rank the
# disclosure right above it just said didn't apply.
#
# The row carries both the sort key AND the raw rank as separate trailing
# fields — never just the sort key — so a caller checking "is this unranked"
# tests the raw rank (0), not the sort key (9999), which a real rank-9999 page
# would also produce.
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(_sort_key "$rk")" "$url" "$c" "$p" "$d" "$rk"
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
# Carries sort_key AND raw_rank as separate trailing fields — see the comment
# on _clicks_lost above for why the raw rank can't be recovered from the key.
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
    printf '%s\t%s\t%s\t%s\n' "$(_sort_key "$rk")" "$url" "$i" "$rk"
  done < <(_valid_rows "$cur") | sort -t$'\t' -k1,1n -k3,3nr
}

_new_queries() {
  local cur="$1" prior="$2" q i seen
  while IFS=$'\t' read -r q _ i _ _; do
    [ -n "$q" ] || continue
    # Exact field match, matching _clicks_lost's idiom above. `grep -qF` is
    # unanchored, so a new query that is a SUFFIX of last week's query read as
    # returning and was dropped: "alpha peptide" vanished because "buy alpha
    # peptide" ranked last week. That is the ordinary shape of query data.
    #
    # The membership probe is captured and its status checked explicitly,
    # rather than `... && continue` on the pipeline: a `&&` list exempts
    # everything left of it from `set -e`, so a hard read failure in
    # `_valid_rows "$prior"` (an unreadable file, not merely a malformed row)
    # was swallowed as "not found" and every current-week query printed as new.
    #
    # The caller shape is what makes this load-bearing, and an earlier version
    # of this comment got it wrong twice over. _render_site invokes the finder
    # as `out_new=$(_new_queries ...) || { ... }`, and an assignment on the
    # LEFT of `||` suppresses errexit inside the command substitution — so
    # `set -e` is NOT active here and cannot stand in for the check. Measured
    # in that shape: with it, rc=1 and no output; without it, rc=0 and a
    # fabricated `400\talpha peptide`. Probed in any OTHER shape the two look
    # identical, which is how an arm claiming to pin this came to be deleted
    # as vacuous; it is back, and it runs the production caller shape.
    #
    # End to end this is still belt-and-braces: _render_site's reject ledger
    # re-reads all four inputs as a bare simple command and trips `set -e`
    # before the finders run. That stops being true the moment the ledger loop
    # moves below them, which is why the check stays. The unguarded twin in
    # _clicks_lost is covered by the same ledger and by its own `set -e`,
    # since it is not on the left of an `||`.
    seen=$(_valid_rows "$prior" | awk -F'\t' -v q="$q" '$1==q {found=1; exit} END{print (found?1:0)}') || return 1
    [ "$seen" = "1" ] && continue
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
#
# Findings are computed BEFORE anything is printed. `_valid_rows` (see its own
# header) leaves a `<file>.rejects` sidecar recording how much of an input it
# dropped, and this is the one place — not each of `_valid_rows`'s six call
# sites — that has to consult it: a report line reading `- none`, or a finding
# missing its revenue rank, must always reflect the data and never a discarded
# read. A dimension whose input rows were *all* rejected fails the run outright
# rather than rendering a clean week; an empty input is a legitimate quiet week
# and still succeeds.
_render_site() {
  local site="$1" pc="$2" pp="$3" qc="$4" qp="$5"
  local weighted=0 n
  [ "$site" = "$MONEY_SITE" ] && weighted=1

  local out_clicks out_ctr out_zero out_new
  out_clicks=$(_clicks_lost "$pc" "$pp" "$weighted") || { echo "ERROR: clicks-lost findings failed for $site" >&2; return 1; }
  out_ctr=$(_ctr_opportunities "$qc") || { echo "ERROR: CTR-opportunity findings failed for $site" >&2; return 1; }
  out_zero=$(_zero_click_pages "$pc" "$weighted") || { echo "ERROR: zero-click findings failed for $site" >&2; return 1; }
  out_new=$(_new_queries "$qc" "$qp") || { echo "ERROR: new-query findings failed for $site" >&2; return 1; }

  # The finders above already ran `_valid_rows` over these four files at least
  # once (idempotent — same file, same content, same counts), but not every
  # file is guaranteed to have gone through every finder (e.g. an all-rejected
  # `$pc` short-circuits `_clicks_lost`'s loop before it ever touches `$pp`).
  # Run it once more per file here so the ledger is complete regardless of
  # which finders happened to visit which input.
  local f bad good rej_total=0 rej_fatal=0 rej_prior_q=0
  for f in "$pc" "$pp" "$qc" "$qp"; do
    _valid_rows "$f" >/dev/null
    read -r bad good < "$f.rejects"
    rej_total=$((rej_total + bad))
    [ "$bad" -gt 0 ] && [ "$good" -eq 0 ] && rej_fatal=1
    # The prior query window is tracked separately because rejects there are
    # the one direction that FABRICATES rather than omits. Every other finder
    # drops a row and loses a finding; _new_queries decides "new" by absence
    # from this file, so a dropped row turns a query that ranked last week
    # into a headline. The banner below says findings may be missing, which is
    # the wrong warning for a line that is present and wrong.
    [ "$f" = "$qp" ] && rej_prior_q="$bad"
  done
  if [ "$rej_fatal" -eq 1 ]; then
    echo "ERROR: every row of an input for $site was malformed — refusing to report a clean week" >&2
    return 1
  fi
  [ "$rej_total" -gt 0 ] && _SITE_DEGRADED=1

  # The rank file is hand-maintained, so present-but-stale (a site migration,
  # a truncated edit, a wrong column order) is its likeliest failure mode, and
  # `[ ! -f "$RANK_FILE" ]` alone never catches it — every lookup then resolves
  # to the unranked sentinel and the report degrades to an impressions
  # ordering with no annotation. Judge staleness from what this run actually
  # produced: among this site's weighted findings, did ANY of them resolve to
  # a real rank? A mix of ranked and never-sold (rank 0) pages is the ordinary
  # shape of a real catalog and must not trip this; zero matches across every
  # weighted finding is the stale-file signature.
  local rank_disclose=0
  if [ "$weighted" = 1 ]; then
    if [ ! -f "$RANK_FILE" ]; then
      rank_disclose=1
    else
      # $NF, not $1: $1 is the *sort key*, which collapses "unranked" and a
      # real rank of 9999 onto the same value (see _sort_key). The raw rank
      # is always the last field regardless of which finder's row this is.
      local stale
      stale=$(printf '%s\n%s\n' "$out_clicks" "$out_zero" | awk -F'\t' '
        NF==0 { next }
        { rows++; if ($NF != 0) hit=1 }
        END { print (rows > 0 && !hit) ? 1 : 0 }
      ')
      [ "$stale" = "1" ] && rank_disclose=1
    fi
  fi

  printf '## %s\n\n' "$site"
  if [ "$rej_total" -gt 0 ]; then
    printf '%d row(s) rejected as malformed; findings below may be incomplete.\n\n' "$rej_total"
  fi
  if [ "$rank_disclose" -eq 1 ]; then
    printf 'Findings are **unranked** — no product-revenue file at `%s`, or none of its entries matched a page in this run — so this is ordered by traffic, not dollars.\n\n' \
      "${RANK_FILE/#"$VAULT"\//}"
  elif [ "$weighted" = 0 ]; then
    printf 'No commerce on this site; findings are unweighted.\n\n'
  fi

  printf '### Pages losing clicks\n\n'
  n=0
  if [ -n "$out_clicks" ]; then
    while IFS=$'\t' read -r rk url c p d rawrk; do
      n=$((n + 1))
      printf -- '- %s — %s clicks (was %s, %s)%s\n' "$url" "$c" "$p" "$d" \
        "$([ "$rawrk" != 0 ] && printf ' — revenue rank %s' "$rawrk")"
    done <<< "$out_clicks"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'

  printf '### Title/meta opportunities (position 5-20, weak click rate)\n\n'
  n=0
  if [ -n "$out_ctr" ]; then
    while IFS=$'\t' read -r i q c ctr pos; do
      n=$((n + 1))
      printf -- '- `%s` — position %.1f, %s impressions, %s clicks, CTR %.2f%%\n' \
        "$q" "$pos" "$i" "$c" "$(awk -v c="$ctr" 'BEGIN{print c*100}')"
    done <<< "$out_ctr"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'

  printf '### Pages with impressions and zero clicks\n\n'
  n=0
  if [ -n "$out_zero" ]; then
    while IFS=$'\t' read -r rk url i rawrk; do
      n=$((n + 1))
      printf -- '- %s — %s impressions, 0 clicks%s\n' "$url" "$i" \
        "$([ "$rawrk" != 0 ] && printf ' — revenue rank %s' "$rawrk")"
    done <<< "$out_zero"
  fi
  [ "$n" -eq 0 ] && printf -- '- none\n'
  printf '\n'

  printf '### New queries this week, by impressions\n\n'
  if [ "$rej_prior_q" -gt 0 ]; then
    printf -- '%d row(s) of the prior query window were malformed, so a query listed here may have ranked last week after all. Treat this section as unverified.\n\n' \
      "$rej_prior_q"
  fi
  n=0
  if [ -n "$out_new" ]; then
    while IFS=$'\t' read -r i q; do
      n=$((n + 1))
      printf -- '- `%s` — %s impressions\n' "$q" "$i"
    done <<< "$out_new"
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

  # Set by _render_site when any site's input had rejected rows. Global,
  # matching _WORKDIR above: the while loop below shares this shell (no `|`
  # after `done`, so no subshell), and this is read once, after every site
  # has rendered, to decide the run's outcome signal.
  _SITE_DEGRADED=0

  {
    printf -- '---\ndate: %s\ntype: report\ntags: [analytics, search-console]\nsource: ceo-analytics\n---\n\n' "$TODAY"
    printf '# Search Console — week of %s\n\n' "$cur_start"
    printf 'This week %s → %s, compared against %s → %s. Search Console lags ~%s days.\n\n' \
      "$cur_start" "$cur_end" "$prior_start" "$prior_end" "$LAG_DAYS"
    printf 'Traffic only. No revenue figure is computed here and no query is credited with a sale — payment happens off-site, so that attribution does not exist. Page-dimension findings on the money site are ordered by the revenue rank of the page they point at; query-dimension findings are ordered by impressions, since a query has no page to rank.\n\n'

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

  # ceo-cron.sh (:1558) exports CEO_RUNNER_OUTCOME_FILE so a script-runner
  # playbook can say more than exit-0-success. A degraded run (rows rejected,
  # disclosed in the report above but not fatal) still exits 0 — a discarded
  # read is disclosed, never promoted to a failure — but it is not a clean
  # week and somebody should look at it.
  #
  # The word is `fired`, not a new one. That channel's vocabulary is exactly
  # two values (ceo-cron.sh:262-272): `fired` notifies, `noop` stays silent,
  # and anything else falls through to the per-trigger default. An earlier
  # version wrote `degraded`, which no `case` arm matches — so the comment
  # and its test both claimed a consumer that does not exist, and the signal
  # went nowhere. `fired` is the channel's existing word for "this tick did
  # real work worth surfacing", which is exactly what a degraded run is.
  if [ "$_SITE_DEGRADED" = 1 ] && [ -n "${CEO_RUNNER_OUTCOME_FILE:-}" ]; then
    printf 'fired' > "$CEO_RUNNER_OUTCOME_FILE"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    cat "$tmp/report.md"
    printf '\n(dry run — not written to %s)\n' "${REPORT_FILE/#"$VAULT"\//}" >&2
    return 0
  fi

  mkdir -p "$REPORT_DIR"
  mv "$tmp/report.md" "$REPORT_FILE"
  printf 'ok %s\n' "${REPORT_FILE/#"$VAULT"\//}"
}

# Tests source this file to reach internal functions (_gsc_parse_body,
# _gsc_query) directly; only run the report when actually executed.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
