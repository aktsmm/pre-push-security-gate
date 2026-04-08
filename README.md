# Ag_hook_Security

Git の `pre-push` フックで `gh copilot` を呼び出し、プッシュ直前にセキュリティレビューを実施する検証用ワークスペースです。

## 何をするか

- `git push` の直前に、これから送るコミット差分を抽出します。
- `gh copilot -p` に差分とチェック観点を渡して、セキュリティレビューを実行します。
- `SECURITY_CHECK: FAIL` が返った場合は push を止め、Copilot の指摘と修正案を表示します。
- `SECURITY_CHECK: PASS` が返った場合は push を通します。
- すべての実行結果を `logs/` に保存します。

## ベストプラクティス上の位置付け

このリポジトリは「ローカルでの早期フィードバック」を目的にしています。`pre-push` フックは便利ですが、以下の理由で単独では本番ゲートになりません。

- ローカルフックは `--no-verify` などで迂回できます。
- 各開発者のローカル環境に依存します。
- `gh copilot` やネットワークの状態に影響されます。

本番で運用するなら、以下と組み合わせるのが前提です。

- GitHub branch protection
- 必須ステータスチェック
- GitHub Actions / CodeQL / dependency scan / secret scan
- 重要ブランチへのレビュー必須化

参考:

- Git hooks: https://git-scm.com/docs/githooks#_pre_push
- GitHub Copilot CLI: https://docs.github.com/en/copilot/how-tos/use-copilot-for-common-tasks/use-copilot-in-the-cli
- GitHub CLI `gh copilot`: https://cli.github.com/manual/gh_copilot

## セットアップ

前提:

- Git for Windows（Git Bash を含む）
- GitHub CLI
- `gh copilot` が使える状態

手順:

```bash
bash setup.sh
```

これで `.git/hooks/pre-push` にフックがインストールされます。

## ブランチ対象の切り替え

デフォルトでは全ブランチをチェックします。対象切り替えは [hooks/pre-push](hooks/pre-push) ではなく [scripts/security_check.sh](scripts/security_check.sh) の `should_check_ref` 関数で行います。

すでにコメントで `main` / `master` のみを対象にする例を入れてあります。そこを置き換えるだけで切り替えできます。

## 失敗時の扱い

- デフォルトは fail-close です。`gh copilot` に失敗した場合も push を止めます。
- 一時的に fail-open にしたい場合は `SECURITY_HOOK_FAIL_OPEN=1` を使います。
- ローカル検証でフック自体をスキップしたい場合は `SKIP_COPILOT_SECURITY_HOOK=1 git push` を使います。

## ログ

ログは `logs/security-YYYYMMDD-HHMMSS.log` に出力されます。

記録内容:

- 実行日時
- 対象 remote / ref
- 対象ファイル
- Copilot への実行コマンド種別
- Copilot の生出力
- 最終結果

## デモ素材

- [demo/vulnerable_python/app.py](demo/vulnerable_python/app.py): SQL injection, command injection, hardcoded secret
- [demo/vulnerable_js/app.js](demo/vulnerable_js/app.js): XSS, SSRF, hardcoded secret, broken auth
- [demo/safe_js/app.js](demo/safe_js/app.js): 通過確認用の小さな安全側サンプル

## 推奨デモ手順

1. `bash setup.sh`
2. まず脆弱デモを含む commit を作る
3. `.git/hooks/pre-push` を手動実行するか、ダミー remote に push して失敗を確認する
4. 次に安全な差分だけを作って PASS を確認する

手動でフックを再現したい場合の例:

```bash
printf 'refs/heads/main %s refs/heads/main %040d\n' "$(git rev-parse HEAD)" 0 | .git/hooks/pre-push origin https://example.invalid/repo.git
```

## 実装メモ

- push フックは `.git` 配下で実行されるため、スクリプト側で `git rev-parse --show-toplevel` を使ってリポジトリルートを解決しています。
- Copilot へのプロンプトが肥大化しないように、差分パッチは文字数上限で切り詰めています。
- 軽量な regex ベースのプリスキャン結果も Copilot に渡して、代表的な危険シグナルを補助的に拾います。