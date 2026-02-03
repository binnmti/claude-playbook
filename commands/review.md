---
description: コミット前ローカルレビュー（CodeRabbit + Copilot + Claude）
argument_instructions: "引数なし=現在の変更のみ、`final`=ブランチ全体のPR前最終レビュー"
---

# コミット前コードレビュー

複数のLLM（CodeRabbit、GitHub Copilot、Claude）を使ってコードレビューを実行し、指摘事項を修正します。

## レビューモード

**引数: $ARGUMENTS**

引数によってレビュー範囲が変わります：

| 引数 | モード | レビュー範囲 |
|------|--------|--------------|
| なし | クイックレビュー | 現在の未コミット変更、または変更がなければ直前のコミット |
| `final` | ファイナルレビュー | mainブランチからの全コミット（PR前最終チェック） |

## 手順

### Step 0: レビュー対象の決定

引数に基づいてレビュー対象を決定してください：

**引数なし（クイックレビュー）の場合:**
1. `git diff` と `git diff --staged` で未コミット変更を確認
2. 変更がある場合: 未コミット変更をレビュー対象とする
3. 変更がない場合: `git diff HEAD~1` で直前のコミットをレビュー対象とする

**引数が `final`（ファイナルレビュー）の場合:**
1. `git log --oneline main..HEAD` でmainからのコミット一覧を確認
2. `git diff main...HEAD` でmainからの全変更をレビュー対象とする
3. ユーザーに「ファイナルレビュー: mainから N件のコミットをレビューします」と報告

### Step 1: 変更内容の確認

Step 0で決定した対象の変更内容を把握してください。

### Step 2: CodeRabbitレビュー

レビューモードに応じたコマンドを実行してください：

**クイックレビュー（未コミット変更）:**
```bash
wsl bash -c "~/.local/bin/cr review --plain -t uncommitted --cwd /mnt/e/Code/Private/TechDive"
```

**クイックレビュー（直前のコミット）:**
```bash
wsl bash -c "~/.local/bin/cr review --plain -t diff --base HEAD~1 --cwd /mnt/e/Code/Private/TechDive"
```

**ファイナルレビュー:**
```bash
wsl bash -c "~/.local/bin/cr review --plain -t diff --base main --cwd /mnt/e/Code/Private/TechDive"
```

結果を「CodeRabbitの指摘」として記録してください。

**注意**: レート制限エラー（「20分待ってください」等）が発生した場合は、「CodeRabbitの指摘: スキップ（レート制限）」と記録して、Step 3に進んでください。

### Step 3: GitHub Copilotレビュー

レビューモードに応じたコマンドを実行してください：

**クイックレビュー（未コミット変更）:**
```bash
copilot --model gpt-5.1-codex-max -p "以下のgit diffをコードレビューしてください。バグ、セキュリティリスク、設計上の問題点を「重大」「警告」「軽微」に分類して指摘してください: $(git diff -- . ':(exclude)*.Designer.cs')"
```

**クイックレビュー（直前のコミット）:**
```bash
copilot --model gpt-5.1-codex-max -p "以下のgit diffをコードレビューしてください。バグ、セキュリティリスク、設計上の問題点を「重大」「警告」「軽微」に分類して指摘してください: $(git diff HEAD~1 -- . ':(exclude)*.Designer.cs')"
```

**ファイナルレビュー:**
```bash
copilot --model gpt-5.1-codex-max -p "以下のgit diffをコードレビューしてください。これはPR前の最終レビューです。バグ、セキュリティリスク、設計上の問題点を「重大」「警告」「軽微」に分類して指摘してください: $(git diff main...HEAD -- . ':(exclude)*.Designer.cs')"
```

結果を「Copilotの指摘」として記録してください。

### Step 4: Claude Codeセルフレビュー

変更されたファイルを読み込み、以下の観点でレビューしてください：

- バグ・論理エラーの可能性
- セキュリティリスク（インジェクション、認証漏れ等）
- CLAUDE.mdの開発原則との整合性（SOLID、DRY、YAGNI）
- 命名・可読性
- テストの有無

**ファイナルレビューの場合は追加で以下も確認:**
- 変更全体の一貫性
- 不要なデバッグコードの残存
- TODOコメントの残存
- ドキュメント（README.md等）の更新漏れ

結果を「Claude Codeの指摘」として記録してください。

### Step 5: 指摘事項の集約

3つのレビュー結果を以下の形式で集約してください：

```
## レビュー結果サマリー

### 重大（必ず修正）
- [CodeRabbit] xxx
- [Copilot] xxx
- [Claude] xxx

### 推奨（修正推奨）
- [CodeRabbit] xxx
- [Copilot] xxx
- [Claude] xxx

### 軽微（任意）
- [CodeRabbit] xxx
- [Copilot] xxx
- [Claude] xxx
```

### Step 6: 修正の実施

「重大」「推奨」の指摘について、ユーザーに確認の上で修正を実施してください。

### Step 7: 再レビュー（ループ）

修正後、Step 2-5を再実行してください。
以下の条件を満たしたら終了：
- 「重大」「推奨」の指摘が0件
- または3回ループした

### Step 8: コミット

レビューが完了したら、変更をコミットしてください：

```bash
git add {変更ファイル}
git commit -m "<type>: <description>

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

**コミットタイプの例:**
- `feat`: 新機能
- `fix`: バグ修正
- `refactor`: リファクタリング
- `test`: テスト追加・修正
- `docs`: ドキュメント

## 出力形式

最終的に以下を報告してください：

```
## レビュー完了

- モード: クイックレビュー / ファイナルレビュー
- 実施回数: N回
- 修正件数: N件
- 残存指摘: N件（軽微のみ）
- コミット: {コミットハッシュ}

### 修正内容
1. xxx
2. xxx

### 残存指摘（軽微）
- xxx
```
