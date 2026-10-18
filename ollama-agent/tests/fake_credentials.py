"""One convention for credential-shaped test fixtures (#572).

A credential-shaped test value is assembled at RUNTIME from split parts through
this helper, so the tree never holds a literal that a secret scanner (or a human
skimming a public repo) can mistake for a leaked key. The body spells FAKE, is
detector-length, and is visibly fake to a person:

    fake_secret("ghp")   ->  "ghp_FAKEFAKEFAKEFAKE0000EXAMPLE00000"
    fake_secret("sk")    ->  "sk_FAKEFAKEFAKEFAKE0000EXAMPLE00000"

It is the python twin of ``scripts/fake-credentials.sh`` (``fake_token``): the
two share one body shape so a bash test and a pytest test fixture look alike.
The fixture's NAME must say so too (FAKE_GITHUB_TOKEN, never bare ``token``),
and the fixture block carries one comment:

    # Synthetic credentials for redaction tests. None of these are real.

#530 dismissed alert #1 by hand in one file; this is the shared convention it
was pointing at. Deliberately no .github/secret_scanning paths-ignore: that
would also hide a real key pasted into a test.

The body is one literal here because this module IS the sanctioned assembly
site: a scanner pattern needs a provider prefix and a token-length body in one
line, and no line in this file joins the two.
"""

# The standard fake body. Detector-length (>= 24 for every provider prefix this
# repo tests), and it spells FAKE/EXAMPLE so a person sees it is not a key.
_FAKE_BODY = "FAKEFAKEFAKEFAKE0000EXAMPLE00000"


def fake_secret(prefix: str) -> str:
    """Return ``prefix`` + the standard fake body, assembled at call time.

    ``prefix`` is the provider's own delimiter-carrying prefix (``"ghp"``,
    ``"sk"``, ``"xoxb"``, ``"AIza"``), passed as its own literal by the caller
    so the joined value exists only at runtime.
    """
    return f"{prefix}_{_FAKE_BODY}"
