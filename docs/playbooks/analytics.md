---
name: analytics
description: Weekly Search Console fix list for the live sites, ordered by the revenue rank of the page each finding points at
trigger: cron
schedule: "0 8 * * 1"
preflight: none
tier: read
status: draft
runner: script
script: ceo-analytics.sh
artifact: CEO/reports/analytics/{TODAY}.md
scope: single
requires: ["GA_SERVICE_ACCOUNT_JSON"]
---

# Analytics

Shell-only playbook. The dispatcher invokes `scripts/ceo-analytics.sh` directly — no LLM call.

## What it does

Pulls Search Console for each configured site over the trailing 7 days, pulls the 7 days before that,
and writes a single report to `<VAULT>/CEO/reports/analytics/<TODAY>.md` containing four ranked lists
per site:

1. Pages losing clicks week-over-week.
2. Queries sitting at position 5–20 with ≥100 impressions and CTR under 2% — the title/meta fix list.
3. Pages with ≥50 impressions and zero clicks.
4. Queries that did not appear last week, the ten with the most impressions.

On the **money site** the two page-dimension findings — declines and zero-click pages — are ordered by
the revenue rank of the page they point at, so a small decline on a best seller outranks a large
decline on a page that has never sold. The two query-dimension findings are ordered by impressions:
a query is not a page, so there is no rank to sort it by. Other sites are
reported unweighted and labelled as such.

## Why traffic, and not revenue

Payment on this stack happens off-site: WooCommerce creates the order, Zoho emails a Stripe payment
link, the customer pays later. GA4 therefore never sees a purchase event and there is no
session-to-paid join, so per-query or per-campaign attribution does not exist. Traffic is the lever
that can actually be moved, and Search Console is where it is measured.

The report says this in its own body rather than leaving it implied, and
`test_the_report_never_claims_revenue_attribution` pins that it never prints a ROAS figure.

## What it deliberately does not do

Each of these is a decision, not an omission:

- **No WooCommerce `/orders` read.** That endpoint returns customer names, emails, phone numbers and
  street addresses, and this writes into a Syncthing-synced vault. If Woo is ever read here it is the
  aggregate `reports/` endpoints only.
- **No revenue figure of its own.** norx-operations owns that number, reconciled across
  Woo/Zoho/Stripe/Mercury. Woo alone, Zoho alone and Stripe alone all disagree; they only cohere
  through that plugin's link graph. A second source of truth would contradict it every week.
- **No `CEO/alerts/` state file and no `CEO/inbox.md` line.** Those arrive only once a threshold has
  been observed firing rarely across real weeks. Wiring an alert before that is the disk-monitor
  failure mode — 64 hours of identical hourly inbox appends with no clear-state path
  (`ceo-automated-writers-are-playbooks`).
- **No Google Ads.** Basic Access to the Ads API needs a non-test manager account holding a developer
  token plus a reviewed access application; it is not a self-serve key.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CEO_ANALYTICS_SITES` | `https://norxpeptides.com/,https://deconpinn.com/` | Comma-separated Search Console property URLs |
| `CEO_ANALYTICS_MONEY_SITE` | `https://norxpeptides.com/` | The one site whose findings are revenue-weighted |
| `CEO_ANALYTICS_RANK_FILE` | `CEO/reports/analytics/product-revenue.tsv` | `url<TAB>rank`, lowest rank = best seller |
| `CEO_ANALYTICS_LAG_DAYS` | `3` | How far back "this week" ends. GSC reports on a 2–3 day lag |
| `CEO_ANALYTICS_FIXTURE_DIR` | unset | Test-only: replaces the API call with recorded TSVs |
| `CEO_ANALYTICS_TODAY` | today | Test-only: pins the report date and filename |

The rank file is currently maintained by hand from norx-operations' aggregate product totals. **Its
absence does not fail the run** — the report says "unranked" and falls back to traffic ordering,
because an unranked list is otherwise indistinguishable from a ranked one.

## Install / credentials

One-time, and it needs a human in the Google Cloud console:

1. Create a service account; download its JSON key.
2. `mv` the key to `~/.config/ceo/ga-service-account.json` and `chmod 600` it.
3. Add `GA_SERVICE_ACCOUNT_JSON=$HOME/.config/ceo/ga-service-account.json` to
   `~/.config/ceo/credentials.env`. The variable holds a **path**, never the key material.
4. In Search Console, add the service account's `client_email` as a user on each property. Read
   permission is sufficient; the requested scope is `webmasters.readonly`.
5. `ceo creds check analytics` to confirm the variable resolves.

The script requests only `webmasters.readonly`. `norxpeptides.com` carries live Google Ads spend
(`AW-6771070082`), so nothing here is ever granted a write scope.

Verify without credentials or a network call:

```bash
CEO_ANALYTICS_FIXTURE_DIR=/path/to/fixtures scripts/ceo-analytics.sh --dry-run
```

`--dry-run` prints the report to stdout and writes nothing to the vault — it doesn't even
create the `reports/analytics/` directory.

## Scheduling

`scope: single`, so it runs on exactly one owner host and **runs nowhere until an owner is assigned**:

```bash
ceo swarm doctor            # confirm/assign the owner (ML-1)
ceo playbook scan           # ML-1 only — rewrites the host-local registry
```

`status: draft` means `ceo playbook scan` installs no schedule; run it on demand with
`ceo-cron.sh analytics` for a few weeks first. Promote to `active` once the output has proven useful
and the thresholds have proven quiet.

## Tests

`scripts/ceo-analytics.test.sh` — 52 tests. The fixture seam sits at `_gsc_query`, so the ranking,
delta, threshold and rendering logic under test is the same code production runs; nothing stubs the
logic being checked. Covered: revenue rank beating a larger raw decline, both edges of the 5–20
position band, the missing-rank-file disclosure, the no-attribution guarantee, `--dry-run` leaving
the vault untouched (including the directory itself), the artifact landing at the declared path, a
missing credential failing loudly rather than producing an empty report, a malformed data row being
rejected outright rather than half-read (a short row, an over-long row, and a non-numeric field in
each of clicks/impressions/position), a Search Console error body failing the run instead of
reporting "none", the bearer token AND the JWT assertion never reaching curl's argv, a malformed
rank file failing the run instead of truncating it, revenue rank never leaking onto a non-money
site (for both the clicks-lost and zero-click findings), the new-queries cap and ordering, and the
exact comparison window (start/end of both windows) landing in the report header.

A page absent from the prior window is not counted as a fall from zero, but that behavior is
guarded twice over (`_clicks_lost` skips it both for having no prior row and for a resulting
non-negative delta) — deleting either guard alone still passes the suite, so treat that pairing as
behavior-level coverage, not a mutation-pinned line.

## Known gaps

- **Ads spend is not in the expense set**, and 62 Mercury debits totalling $15,413.50 are
  uncategorized in norx-operations. So "am I profitable" stays unanswerable regardless of this
  report — that is bookkeeping, not analytics, and it is the higher-dollar item.
- The rank file is manual until norx-operations exposes a product→revenue aggregate.
- `deconpinn.com`'s Search Console verification is presumed from the shared Google account, not
  confirmed. If the first run returns nothing for it, that is why.
