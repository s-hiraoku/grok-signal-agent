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
   出典: @handle / URL

2. 見出し
   要点: ...
   なぜ重要か: ...
   出典: @handle / URL

最後に:
- 今日の流れ:
- 明日以降ウォッチすること:
```

## 品質基準

- 重要な投稿は 5-10 件に絞る。
- 各項目は 2-4 行に収める。
- URL または引用元 handle を必ず残す。
- 誇張しない。
- 判断が分かれる場合は、事実と解釈を分ける。
