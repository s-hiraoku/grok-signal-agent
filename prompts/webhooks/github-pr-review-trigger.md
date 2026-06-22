GitHub webhook または外部 PR monitor から、レビュー待ち・CI 失敗・PR 更新の payload を受信しました。

イベント種別: {event_type}
ペイロード:
```json
{__raw__}
```

payload だけを根拠に、開発者が次に見るべき GitHub PR 状況を日本語で短く整理してください。GitHub MCP や gh CLI が利用できる場合でも、payload の URL と repository を優先し、不足情報を勝手に補完しないでください。

構成:
1. 対象 PR/repository
2. 今必要なアクション
3. リスクまたはブロッカー
4. 直接URL

レビュー依頼、CI 失敗、merge conflict、長時間放置のいずれでもない低信号イベントなら `[SILENT]` を返してください。
