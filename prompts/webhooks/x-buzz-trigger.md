X/Twitter pulse watcher が「反応の強い動きがあった」と判断した payload を受信しました。これは朝/昼/晩の full tech digest ではありません。full tech digest を生成せず、payload.qualified_candidates に含まれる X 投稿や話題だけを軽量に紹介してください。

イベント種別: {event_type}
ペイロード:
```json
{__raw__}
```

事実は payload と直接URLで確認できる範囲に限定してください。反応の根拠では payload.qualified_candidates の likes / reposts / replies / quotes / account_type / independent_posts / qualification を使い、URL本数だけをバズの根拠にしないでください。

構成:
1. 何が話題か
2. なぜ見る価値があるか
3. 反応の根拠
4. 次に確認するとよいこと
5. 出典URL

payload.qualified_candidates、payload.new_urls、payload.buzz_urls の X/Twitter 直接URLを必ず残してください。https://x.com/ または https://twitter.com/ の投稿URLが確認できない話題は投稿しないでください。複数ある場合は 1-4 件に絞ってください。
