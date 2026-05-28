# エルメスちゃん Self-Growth

This repo treats "self-growth" as an operational loop, not as real
consciousness. エルメスちゃん keeps a persistent identity, memory,
self-evaluations, and weekly improvement notes, then uses them as soft guidance
for later digests.

## What Runs

The heartbeat now does four things:

1. Reads identity from `~/.hermes/prompts/hermes-chan-identity.md`.
2. Reads self-memory from `~/.hermes/state/hermes-chan-memory.md`.
3. Saves each digest under `~/.hermes/state/digests/`.
4. Evaluates each digest and saves the result under
   `~/.hermes/state/evaluations/`.

A weekly LaunchAgent runs on Sunday at 21:10 local time. It reads recent
evaluations and rewrites:

```text
~/.hermes/state/hermes-chan-memory.md
```

That memory is then included in future heartbeat prompts.

## Files

- `prompts/hermes-chan-identity.md`: stable identity, values, and voice.
- `prompts/evaluate-digest.md`: per-digest self-evaluation rubric.
- `prompts/weekly-self-reflection.md`: weekly memory update prompt.
- `scripts/hermes-discord-heartbeat.sh`: digest generation, logging, evaluation.
- `scripts/hermes-weekly-self-reflection.sh`: weekly memory update.
- `launchd/com.shiraoku.grok-signal-agent.weekly-self-reflection.plist`:
  weekly schedule.

## Operating Notes

Install or refresh the LaunchAgents after pulling these files:

```bash
./scripts/install-macos-launchagent.sh
```

Check self-growth logs:

```bash
tail -f ~/.hermes/logs/hermes-discord-heartbeat.log
tail -f ~/.hermes/logs/hermes-weekly-self-reflection.log
```

Inspect memory:

```bash
sed -n '1,220p' ~/.hermes/state/hermes-chan-memory.md
```

Run weekly reflection manually:

```bash
~/.hermes/bin/hermes-weekly-self-reflection.sh
```

## Safety Boundary

エルメスちゃん may update runtime memory, but she does not rewrite this
repository or change LaunchAgents by herself. Code, prompts in this repo, and
service schedules remain human-reviewed.

## gbrain Fit

`garrytan/gbrain` looks well aligned with the long-term version of this idea:
it provides a Markdown-backed brain, hybrid search, synthesized answers,
gap analysis, and MCP/agent integration.

For this repo, the recommended path is:

1. Start with the local Markdown memory loop in `~/.hermes/state/`.
2. Let it produce enough digests and evaluations to learn the shape of useful
   memory.
3. Add gbrain later as the memory backend once there are real pages worth
   searching, linking, and auditing.

Do not add gbrain as a hard dependency until the basic loop proves useful. It
adds another runtime, storage model, and operational surface area.
