# claude-ceo — project instructions

Loaded at session start. Keep concise; the full architecture lives in `README.md`.

## Scheduled work / crons

Scheduling on CEO is run by the **`ceo-schedulerd`** daemon — a thin adapter over the
[cronbird](https://github.com/nhangen/cronbird) engine — **not** crontab or launchd.
Native crontab install is retired. To investigate, list, or create scheduled jobs,
use the **`ceo` CLI** (the front door), not `cronbird` directly:

- **Inspect / list:** `ceo playbook list` (registered jobs), `ceo doctor` (daemon
  health + artifact checks), `ceo playbook info <name>`.
- **Create / change:** edit the playbook `.md` (`docs/playbooks/<name>.md`, or the
  synced `$CEO_VAULT/CEO/playbooks/<name>.md`), then `ceo playbook scan`
  **on ML-1 only** — scan installs schedulers and rewrites the host-local
  `~/.ceo/registry.json` (see the `ceo-scan-only-on-ml1` rule).
- **Enable / disable per host:** `ceo playbook enable|disable <name>`.

Do **not** hand-roll crontab lines, launchd plists, or systemd units for recurring
CEO work — register a playbook (see the `ceo-automated-writers-are-playbooks` rule).

`cronbird` is the engine underneath; its own `cronbird status|list|next-runs`
commands are the front door only for a **standalone** cronbird deployment, not CEO.
