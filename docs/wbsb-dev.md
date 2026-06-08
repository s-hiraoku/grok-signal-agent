# wbsb.dev Source Notes

`wbsb.dev`（wabisabi）は日本語の技術記事コミュニティとして扱う。
Hermesから参照するときは Jina Reader MCP の `read_url` でページを読ませる。

## Entry Points

- Home: <https://wbsb.dev/>
- New: <https://wbsb.dev/?tab=new>
- Show: <https://wbsb.dev/?tab=show>
- Atom Feed: <https://wbsb.dev/api/feed/atom>
- RSS Feed: <https://wbsb.dev/api/feed/xml>
- Guidelines: <https://wbsb.dev/info/guidelines>

## Usage Guidance

- 記事タイトル、URL、投稿日、著者、技術タグ、要点を確認する。
- ダイジェストや調査回答で使う場合は、必ず記事の直接URLを出す。
- wbsb.devはAIを主題にした記事を禁止しているため、AIニュース源としては扱わない。
- 開発、Web、言語、インフラ、セキュリティ、開発手法などの技術記事ソースとして扱う。
- `config/signal-watchers.json` の `wbsb-feed` / `wbsb-new-html` が新着の
  キャッチアップ trigger source として使う。

## Example Prompt

```text
Jina Readerで https://wbsb.dev/?tab=new を読み、最近の技術記事からWeb/言語/インフラ寄りのものを3件、URL付きで要約して。
```
