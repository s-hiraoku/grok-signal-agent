# Daily X Signal Summary

今日の AI エージェント関連の X 投稿を調べ、日本語で重要度順に要約してください。

## 対象

- AI agents
- coding agents
- autonomous agents
- Grok / xAI
- OpenAI Codex / ChatGPT agents
- Claude Code
- Gemini / Jules / developer agents
- MCP / A2A / tool use
- agent evaluation, safety, security, deployment, pricing, model releases

## 実行方針

- 必ず `x_search` を使って、直近 24 時間を中心に確認する。
- `xurl` は使わない。X/Twitter の検索、投稿発見、反応調査、要約では `x_search` だけを使う。
- `web_search` や browser 系ツールで X/Twitter を代替検索しない。
- 各項目には、必ず X/Twitter 投稿の直接 URL を残す。handle だけの出典は不可。
- 投稿内で引用・リンクされている外部ページの内容を要約に使った場合は、その元ページの直接 URL も `参照ページ:` として残す。
- 単なる宣伝、薄い感想、重複投稿は落とす。
- 一次情報、開発者本人、公式アカウント、実装例、実測、障害情報を優先する。
- 未確認の噂は「未確認」と明記する。
- 日本語で簡潔にまとめる。

## 出力形式

```text
AIエージェント X重要投稿まとめ（YYYY-MM-DD）

1. 見出し
   要点: ...
   なぜ重要か: ...
   出典: https://x.com/... または https://twitter.com/...
   参照ページ: https://...（外部ページを参照した場合のみ）

2. 見出し
   要点: ...
   なぜ重要か: ...
   出典: https://x.com/... または https://twitter.com/...
   参照ページ: https://...（外部ページを参照した場合のみ）

最後に:
- 今日の流れ:
- 明日以降ウォッチすること:
```

## 品質基準

- 重要な投稿は 5-10 件に絞る。
- 各項目は 2-4 行に収める。
- 各項目に X/Twitter の直接 URL を必ず残す。URL が確認できない項目は出さない。
- Google/Web 検索由来のページを参照した場合は、Google の検索結果 URL ではなく、元記事・公式ページ・ドキュメントの直接 URL を残す。
- 誇張しない。
- 判断が分かれる場合は、事実と解釈を分ける。
