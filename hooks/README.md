# hooks

このディレクトリは、共有したい Git hook の元ファイル置き場です。

重要:

- Git が実際に実行する hook は `.git/hooks/` 配下にあります
- `.git/` はローカル管理領域なので、通常は Git 管理されず、VS Code からも見えにくいことがあります
- そのため、このリポジトリでは version 管理する hook 本体を `hooks/` に置き、`setup.ps1` または `setup.sh` で `.git/hooks/` へコピーします

このリポジトリでの流れ:

1. [hooks/pre-push](pre-push) を編集する
2. [../setup.ps1](../setup.ps1) または [../setup.sh](../setup.sh) を実行する
3. `.git/hooks/pre-push` にインストールされた実行用 hook を Git が使う

補足:

- `.github/` は GitHub 側の設定置き場であり、local hook の実行場所ではありません
- `.git/hooks/` の中身を直接手で直すより、`hooks/` 側を修正して setup を再実行する方がズレを防げます
