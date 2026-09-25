# 設計メモ

コードを読んでも分からない制約と、それに基づいた判断を残す。

## Apple Silicon 前提

`scripts/init.sh` が Homebrew の prefix を `/opt/homebrew` で直書きしている。
`install.sh` と `init.sh` の両方が `uname -m` で arm64 を確認し、そうでなければ停止する。

`install.sh` 側にも置いているのは、clone という副作用を作る前に落とすため。

## 2つの入口

| 入口 | 経路 |
|---|---|
| `install.sh`（curl で取得） | clone → `make all` → `init.sh` |
| `make init` | `init.sh` のみ |

`install.sh` はリポジトリが存在しない時点で動くため、共通のシェル関数を `source` できない。
そのため OS の判定は両方に書いてある。

## Xcode Command Line Tools の確認は install.sh だけにある

`/usr/bin/git` `/usr/bin/make` `/usr/bin/clang` は**同一のバイナリ**（CLT シム）である。

```sh
$ shasum -a 256 /usr/bin/make /usr/bin/git /usr/bin/clang
34129c71a01a74f7...  # 3つとも一致する
```

したがって CLT が無い Mac では `make` 自体が起動できず、`make init` は `init.sh` に到達しない。
**Makefile の中にチェックを置いても実行されない。**

`init.sh` にも置いていない理由:

- `make init` 経路では到達しない（上記のとおり）
- 残る経路（GitHub から ZIP をダウンロードして展開し、`bash scripts/init.sh` を直接実行）でも、
  Homebrew のインストーラが CLT を自前で導入する

`install.sh` の1箇所だけが意味を持つ。ここは `git clone` と `make` の両方より前にある必要がある。

## ghq ルートの解決

`install.sh` は clone 先を次の順で決める。

1. `ghq root`
2. 環境変数 `GHQ_ROOT`
3. `git config --get ghq.root`
4. 既定値 `~/src`

`ghq` は dotfiles 経由で入るため、新しい Mac ではこのスクリプトより後になる。同じ理由で
`~/.config/git` もまだ存在しない。つまり新規セットアップでは **4 の既定値が使われる**。

既定値を ghq 本来のデフォルト（`~/ghq`）ではなく実際に使っているルートにしているのは、
ここがずれると dotfiles 適用後にプロビジョニングリポジトリだけ ghq の管理外に取り残され、
後日 `ghq get` したときに重複クローンが生じるため。

`git config --get ghq.root` は `~/src` のように**チルダを展開せずに**返す（`ghq root` が絶対パスを
返すのは ghq が内部で展開しているから）。展開しないまま `mkdir` / `git clone` に渡すと、
カレントディレクトリ直下に `~` という名前のディレクトリができる。`${GHQ_ROOT/#\~/${HOME}}` で展開している。

## ansible collection を追加インストールしない

Brewfile の `brew "ansible"` は full パッケージで、`community.general` を自身の仮想環境に
同梱している。この結果:

- `ansible-playbook` には追加インストールが不要
- `ansible-galaxy collection install` は「既に入っている」と判断し、共有パス
  （`~/.ansible/collections`）には書き出さない
- `ansible-lint` は Homebrew の別 formula で、自分の仮想環境にコレクションを持たない

そのため `make lint` は `ANSIBLE_COLLECTIONS_PATH` で ansible 側の同梱先を指している。
`brew --prefix ansible` 経由にしているのは、`brew upgrade` 後に古い keg が残っていても
取り違えないため。`--offline` を付けてネットワークアクセスを発生させない。

`requirements.yml` は置いていない。実行時に不要で、あっても `ansible-galaxy` が何もしない。

ansible-core のバージョンは実行側と lint 側で一致しない（別 formula のため）。パッチ差なので
実害は出ていないが、完全に揃えるならリポジトリ内の単一 venv に両方を入れる必要がある。

## ansible-vault を使わない

`github_access_token` は既定で空にしている。以前は ansible-vault で暗号化した PAT を
`defaults/main.yml` に埋め込んでいたが廃止した。空のままだと公開鍵の GitHub 登録をスキップし、
手動登録を促す。

無人実行するジョブから 1Password CLI（`op read`）は呼べない（Touch ID / GUI 連携が前提）。
プロビジョニング時（人が居る）に 1Password から取り出して Keychain に入れ、無人実行時は
Keychain から読む、という分担を想定している。

## SSH 鍵の生成に user モジュールを使わない

`ansible.builtin.user` の `generate_ssh_key` は macOS では root が必要で、さらに
`ansible_user` を参照する書き方は local connection では未定義になる。`ssh-keygen` を
`creates` 付きの `command` で呼んでいる。

鍵の種類は `github_ssh_key_options` で変数化してある（既定は既存マシンに合わせて `-t rsa -b 4096`）。

## 冪等性

**2回連続で実行し、2回目が `changed=0` になること**を条件にしている。CI もこれを検証する。

- DNS 設定は `networksetup -getdnsservers` の出力と比較し、差があるときだけ実行する
  （`networksetup -setdnsservers` は常に成功するため、無条件に実行すると毎回 changed になる）
- CI で実行できないタスクには `skip_test` タグを付ける（dotfiles の clone、SSH 鍵の生成、DNS 設定）

### 入力ソースを managed にしない

`com.apple.HIToolbox` の `AppleEnabledInputSources` と `AppleSelectedInputSources` は、macOS が
**辞書の配列**として保存する。

```
$ defaults read com.apple.HIToolbox AppleSelectedInputSources
(
        {
        "Bundle ID" = "com.apple.PressAndHold";
        InputSourceKind = "Non Keyboard Input Method";
    },
    ...
)
```

`osx_defaults` は文字列の配列しか書けないため、辞書を模した文字列を書き込むことになる。結果として:

- 書き込んだ値と読み出した値が一致せず、**毎回 changed になる**（冪等性が壊れる）
- そもそも設定として反映されない

2023年から入っていたが機能していなかったため削除した。入力ソースはシステム設定で行う。

## CI

ランナーを明示的に固定している。`macos-latest` は予告なく次のメジャーバージョンへ移るため、
CI が落ちたときに自分の変更が原因なのかイメージが変わったのかを切り分けられなくなる。実際
このリポジトリは、ランナーが arm64 化して `/usr/local/bin/aws` が消えたことで壊れていた。

固定先は**このリポジトリが実際に対象とするメジャーバージョン**に合わせる（現在は `macos-26`）。
古いイメージで検証すると、まさに今回修復したクラスの破損（`spctl --master-disable` の改名、
現行 macOS が無視する defaults）を CI が見逃す。対象の macOS が上がったらここも上げる。

lint ジョブは `make lint` を実行する。ローカルと同じコマンドを通すためで、コレクションの
参照解決もローカルと同じ経路になる。
