# review-tools

## WEB ダッシュボード起動

```
.review-tools/serve.py
```

→ http://localhost:38500/ (変更は `--port`)

## その他のコマンド

respond.sh と close.sh はレビュー対象リポジトリの中から実行する。

- 指摘への裁定: `.review-tools/respond.sh "1:fix/h 理由 2:fp 理由 3:skip"` — verdict は fix/fp/skip/dup、`/h /m /l` は任意。pending が 0 になるまで push はブロックされる
- セッション手動クローズ: `.review-tools/close.sh "理由" [branch]` — 放棄したブランチなど、自然に閉じないセッション用
- スモークテスト: `.review-tools/smoke.sh` — 各 CLI を self-update してから疎通確認。レビュアーが変な応答をし始めたら叩く

## 仕組み

commit/push 時のレビューは global git hook (`core.hooksPath` → `git-hooks/`) から review-commit.sh / review-push.sh が自動発火。ただし `.review-tools/.env` を自分で作った環境でだけ動く (`cp .env.sample .env`)。無ければフックは何もしないので、このツリーを別環境に持って行ってもレビューが勝手に始まることはない。モデルと有効レビュアーは models.conf。正本は log/ 配下のセッションファイルで、REVIEW_LOG.md は自動生成 (手編集しても次の rebuild で消える)。レビューを飛ばすときは `git push --no-verify` か `REVIEW_SKIP=1`。
