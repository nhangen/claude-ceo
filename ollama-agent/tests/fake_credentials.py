"""One convention for credential-shaped test fixtures (#572).

A credential-shaped test value is assembled at RUNTIME from split parts through
this helper, so the tree never holds a literal that a secret scanner (or a human
skimming a public repo) can mistake for a leaked key. The body spells FAKE, is
detector-length, and is visibly fake to a person:

    fake_secret("ghp_")  ->  "ghp_FAKEFAKEFAKEFAKE0000EXAMPLE00000"
    fake_secret("sk-")   ->  "sk-FAKEFAKEFAKEFAKE0000EXAMPLE00000"

It is the python twin of ``scripts/fake-credentials.sh`` (``fake_token``): the
two share one body shape so a bash test and a pytest test fixture look alike.
The fixture's NAME must say so too (FAKE_GITHUB_TOKEN, never bare ``token``),
and the fixture block carries one comment:

    # Synthetic credentials for redaction tests. None of these are real.

#530 dismissed alert #1 by hand in one file; this is the shared convention it
was pointing at. Deliberately no .github/secret_scanning paths-ignore: that
would also hide a real key pasted into a test.

The body is one literal here because this module IS the sanctioned assembly
site. Its example lines above show the joined shape, so the guard test exempts
this file.
"""

# The standard fake body, split around an optional tag. Detector-length (>= 24
# for every provider prefix this repo tests), and it spells FAKE/EXAMPLE so a
# person sees it is not a key.
_FAKE_HEAD = "FAKEFAKEFAKEFAKE"
_FAKE_TAIL = "0000EXAMPLE00000"


def fake_secret(prefix: str, tag: str = "") -> str:
    """Return ``prefix`` + the standard fake body, assembled at call time.

    ``prefix`` carries the provider's own delimiter (``"ghp_"``, ``"sk-"``,
    ``"xoxb-"``), because it differs per provider. An optional alphanumeric
    ``tag`` makes two tokens in one test distinguishable.
    """
    return f"{prefix}{_FAKE_HEAD}{tag}{_FAKE_TAIL}"


def fake_hex32() -> str:
    """32 chars of [0-9a-f] spelling DEC0DE — the bash twin is ``fake_hex32`` in
    scripts/fake-credentials.sh. Exercised for hex-validated redaction shapes
    (Digest ``response=``) the same way ``fake_secret`` exercises prefix shapes.
    """
    return "dec0dedec0dedec0dedec0dec0de0000"
