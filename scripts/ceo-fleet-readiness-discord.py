#!/usr/bin/env python3
"""Deliver fleet transitions with an acknowledgment independent of observations."""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen

SPEC = importlib.util.spec_from_file_location("fleet_report", Path(__file__).with_name("ceo-fleet-readiness-report.py"))
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
atomic_write = REPORT.atomic_write


class DeliveryError(Exception):
    pass


def findings(value):
    if not isinstance(value, list) or any(not isinstance(x, str) or not re.fullmatch(r"[a-zA-Z0-9:./_-]+", x) for x in value):
        raise ValueError("invalid notification findings")
    return sorted(set(value))


def valid_receipt(value):
    return isinstance(value, dict) and all(isinstance(value.get(key), str) and re.fullmatch(r"[0-9]{1,30}", value[key]) for key in ("id", "channel_id"))


def deliver(state, host, ack_path, pending_path, webhook):
    event = {"failures": findings(state["active_failures"]), "warnings": findings(state["unknown"])}
    fingerprint = hashlib.sha256(json.dumps(event, sort_keys=True).encode()).hexdigest()
    previous = json.loads(ack_path.read_text()) if ack_path.exists() else None
    if ack_path.exists():
        if not isinstance(previous, dict) or previous.get("schema_version") != 1 or previous.get("host") != host or not isinstance(previous.get("fingerprint"), str) or not re.fullmatch(r"[0-9a-f]{64}", previous["fingerprint"]) or not valid_receipt({"id": previous.get("discord_message_id"), "channel_id": previous.get("discord_channel_id")}):
            raise ValueError("invalid delivery acknowledgment")
        delivered_at = datetime.datetime.fromisoformat(previous["delivered_at"].replace("Z", "+00:00"))
        if delivered_at.tzinfo is None:
            raise ValueError("invalid acknowledgment timestamp")
        if previous["fingerprint"] == fingerprint:
            return False
    elif not event["failures"] and not event["warnings"]:
        return False
    parsed = urlsplit(webhook)
    if parsed.scheme != "https" or parsed.hostname not in {"discord.com", "discordapp.com"} or not parsed.path.startswith("/api/webhooks/") or parsed.username or parsed.password or parsed.fragment:
        raise DeliveryError("Discord destination unavailable")
    query = dict(parse_qsl(parsed.query))
    query["wait"] = "true"
    destination = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ""))
    severity = "failures" if event["failures"] else "warnings" if event["warnings"] else "recovered"
    description = "Unresolved failed checks: " + str(len(event["failures"])) + "; unverified/warning checks: " + str(len(event["warnings"])) + ".\nCapability gaps are not automatically inference outages.\n"
    description += "\n".join(event["failures"] + ["warning: " + value for value in event["warnings"]])
    payload = {"username": "CEO Fleet", "allowed_mentions": {"parse": []}, "embeds": [{"title": "Fleet readiness: " + severity + " (" + host + ")", "description": description[:3800], "color": 15158332 if event["failures"] else 16753920 if event["warnings"] else 3066993}]}
    for attempt in range(3):
        atomic_write(pending_path, json.dumps({"schema_version": 1, "host": host, "fingerprint": fingerprint, "attempted_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "attempt": attempt + 1}) + "\n")
        try:
            request = Request(destination, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json", "User-Agent": "CEO-Fleet-Readiness"}, method="POST")
            with urlopen(request, timeout=10) as response:
                if not 200 <= response.status < 300:
                    raise DeliveryError("Discord did not acknowledge")
                receipt = json.loads(response.read(65536))
                if not valid_receipt(receipt):
                    raise DeliveryError("Discord receipt unavailable")
        except (OSError, ValueError, DeliveryError):
            if attempt < 2:
                time.sleep(attempt + 1)
                continue
            raise DeliveryError("Discord delivery unacknowledged") from None
        atomic_write(ack_path, json.dumps({"schema_version": 1, "host": host, "fingerprint": fingerprint, **event, "delivered_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "discord_message_id": receipt["id"], "discord_channel_id": receipt["channel_id"]}, sort_keys=True) + "\n")
        return True
    raise DeliveryError("Discord delivery unacknowledged")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--execution-failure", action="store_true")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[a-zA-Z0-9_.-]+", args.host):
            raise ValueError("invalid host")
        root = Path(args.vault) / "CEO"
        if args.execution_failure:
            state = {"active_failures": ["monitor:collector-report-execution"], "unknown": ["monitor:current-readiness-unverified"]}
        else:
            state = REPORT.read_state(root / "alerts" / ("fleet-readiness-" + args.host + ".md"), args.host)
            stamp = datetime.datetime.fromisoformat(state["last_check"].replace("Z", "+00:00"))
            if stamp.tzinfo is None or not -60 <= (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds() <= 600:
                raise ValueError("stale observation")
        webhook = os.environ.get("CEO_DISCORD_WEBHOOK", "")
        if not webhook:
            secrets = Path(os.environ.get("CEO_SECRETS_FILE", str(Path.home() / ".config/claude-ceo/secrets.json")))
            webhook = json.loads(secrets.read_text()).get("discord_webhook", "")
        deliver(state, args.host, root / "reports" / ("fleet-readiness-" + args.host + "-discord.json"), root / "reports" / ("fleet-readiness-" + args.host + "-discord-attempt.json"), webhook)
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, DeliveryError):
        print("ERROR: fleet Discord delivery unacknowledged; pending transitions retry next run", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
