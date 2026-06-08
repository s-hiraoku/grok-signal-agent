# Jina Reader Access

Hermes can use the official Jina AI Remote MCP server to turn public URLs into
clean Markdown. This is useful when a page is too noisy for normal browser
extraction or when Hermes needs a compact source view.

## Setup

Anonymous Reader access works without an API key, with Jina's anonymous rate
limits:

```bash
scripts/hermes-jina-mcp-setup.sh --restart-gateway
```

For higher limits, put a Jina API key in `~/.hermes/.env`:

```bash
JINA_API_KEY=jina_xxx
```

Then configure the Authorization header by reference:

```bash
scripts/hermes-jina-mcp-setup.sh \
  --api-key-env JINA_API_KEY \
  --restart-gateway
```

The key itself is not written into `~/.hermes/config.yaml`; the config stores
`Bearer ${JINA_API_KEY}` and Hermes expands it from the environment at runtime.

## Enabled Tools

The setup script enables Reader-oriented tools only:

- `read_url`
- `parallel_read_url`
- `guess_datetime_url`
- `capture_screenshot_url`
- `primer`
- `search_jina_blog`

It does not expose broad web search, arXiv/SSRN search, embeddings, reranking,
classification, or extraction tools by default. Those either require an API key
or are outside the "read this URL" use case.

## Verify

Restart Hermes Gateway or start a new CLI session:

```bash
hermes gateway restart
```

Then ask:

```text
Jina Readerで https://example.com をMarkdownとして読んで要点を教えて。
```

If the MCP server does not appear, check:

```bash
tail -n 100 ~/.hermes/logs/mcp-stderr.log
sed -n '/^mcp_servers:/,120p' ~/.hermes/config.yaml
```

## References

- [Official Jina AI MCP server](https://github.com/jina-ai/MCP)
- [Jina Reader](https://jina.ai/reader/)
