# 設計メモ

コードを読んでも分からない制約と、それに基づいた判断を残す。

## Apple Silicon 前提

`scripts/init.sh` が Homebrew の prefix を `/opt/homebrew` で直書きしている。
`install.sh` と `init.sh` の両方が `uname -m` で arm64 を確認し、そうでなければ停止する。

`install.sh` 側にも置いているのは、clone という副作用を作る前に落とすため。

## 2つの入口

| 入口 | 経路 |
|---|---|
| `install.sh`（curl で取得） | clone → `make init` → `init.sh` |
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

## SSH 鍵を playbook で扱わない

以前は ansible-vault で暗号化した Personal Access Token を埋め込み、`community.general.github_key`
で公開鍵を登録していた。さらにその前段で `ssh-keygen` による鍵生成も行っていた。すべて廃止した。

`gh auth login --git-protocol ssh` が、認証と同時に鍵の生成とアップロードを行う。

> Specifying `ssh` for the git protocol will detect existing SSH keys to upload,
> prompting to create and upload a new key if one is not found.

この認証は対話が必須で避けられない。同じことを playbook で再実装しても自動化の範囲は広がらず、
コードと秘密情報が増えるだけになる。

副産物として、GitHub 用のトークンを保管・ローテーションする必要がなくなった。無人実行するジョブ
（Slack / Backlog）のトークンは別の話で、1Password CLI（`op read`）は Touch ID / GUI 連携が前提の
ため無人では呼べない。プロビジョニング時（人が居る）に 1Password から取り出して Keychain に入れ、
無人実行時は Keychain から読む分担を想定している。

## セットアップの順序と認証の境界

対象リポジトリの公開状態はこうなっている。

| リポジトリ | 公開状態 |
|---|---|
| `mac-provisioning` | public |
| `dotfiles` | public |
| `claude-config` | **private** |

private なのは `claude-config` だけなので、**認証が必要になる地点は1箇所に閉じている**。順序は
そこを境に分ける。

1. Xcode Command Line Tools〔対話〕
2. `install.sh` — clone して `make init`（Homebrew と Brewfile。ここで `gh` が入る）
3. `gh auth login --git-protocol ssh`〔対話〕— 認証と SSH 鍵の登録
4. `make deploy` — dotfiles / macos / claude_config

`install.sh` が `make all` ではなく `make init` で止まるのはこのためである。`gh` は `make init` で
入るので、それより前に認証はできない。`make all` のまま通すと `claude_config` が必ず一度失敗する。

`claude_config` ロールは `git ls-remote` で到達性を確認し、届かなければ実行すべきコマンドを表示して
継続する（play は失敗させない）。順序を守れなかった場合や `make all` を使った場合でも、認証後の
`make deploy` で完了する。

`claude-config` の取得には SSH URL を使う。`gh auth login --git-protocol ssh` が鍵を登録するので、
`gh auth git-credential` ヘルパー（`~/.config/git` 経由で設定される）が配置済みかどうかに依存しない。

なお `dotfiles` ロールは `make install` だけを呼び、`make homeConfig` は呼ばない。そのため
`~/.config/git` は playbook では配置されず、`ghq.root` も設定されない。`claude_config` ロールが
ghq ルートを自前の変数（既定 `~/src`、`install.sh` と同じ）で持っているのはこのためである。

## 冪等性

**2回連続で実行し、2回目が `changed=0` になること**を条件にしている。CI もこれを検証する。

- DNS 設定は `networksetup -getdnsservers` の出力と比較し、差があるときだけ実行する
  （`networksetup -setdnsservers` は常に成功するため、無条件に実行すると毎回 changed になる）
- CI で実行できないタスクには `skip_test` タグを付ける（dotfiles の clone、DNS 設定、`claude_config` の全タスク）

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
