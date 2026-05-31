# Scheduled Jobs Design

Scheduled Discord work has one scheduler: Hermes cron.

Hermes' built-in LaunchAgent is only process supervision. It starts and
restarts Hermes Gateway. It must not contain business schedules, channel
routing, prompt text, or job-specific behavior.

## Responsibilities

| Layer | Owns | Must not own |
| --- | --- | --- |
| Hermes built-in LaunchAgent | Gateway process lifecycle | schedules, channels, prompts |
| Hermes Gateway | runtime host for cron and hooks | job-specific business logic |
| Hermes cron | time-based scheduling and delivery target | digest/evaluation implementation |
| `config/hermes-cronjobs.json` | job declarations: name, schedule, channel, mode | shell control flow |
| `scripts/register-hermes-cronjobs.sh` | generic JSON-to-Hermes-cron registration | hardcoded job definitions |
| job handler scripts | concrete job behavior | scheduling or channel routing |
| Gateway hooks | Discord event-triggered actions | time-based scheduling |

## Current Jobs

`config/hermes-cronjobs.json` declares:

- `tech-digest 08:00`, `tech-digest 12:30`, `tech-digest 18:00`
- `平日9:50リマインダー`
- `金曜17時gbrainサマリー`

The `tech-digest` jobs use `mode: "script"` and call
`hermes-tech-digest-cron.sh`. That script is a handler: it generates the digest,
saves the digest/evaluation artifacts, optionally writes back to gbrain, and
prints the final Discord message to stdout. Hermes cron owns the schedule and
delivery target.

Reminder and weekly summary jobs use `mode: "prompt"` because they do not need a
custom implementation handler.

## Adding A Scheduled Job

Add a new entry to `config/hermes-cronjobs.json`.

Use `mode: "prompt"` when the job can be expressed as a self-contained Hermes
prompt:

```json
{
  "id": "example-reminder",
  "name": "example reminder",
  "schedule": "0 10 * * 1-5",
  "channel": "morning-brief",
  "mode": "prompt",
  "prompt": "Post a short reminder."
}
```

Use `mode: "script"` when the job needs deterministic file IO, retries,
artifact persistence, external command calls, or custom post-processing:

```json
{
  "id": "example-script-job",
  "name": "example script job",
  "schedule": "0 18 * * 5",
  "channel": "weekly-review",
  "mode": "script",
  "script": "example-script-job.sh",
  "no_agent": true,
  "prompt": "Run the example script."
}
```

Scripts must live under `~/.hermes/scripts/` at runtime. The installer copies
repository scripts matching `scripts/*-cron.sh` there.

## Event Triggers

Discord message-triggered behavior should not be added to Hermes cron. Add it
through Hermes Gateway hooks, using the same separation:

- hook registration decides which Discord events are observed;
- a trigger router reads a declarative trigger config;
- handler scripts implement concrete behavior.

That keeps event triggers extensible without adding a second scheduler.
