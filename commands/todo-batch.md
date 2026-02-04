---
description: 複数ToDoタスクをWorktreeで並列管理し、自走式で一括実行する
---

# ToDo一括実行（オーケストレーション）

複数のplan.mdをWorktreeで分離し、自走式で順次実行します。
不在時にまとめて作業を依頼するケースを想定。

## 使い方

```
/todo-batch all
/todo-batch doc/todos/tasks/task-01/plan.md doc/todos/tasks/task-02/plan.md
```

## 核心原則

1. **自走式**: 成功している限り確認なしで完遂
2. **Worktree分離**: 各タスクを独立したWorktreeで実行
3. **todo-runに委譲**: 実際の実行はtodo-runが行う

## 関係性

```
todo-batch（親）
    ├── Worktree作成・管理
    └── todo-run を呼び出し（子）
```

**todo-run は todo-batch を知らなくても動く。**

## 実行手順

### Step 1: 計画

1. 対象plan.mdを収集
2. 実行計画を表示

```markdown
## 一括実行計画

| # | タスク | plan.md | ステータス |
|---|--------|---------|-----------|
| 1 | 認証機能 | tasks/task-01/plan.md | pending |
| 2 | ログ改善 | tasks/task-02/plan.md | pending |
```

### Step 2: Worktree作成

```bash
mkdir -p .worktrees
git worktree add .worktrees/task-01-認証 -b todo/task-01-認証
git worktree add .worktrees/task-02-ログ -b todo/task-02-ログ
```

**.gitignore に追加（初回のみ）:**
```
.worktrees/
```

### Step 3: タスク実行（サブエージェントでtodo-run）

`Task` ツール（general-purpose）で実行:

```
/todo-run として実行してください。

## plan.mdパス
{パス}

## 作業ディレクトリ
.worktrees/{task-id}/

## 報告形式
- ステータス: completed / failed / blocked
- コミット: {hash}
```

### Step 4: 次のタスクへ

- **成功**: 次のタスクへ（Step 3に戻る）
- **失敗**: 独立タスクは続行、失敗は最後に報告

### Step 5: 全完了後

1. **最終統合テスト**（メインブランチで）
2. **実行結果サマリー**

```markdown
## 一括実行完了

| # | タスク | ステータス | Worktree |
|---|--------|-----------|----------|
| 1 | 認証機能 | completed | .worktrees/task-01-認証/ |
| 2 | ログ改善 | failed | .worktrees/task-02-ログ/ |

成功: 1 / 2 タスク

各Worktreeで確認後、「マージして」と伝えてください。
```

## マージ処理

**「マージして」と言われたら:**

```bash
git checkout main
git merge todo/task-01-認証
git worktree remove .worktrees/task-01-認証
git branch -d todo/task-01-認証
```

**「全部マージして」:**
成功した全タスクをマージ、失敗したWorktreeは残す。

## 出力形式

**実行中:**
```
## タスク 1/3 実行中: 認証機能
```

**完了時:**
```
## タスク 1/3 完了 → 次: ログ改善
```

**全完了:**
```
## 一括実行完了
成功: 2 / 3 タスク
```

## 注意事項

- **自走式**: 実行開始後は完了まで介入不要
- Worktreeは確認が終わるまで残す
- マージはユーザーの承認後のみ
- 失敗タスクは `/todo-run` で個別に再実行可能
