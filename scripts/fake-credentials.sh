#!/bin/bash
# fake-credentials.sh — one convention for credential-shaped test fixtures (#572).
#
# A credential-shaped test value is assembled at RUNTIME from split parts through
# this helper, so the tree never holds a literal that a secret scanner (or a
# human skimming a public repo) can mistake for a leaked key. The body spells
# FAKE, is detector-length, and is visibly fake to a person:
#   fake_token ghp_  ->  ghp_FAKEFAKEFAKEFAKE0000EXAMPLE00000
#   fake_secret("ghp_")  ->  same value (python twin; one body shape everywhere)
#
# The fixture's NAME must say so too (FAKE_GITHUB_TOKEN, never bare `token`),
# and the fixture block carries one comment:
#   # Synthetic credentials for redaction tests. None of these are real.
#
# #530 dismissed alert #1 by hand in one file; this is the shared convention it
# was pointing at. Deliberately no .github/secret_scanning paths-ignore: that
# would also hide a real key pasted into a test.
#
# The body is one literal in each of the two sites below (bash and python)
# because they ARE the sanctioned assembly sites. Their example lines above show
# the joined shape, so the guard test exempts both files.

# fake_token <prefix> [tag] — print prefix + the standard fake body.
# <prefix> carries the provider's own delimiter, because it differs: "ghp_",
# "sk-", "xoxb-". An optional alphanumeric <tag> makes two tokens in one test
# distinguishable (FAKEFAKEFAKEFAKE<tag>0000EXAMPLE00000).
#   FAKE_GITHUB_TOKEN=$(fake_token ghp_)
#   FAKE_OPENAI_KEY=$(fake_token sk-)
#   FAKE_SLACK_TOKEN=$(fake_token xoxb-)
fake_token() {
  local prefix="${1:?fake_token: provider prefix with delimiter required, e.g. ghp_, sk-, xoxb-}"
  local tag="${2:-}"
  printf '%s%s%s%s' "$prefix" "FAKEFAKEFAKEFAKE" "$tag" "0000EXAMPLE00000"
}
