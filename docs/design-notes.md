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

### gh が生成する鍵

gh 2.93.0 のソースで確認した仕様。

| 項目 | 値 |
|---|---|
| 種類 | ed25519 |
| パス | `~/.ssh/id_ed25519` |
| コメント | 空 |
| 既存の公開鍵がある場合 | 生成せず、どれをアップロードするか尋ねる |

```go
// pkg/ssh/ssh_keys.go
exec.Command(keygenExe, "-t", "ed25519", "-C", "", "-N", passphrase, "-f", keyFile)
// pkg/cmd/auth/shared/login_flow.go
opts.sshContext.GenerateSSHKey("id_ed25519", passphrase)
```

**gh が登録するのは認証用の鍵だけである。** GitHub がコミットを Verified と表示するには、署名用として
別途登録する必要がある。

```sh
gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(hostname)" --type signing
```

dotfiles が `user.signingkey = ~/.ssh/id_ed25519.pub` を指定しており、`commit.gpgsign` は無条件なので、
**この登録を飛ばすと署名は付くが Verified にならず、鍵自体が無いマシンでは一切コミットできない。**

## macOS は Homebrew、Linux は dotfiles

パッケージの入手元は次の方針で分ける。

- **macOS** — Homebrew で入るものは `Brewfile` から入れる。dotfiles にはそれ以外（シェルプラグインなど）だけを持たせる
- **Linux** — dotfiles が全てを入れる

後者が理由である。Linux でも同じ環境を作れるようにするには、dotfiles 単体で完結している必要がある。
そのため dotfiles 側のリリースバイナリ取得は **OS ではなくコマンドの有無で判定する**。macOS では
Homebrew が先に PATH に乗るのでスキップされ、dotfiles だけを持つマシン（Linux、または
mac-provisioning を通していない Mac）では dotfiles が入れる。

### ghq は Homebrew から入れる

zinit が配置する `ghq` のパスは **ghq ルートの内側**にある。

```
PATH ⊃ <ghq root>/github.com/winky/dotfiles/.zinit/plugins/x-motemen---ghq
```

ghq ルートを移動すると ghq 自身のパスが壊れる。`~/development` を `~/src` へ移したときに実際に
起き、`~/.zinit` のリンクを張り直すまで `ghq` が使えなかった。`/opt/homebrew/bin` は ghq の管理範囲
の外にある固定パスなので、この循環がない。

launchd のジョブから使う場合も効く。launchd はシェルの初期化ファイルを読まないため、どちらの場合も
plist で PATH を指定するか絶対パスで呼ぶ必要があるが、その絶対パスがリポジトリの位置に依存しなくなる。

### fzf と asdf も Homebrew から入れる

ghq と同じ理由である。zinit はこの2つの本体も ghq ルートの内側に置いていた。

`~/development` → `~/src` の移行で、asdf の shims が実際に全滅した。

```
$ python3 -c '...'
/Users/winky/.asdf/shims/python3: line 3: exec: asdf: not found
```

shims は `~/.asdf`（ghq ルートの外）なので残るが、そこから呼ばれる本体が消えた。shim の中身は
`exec asdf exec "python3" "$@"` で、**asdf 本体を PATH から引く**ため何も動かなくなる。

当初は「シェル統合まで行っているので単独で扱う」として保留していたが、統合の実体は薄い。

| | 移行前 | 移行後 |
|---|---|---|
| fzf | `atclone'./install --completion --key-bindings'` ＋ `multisrc'shell/{key-bindings,completion}.zsh'` | `eval "$(fzf --zsh)"` |
| asdf | `atload'PATH=$HOME/.asdf/shims:$PATH;'` | 同じ1行を dotfiles 側に残す |

- fzf は 0.48 以降、自身が補完とキーバインドを出力する。install スクリプトと `shell/*.zsh` は不要
- asdf は 0.16 で `asdf.sh` を廃止した。統合は shims の前置だけで、旧来の「`asdf.sh` を source
  する」方式ではない。ただし **asdf の formula は caveats を持たない**ため、shims を PATH に置け
  とは誰も教えてくれない。dotfiles 側の1行が asdf を機能させている唯一の要素になる
- 入るのは Homebrew の asdf 0.20.2 / fzf 0.74.4（zinit 経由は v0.18.0 / 0.62.0）。どちらの asdf も
  0.16 以降の Go 版なので、`ASDF_DATA_DIR`（`~/.asdf`）の plugins / installs はそのまま使える

引き受けるリスクは `brew upgrade` で asdf 本体が意図せず上がること。言語ランタイムの基盤なので
0.15 → 0.16 級の破壊的変更が来ると全部止まる。ただし移行前の `from'gh-r'` も常に最新リリースを
取っていたので**リスクは増えない**。`brew pin asdf` で止められる分だけ改善する（`Brewfile` 単体では
バージョンを固定できない）。

dotfiles 側はシェル統合を「本体がどこから来たか」と独立させ、関数に切り出して両経路から呼ぶ。
`$+commands[...]` で判定するため、**この Brewfile と dotfiles はどちらを先に適用しても壊れない**。
asdf の宣言に残っていた `bpick'*darwin-arm64*'` 決め打ち（ghq / gh で直したのと同じ穴）も、
この変更で uname 由来になった。

### cask は Caskroom ではなく実体を見て決める

Brewfile に無いが実機に入っている cask が12個あった。取り込むかどうかは **Caskroom の日付や
バージョンでは判断できない**。自己更新するアプリは Caskroom の記録が古いまま残る。

- `tableplus` — Caskroom は 5.3.4（2023-03）だが、`/Applications/TablePlus.app` は 26.10.20
  （2026-09）。**使用中**
- `firefox` — 自己更新するアプリなのに `/Applications` が 108.0.2（2023-01）のまま。
  **起動していない**

判断は `/Applications` の実体（`CFBundleShortVersionString` と mtime）で行った。

| 取り込む | 落とす |
|---|---|
| `google-japanese-ime` `session-manager-plugin` `tableplus` | `firefox` `android-studio` `wifi-explorer` — 実体が2023年から動いていない |
| | `postico` `adobe-creative-cloud` — `/Applications` に実体が無い |
| | `superset` — 実体は新しいが使っていない（下記） |

**実体の新しさは使用中の証明にはならない。** `superset` は `/Applications/Superset.app` が
1.12.1（2026-06）で、この調査では「使用中」に分類したが、実際にはもう使っていなかった。
mtime で分かるのは「更新が止まっている＝使っていない」の方向だけで、その逆は言えない。
**新しい側は本人に確認する必要がある。**

方針で除外するもの。

- `sbx` — Docker Sandbox を使わない決定による。独自 tap `winky/tap` 由来でもある
- `adoptopenjdk` — cask が homebrew-cask から削除済みで API が 404 を返す。Brewfile に書けない。
  Java が必要になったら asdf の java プラグインで入れる

### docker cask は docker-desktop に改名された

`docker-desktop` の API が `old_tokens: ["docker"]` を返す。`cask "docker"` は旧トークンで、
Caskroom には `docker` と `docker-desktop` が同一バージョン（`4.43.2,199162`）で二重に登録されて
いた。実体は同じアプリなので、片方を `brew uninstall` すると残った側も壊れる。Brewfile を新しい
トークンに直すだけにとどめる。

### claude-code は cask で入れない

Brewfile に `cask "claude-code"` があったが、実際の Claude Code は native installer が置く
`~/.local/bin/claude` である。dotfiles の PATH 構築は `$HOME/.local/bin` を `/opt/homebrew/bin` より
前に置くため、**cask を入れても使われない**。まっさらな Mac mini で `brew bundle` すると二重に入る。

さらに cask の `zap` は `~/.claude` を trash 対象にしている。ここは `claude_config` ロールが
リンクを張る場所なので、`brew uninstall --zap claude-code` がグローバル設定を消す。

Claude Code 自身が自己更新するため、宣言的に持つ利点も小さい。当日の手順書側に手動インストール
として置く。

## 機種差はプロファイルで表現する

ノートと Mac mini の違いを `host_profile`（`laptop` | `mac-mini`）1つに集約する。判定は
`scripts/host-profile.sh` にしか無く、`scripts/init.sh`（どの Brewfile を渡すか）と `Makefile`
（playbook への `-e host_profile=`）の両方がこれを呼ぶ。`HOST_PROFILE` で上書きできる。

### inventory を2ホストにしない

当初の計画は inventory に `laptop` / `mac-mini` を並べ `host_vars/` で差を表現するものだった。
ansible としては素直だが、**両ホストが `ansible_connection: local`** であるため、この用途では
危険な穴が開く。

- `site.yml` は `hosts: all` にせざるを得ず、`--limit` を忘れると**両プロファイルが同じ機体に
  適用される**（ヘッドレス向けの設定がノートに入る）
- `--limit` のタイポは `no hosts matched` の警告だけで **exit 0**。プロビジョニングが黙って
  何もしない
- 着荷当日、新品の Mac mini で `HOST=mac-mini` を付け忘れる経路が残る

加えて **Brewfile の分割は bash 側でも機種判定を要求する**。`brew bundle` に include の仕組みは
無く、`init.sh` がどのファイルを渡すか決めなければならない。inventory では解決しない。つまり
2ホスト構成は判定機構を減らすのではなく、判定スクリプトの上に inventory の穴を積む形になる。

そのため inventory は `local` 1台のままにし、差は変数で表現する。

### 機種の判定に model identifier を使わない

`sysctl -n hw.model` と ansible の `ansible_product_name` が返すのは model identifier で、
**Apple は識別子から製品名を外した**。Mac mini は以前 `Macmini9,1` だったが、現行機は
`Mac16,10` のような形を返す。`Macmini*` での前方一致は**まさに新しい Mac mini で外れる**。

`system_profiler SPHardwareDataType` の `Model Name` は製品名（`Mac mini` / `MacBook Pro`）を
返すので、こちらを使う。164ms かかるが、プロビジョニングの所要時間では問題にならない。

未知の機種は `HOST_PROFILE` の明示を促して**失敗させる**。ノートをヘッドレス機として
プロビジョニングするより、止まる方がましである。CI ランナーはどちらにも一致しないので、
ワークフローが `-e host_profile=laptop` を明示している。

### プロファイルの解決は check モードでも走らせる

`ansible.builtin.command` は check モード非対応なので `--check` では既定でスキップされる。
解決タスクがスキップされると `host_profile` が未設定のまま `include_vars` に届き、素の
`ansible-playbook site.yml --check` が壊れる。読み取り専用のスクリプトなので `check_mode: false`
を付ける。

`include_vars` は存在しないファイルで失敗する。これが `host_profile` のタイポを silent fallback
ではなくエラーにしている。`vars/laptop.yml` が全スイッチを `false` で明示しているのも同じ理由で、
両プロファイルが実ファイルに解決されることを保証している。

自動判定には、実行時にどのプロファイルが効いたか分からないという弱点がある。引数方式なら
コマンド履歴に残る情報が消える。そのため `include_vars` のタスク名に解決結果を入れてある。

```
TASK [Load the profile variables: mac-mini] ***
```

テンプレートを名前の末尾に置いているのは ansible-lint の `name[template]` を満たすため。

### スイッチ名は unattended、headless ではない

Mac mini は常時稼働・無人復帰させるが、ディスプレイと入力機器を付けて対話利用もする。
`enable_unattended` が gate するのは電源管理（`pmset` の sleep 無効、`autorestart`）と自動ログイン、
スクリーンセーバ無効であって、**画面の有無ではない**。

当初は `enable_headless` としていた。この名前は「画面が無い＝GUI 設定は不要」という読み違いを誘う。
実際に一度そう判断し、`macos` ロールを Mac mini でスキップする / トラックパッド系 defaults を落とす /
`bettertouchtool` をノート専用にする、という3つの誤りにつながっている。

### enable_* を group_vars で既定値にしない

`enable_unattended` などのロールスイッチは `group_vars/all.yml` に**置かない**。

ansible の precedence では `include_vars`（#18）が playbook の `group_vars/all`（#5）を上回る。
両プロファイルが全スイッチを定義している限り group_vars 側の値は**一度も読まれない**。

問題は冗長さではなく、スイッチを1つ書き忘れたときの挙動である。group_vars に既定値があると、
`vars/mac-mini.yml` への追記を忘れた時点で `false` が黙って効き、**必要な機体でロールが
スキップされる**。エラーは出ない。既定値を置かなければ `when: enable_unattended` が
undefined variable で落ちる。

`include_vars` を存在しないファイルで失敗させてタイポを検出しているのと同じ判断である。
代償として、スイッチを追加するときは両プロファイルに書く必要がある。

### Brewfile は機種固有のものだけ分ける

`Brewfile`（共通）/ `Brewfile.laptop` / `Brewfile.mac-mini` の3本。**GUI と CLI では分けない。**
Mac mini は常時稼働・無人復帰させるが SSH 専用ではなく、ディスプレイと入力機器を付けて対話利用も
する。GUI アプリは両方に必要である。

| | 入るもの | 理由 |
|---|---|---|
| `Brewfile.laptop` | `tailscale-app` | GUI アプリ版の Tailscale。下記 |
| `Brewfile.mac-mini` | `ollama` | ローカル LLM。アプリではなく formula を使い、常駐させる |
| | `tailscale` | formula 版。下記 |

片方が空になる時期もある。その場合も**ファイルは消さずコメントだけ残す**。`init.sh` がファイルの
不在を許容すると、プロファイル名を間違えたときに黙ってスキップされる。`brew bundle` はコメント
だけのファイルで exit 0 になるので、空ファイルは no-op として安全に扱える。

### cask_args は書かない

`cask_args appdir: "/Applications"` を全ファイルから外した。`/Applications` は Homebrew の
**既定値**（`Library/Homebrew/cask/config.rb`）なので、この行は何も変えていなかった。

ただし「共通 `Brewfile` に書いてあるから分割ファイルでは不要」という理解は誤りである。
`cask_args` はファイル単位のディレクティブで、`init.sh` は2回に分けて呼ぶ。

```sh
brew bundle --file "${PROVISION_ROOT}/Brewfile"
brew bundle --file "${PROVISION_ROOT}/Brewfile.${PROFILE}"
```

**`--file` の呼び出しをまたいで継承されない。** 既定以外の `appdir` を使いたくなったら、cask を
含む全ファイルに書く必要がある。既定値と同じ行を置いたままにすると、この継承関係を誤読させる
うえ、意味を持っているように見えてしまう。

### Tailscale は機体で入れ方を変える

同じ 1.102.4 が formula と cask の両方にある。要件が違うので機体ごとに選ぶ。

| | 入れ方 | 常駐の形 |
|---|---|---|
| Mac mini | `brew "tailscale"` | service 定義が `require_root: true` なので **root の LaunchDaemon**。ログイン前から上がる |
| ノート | `cask "tailscale-app"` | GUI アプリ。ユーザーセッションの Network Extension |

Mac mini が formula なのは**無人復帰のため**である。電源復帰やリブートの後、誰もログインしていない
状態で tailnet に戻っていなければ遠隔操作できない。GUI アプリはユーザーセッションに紐づくので、この
要件を満たせない。

tailscaled の状態は `/var/lib/tailscale` にあり login keychain を触らないので、「LaunchDaemon は
秘密情報を持たないものに限る」という決定の範囲内に収まる。

ノートが GUI アプリなのは、手で操作する機体でメニューバーから接続状態が見える利点を取ったから。
無人復帰の要件が無い機体に root デーモンを常駐させる理由がない。

バイナリの位置が機体で変わるため `tailscale_bin` は `vars/<profile>.yml` に置く。ロールに
`defaults/main.yml` を置かないのは `enable_*` と同じ理由で、既定値があると**ノートで formula の
パスを見て「未インストール」と誤報する**。

### Tailscale は両端が tailnet に居ないと通らない

ピアツーピアのメッシュなので、Mac mini だけ参加させても tailnet 外のノートからは到達できない。
Funnel は HTTPS の公開用で SSH の経路にはならず、subnet router は「tailnet 上の端末から LAN へ」の
逆向きである。

そのためノートにも、iPad から繋ぐなら iPad にも Tailscale が必要になる。iPad は App Store の公式
アプリで参加させる（Homebrew の管理外）。

### tailscale ロールは状態を報告して失敗させない

デーモンの起動（formula は root が必要）と `tailscale up`（ブラウザでの承認）はどちらも一度きりの
対話操作なので自動化しない。`claude_config` と同じ形で、状態を読んで**次に打つコマンドを出す**。
play を失敗させないので、次の `make deploy` がその先の状態を報告する。

状態は4つに分かれる。

| 状態 | 出すもの |
|---|---|
| バイナリが無い | `make init`（プロファイルごとの Brewfile 記述を添えて） |
| `status --json` が非ゼロ | デーモンの起動コマンド（`sudo brew services start tailscale` / `open -a Tailscale`） |
| `BackendState != Running` | `tailscale up` |
| `Running` | 状態確認のコマンドのみ |

`status --json` の rc を `failed_when: false` で保持しているのは、**デーモンに繋がらないことと
ログインしていないことが別の状態**であり、同じ案内を出すと手戻りになるためである。

## dotfiles は ghq 配下に置く

`dotfiles_path` は ghq のルート配下（既定 `~/src/github.com/winky/dotfiles`）を指す。以前は
`~/.dotfiles` だったが、実際の運用は ghq 管理下であり、そのままでは新しい Mac に**2つ目の
clone が作られる**。

`~/.dotfiles` を前提にしていた影響は目に見えにくかった。`~/.dotfiles` が（中身が不完全でも）
存在すると `Install dotfiles` ブロックは「導入済み」と判断してスキップするため、何も起きない
ように見える。

ghq ルートは `dotfiles_ghq_root` / `claude_config_ghq_root` がそれぞれ持ち、play レベルの
`ghq_root` があればそちらを使う。Phase 2 でホストごとに `ghq_root` を設定する。

## `make check` では捕まらないものがある

check モードは `command` / `shell` タスクを実行しない。したがって「コマンドの実行自体が失敗する」
種類の問題は dry-run では現れず、実際に適用するまで分からない。`make homeConfig` を呼ぶタスクを
足したときに、存在しないディレクトリで make を実行しようとする不具合が `make check` を通過した。

CI も同じ穴を持つ。`skip_test` タグを付けたタスク（dotfiles の clone、DNS 設定、`claude_config`
の全タスク）は CI で実行されないため、そちらでも検出されない。

外部コマンドを呼ぶタスクを追加するときは、dry-run と CI の両方が対象外である前提で、前提条件
（対象ディレクトリの存在、認証状態）を明示的に確認するタスクを添える。

### 他のリポジトリの make ターゲットは中身を読む

`dotfiles` ロールは長く `make install` を呼んでいた。そのターゲットの実体はこうだった。

```make
install: clean update deploy
	@exec $$SHELL
```

- `clean` はホームの dotfiles シンボリックリンクを `rm -vrf` する
- `update` は `git pull origin master` を実行する
- `exec $SHELL` は make を、tty を持たないシェルに置き換える

**この3つはどの検証にも現れない。** dry-run は `command` を実行せず、CI は `skip_test` タグで
除外し、新品のマシンでは `clean` が消すものが無いため無害に見える。ターゲット名からも分からない。
呼ぶ前に定義を読む以外に検出手段がない。

## ロールは対象リポジトリの make ターゲットを呼ぶ

`dotfiles` と `claude_config` は、リンクを自前で張らずに対象リポジトリの make ターゲットを呼ぶ
（`make deploy` / `make homeConfig` / `make install`）。リンクの定義がリポジトリ側の1箇所に
収まり、対象が増えても playbook を直す必要がない。

playbook が持つのは**実行すべきかどうかを判定するためのリンク一覧**だけで、リンクそのものは作らない。
判定は「リンクが欠けているか、対象リポジトリ以外を指しているか」で行う。これにより、既にリポジトリを
持っているマシンでもリンクが壊れていれば復旧する（ghq ルートを移したときは21本すべてが旧パスを
指していた）。

呼ぶ前に確認すべき点は3つある。

| 確認 | 理由 |
|---|---|
| 破壊的なターゲットを含まないか | 上記の `clean` / `exec $SHELL` |
| 対象ディレクトリを自分で作るか | `claude-config` の `install` は `$(HOME)/.claude` を作らない。ロール側で先に作る |
| cwd に依存するか | `claude-config` は `REPO_DIR := $(shell pwd)` を使う。`make -C` では呼び出し元の cwd を指すため、`chdir` が必須 |

`ln -sfn` は実ディレクトリを置き換えられない。Claude Code は claude.ai から同期したスキルのために
`~/.claude/skills` を実ディレクトリとして作るので、そこに居座っている場合は make を実行せず退避を
促す。

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
4. `make deploy` — dotfiles / tailscale / macos / claude_config

`install.sh` が `make all` ではなく `make init` で止まるのはこのためである。`gh` は `make init` で
入るので、それより前に認証はできない。`make all` のまま通すと `claude_config` が必ず一度失敗する。

`claude_config` ロールは `git ls-remote` で到達性を確認し、届かなければ実行すべきコマンドを表示して
継続する（play は失敗させない）。順序を守れなかった場合や `make all` を使った場合でも、認証後の
`make deploy` で完了する。

`claude-config` の取得には SSH URL を使う。`gh auth login --git-protocol ssh` が鍵を登録するので、
`gh auth git-credential` ヘルパー（`~/.config/git` 経由で設定される）が配置済みかどうかに依存しない。

ghq ルートは各ロールが自前の変数（既定 `~/src`、`install.sh` と同じ）で持つ。`dotfiles` ロールが
`~/.config/git` を配置するのは同じ play の中なので、`claude_config` ロールが `git config --get ghq.root`
を読む形にはできるが、その値はチルダが展開されないまま返るため（後述の「ghq ルートの解決」を参照）
変数で持つ方が単純である。

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

### test ジョブは両プロファイルを回す

`enable_*` で gate されたロールは laptop プロファイルでは1本も走らない。CI も laptop だけだと、
**Mac mini が `unattended` / `agent-user` / `ollama` を実行する最初の機体になる**。見送った
Phase 1.5（macOS VM での検証）が埋めようとしていた穴がそのまま残る。

ランナーは使い捨てなので、そこでなら `pmset` や `dscl` の変更が残らない。VM を立てるより安く、
本番に近い。matrix で `laptop` と `mac-mini` を回す（GitHub Actions は YAML アンカーを使えないので、
ジョブを複製するのではなく matrix にしている）。

`fail-fast: false` を付けているのは、片方のプロファイルの失敗でもう片方が打ち切られると
どちらが壊れたのか分からなくなるためである。

プロファイルは `-e host_profile=` で明示する。ランナーの機種はどちらにも一致しないので、
`scripts/host-profile.sh` は正しく判定を拒否する。
