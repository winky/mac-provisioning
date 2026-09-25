# mac-provisioning

![actions](https://img.shields.io/github/actions/workflow/status/winky/mac-provisioning/main.yml?branch=master&label=actions&logo=github&style=flat-square)

Apple Silicon の Mac を Ansible でセットアップする。

## 前提

- Apple Silicon — `scripts/init.sh` が Homebrew の prefix を `/opt/homebrew` で直書きしているため、Intel Mac では動かない
- Xcode Command Line Tools

## 使い方

### 新しい Mac

```sh
curl -fsSL https://raw.githubusercontent.com/winky/mac-provisioning/master/scripts/install.sh | bash
```

ghq のルート配下（既定では `~/src/github.com/winky/mac-provisioning`）に clone し、`make init`
を実行する。別の場所に置くなら `GHQ_ROOT` を渡す。

続いて2つのコマンドを実行する。`gh` は `make init` で入るため、この順序になる。

```sh
gh auth login --git-protocol ssh      # 認証 ＋ SSH 鍵の生成・登録
make -C <repo> deploy                 # playbook の適用
```

### clone 済みの場合

```sh
make check   # 差分の確認（何も変更しない）
make deploy  # 適用
```

## make ターゲット

| target | 内容 |
|---|---|
| `all` | `init` と `deploy` |
| `init` | Homebrew の導入と Brewfile の適用 |
| `deploy` | `ansible-playbook site.yml` |
| `check` | `--check --diff` での dry-run |
| `lint` | `ansible-lint` |
| `help` | ターゲット一覧 |

## 構成

```
Brewfile              brew / cask のパッケージ
scripts/install.sh    新しい Mac で最初に実行する
scripts/init.sh       Homebrew と Brewfile
ansible/site.yml      dotfiles / macos / claude_config の3ロール
```

ロール単位で流すときは tag を使う。

```sh
cd ansible && ansible-playbook site.yml --tags macos
```

## 自動化していないこと

| 項目 | 理由 |
|---|---|
| Xcode Command Line Tools の同意 | GUI の同意が必要。`install.sh` が検知してインストーラを起動し、完了後の再実行を促す |
| Homebrew 導入時の sudo パスワード | インストーラが要求する |
| cask の許可ダイアログ | アプリによって出る |
| `gh` の認証（`gh auth login --git-protocol ssh`） | 対話が必須。認証と同時に SSH 鍵の生成・登録も行う。private な `claude-config` の取得もこれに依存する |
| 入力ソース（キーボード / 日本語入力） | macOS が辞書の配列で保存しており `osx_defaults` では表現できないため。[docs/design-notes.md](docs/design-notes.md) を参照 |

設計上の制約と、その判断の理由は [docs/design-notes.md](docs/design-notes.md) に残している。
