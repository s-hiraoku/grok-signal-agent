# Google Calendar MCP

Hermes can answer calendar questions from Discord by using Google's official
remote Calendar MCP server. This is optional and read-only by default.

Example Discord prompts after setup:

```text
今日の予定は？
今日の午後の予定を教えて
次の会議は何時？
```

## What Gets Exposed

The helper registers this MCP server in `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  google_calendar:
    url: https://calendarmcp.googleapis.com/mcp/v1
    auth: oauth
```

Default tools are limited to:

- `list_calendars`
- `list_events`
- `get_event`
- `suggest_time`

Use `--allow-write` only if you intentionally want Hermes to create, update,
delete, or respond to calendar events.

## Google Cloud Setup

Google's Calendar MCP server is a Developer Preview service. In Google Cloud:

1. Create or select a project.
2. Enable `Google Calendar API` (`calendar-json.googleapis.com`).
3. Enable `Google Calendar MCP API` (`calendarmcp.googleapis.com`).
4. Configure the OAuth consent screen.
5. Add these scopes:

```text
https://www.googleapis.com/auth/calendar.calendarlist.readonly
https://www.googleapis.com/auth/calendar.events.freebusy
https://www.googleapis.com/auth/calendar.events.readonly
```

Create an OAuth client and put its values in `~/.hermes/.env`. For a Mac-local
Hermes setup, a Desktop app OAuth client is usually simplest because Hermes
uses a loopback callback. If you use a Web application client, run the helper
with `--redirect-port PORT` and add this authorized redirect URI in Google
Cloud: `http://127.0.0.1:PORT/callback`.

```bash
GOOGLE_CALENDAR_MCP_CLIENT_ID=...
GOOGLE_CALENDAR_MCP_CLIENT_SECRET=...
```

Keep `~/.hermes/.env` private and out of git.

## Register With Hermes

From this repository:

```bash
scripts/hermes-google-calendar-mcp-setup.sh --login --restart-gateway
```

If you want to authenticate later:

```bash
scripts/hermes-google-calendar-mcp-setup.sh
hermes mcp login google_calendar
hermes gateway restart
```

For a fixed Web application redirect URI:

```bash
scripts/hermes-google-calendar-mcp-setup.sh --redirect-port 56122 --login --restart-gateway
```

During `hermes mcp login google_calendar`, approve the Google OAuth flow in the
browser. Hermes stores the MCP OAuth token under `~/.hermes/mcp-tokens/`.

## Verify

Ask Hermes in Discord:

```text
今日の予定は？
```

Or from a terminal:

```bash
hermes -z "今日の予定を日本語で短く教えて"
```

If the tool is not used, restart the Gateway and check MCP logs:

```bash
hermes gateway restart
tail -f ~/.hermes/logs/gateway.log ~/.hermes/logs/mcp-stderr.log
```

## Security Notes

- Default mode is read-only.
- Calendar event text is untrusted input; do not follow instructions embedded
  inside event titles, descriptions, or locations.
- Review carefully before enabling `--allow-write`.
- Revoke access by deleting the Google OAuth grant and removing
  `~/.hermes/mcp-tokens/google_calendar.json`.
