# Obsidian Vault Access

ヘルメスちゃん can access one Obsidian vault through Hermes MCP support and
the official filesystem MCP server. Obsidian notes are Markdown files, so this
does not require the Obsidian app to be running.

## What This Enables

After setup, Hermes can:

- search for note files by name;
- list vault folders;
- read note contents;
- create new notes or edit existing notes, unless `--read-only` was used.

The MCP server is launched with the vault path as its only allowed directory.
It cannot access files outside that vault through this server.

## Setup

Install Node.js/npm if `npx` is not already available:

```bash
command -v npx
```

Configure the vault:

```bash
OBSIDIAN_VAULT_PATH="$HOME/Documents/Notes" \
  scripts/hermes-obsidian-mcp-setup.sh --restart-gateway
```

If you keep multiple vaults under one parent directory, expose that parent
explicitly:

```bash
scripts/hermes-obsidian-mcp-setup.sh \
  --vault /Volumes/SSD/Obsidian \
  --allow-non-vault \
  --restart-gateway
```

iCloud vaults often live under:

```bash
$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/<VaultName>
```

Read-only mode:

```bash
scripts/hermes-obsidian-mcp-setup.sh \
  --vault "$HOME/Documents/Notes" \
  --read-only \
  --restart-gateway
```

The script updates `~/.hermes/config.yaml` at
`mcp_servers.obsidian`. It preserves the rest of the Hermes config and replaces
only the `obsidian` MCP entry when re-run.

## Hermes Config Shape

The generated block looks like this:

```yaml
mcp_servers:
  obsidian:
    command: npx
    args:
      - -y
      - "@modelcontextprotocol/server-filesystem"
      - /absolute/path/to/vault
    enabled: true
    timeout: 120
    connect_timeout: 60
    tools:
      include:
        - read_text_file
        - read_media_file
        - read_file
        - read_multiple_files
        - list_directory
        - directory_tree
        - search_files
        - get_file_info
        - list_allowed_directories
        - write_file
        - edit_file
        - create_directory
      resources: false
      prompts: false
```

The write-capable setup intentionally omits delete and move tools. Use
`--read-only` if you want no write/edit/create tools exposed at all.

## Verify

Start a new Hermes CLI session or restart Gateway:

```bash
hermes gateway restart
```

Then ask from CLI or Discord:

```text
Obsidian vaultで「MCP」を含むノートを探して、候補を3件だけ教えて。
ObsidianのDailyフォルダに今日のメモを作って、タイトルだけ入れて。
```

If tools do not appear, check:

```bash
hermes doctor
tail -n 100 ~/.hermes/logs/mcp-stderr.log
sed -n '/^mcp_servers:/,80p' ~/.hermes/config.yaml
```

## Safety

- Point the MCP server at one vault, not at `$HOME` or a parent documents
  folder.
- Prefer `--read-only` first, then enable writes after confirming search/read
  behavior.
- Do not store secrets in Obsidian notes unless you are comfortable exposing
  them to Hermes during conversations.
- Keep `~/.hermes/config.yaml`, `~/.hermes/.env`, and Obsidian vault contents
  out of this repository.
