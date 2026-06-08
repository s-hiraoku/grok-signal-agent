# Zenn Source Notes

`zenn.dev`（Zenn）は日本語のエンジニア向け情報共有コミュニティとして扱う。
Hermesから参照するときは Jina Reader MCP の `read_url` でページを読ませる。

## Entry Points

- Home: <https://zenn.dev/>
- Explore: <https://zenn.dev/articles/explore>
- Trend Feed: <https://zenn.dev/feed>
- Manual: <https://zenn.dev/manual>
- About: <https://zenn.dev/about>

## Usage Guidance

- 記事タイトル、URL、投稿日、著者、トピック/タグ、要点を確認する。
- ダイジェストや調査回答で使う場合は、必ず記事の直接URLを出す。
- Tech記事と公式/一次情報に近い記事を優先する。
- 個人記事は一次情報ではなく、個人の知見・実装記録・調査記録として扱う。
- Books、Scraps、Ideasは有用な場合だけ補助情報として扱う。
- `config/signal-watchers.json` の `zenn-trending` がキャッチアップ trigger
  source として使う。

## Example Prompt

```text
Jina Readerで https://zenn.dev/articles/explore を読み、最近のTech記事から開発者が試す価値のあるものを3件、URL付きで要約して。
```
