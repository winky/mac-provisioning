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

## ホスト鍵は GitHub の API から取る

`claude_config` と `scheduled_jobs` は SSH で clone する。**一度も接続したことのない機体では、ssh が
ホスト鍵を信用してよいか尋ねて止まる。** タスクからは答えられないので、両ロールは「リポジトリに
到達できない」と報告し、**原因からは遠い場所にメッセージが出る**。Mac mini の初回 deploy で実際に
起きた。

`github_known_hosts` ロールが先に `known_hosts` を用意する。

**`ssh-keyscan` は使わない。** あれは初回にポート22で応答したものを無条件に信じる仕組みで、
ホスト鍵確認が防ごうとしているものそのものである。GitHub は `https://api.github.com/meta` の
`ssh_keys` でホスト鍵を公開しているので、**TLS 検証の効く経路**で取れる。

**問い合わせるのは known_hosts に無いときだけ。** 未認証の api.github.com は1時間あたり60回/IP
で、CI のランナーは IP を共有する。毎回取りに行く最初の版はこれを使い切り、**play ごと落ちた**。
`ssh-keygen -F` で先に確認すれば、通常の実行はネットワークに触れない。

取得に失敗しても deploy は止めない。レート制限や障害でこの1ロールが転ぶ理由は、他の7ロールが
やることを諦める理由にならない。代わりに **`ssh -T git@github.com` を受け入れる**よう報告する。

`known_hosts` モジュールは既にある項目を書き換えないので、繰り返しても変更にならない。鍵が
入れ替わったときだけ changed になる。

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

この分岐は `status --json` の挙動に依存している。実機（GUI アプリ版、未ログイン）で確認した結果:

```
$ /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json ; echo $?
{ "BackendState": "NeedsLogin", "Self": { "DNSName": "", ... } }
0
```

**未ログインでも rc は 0 で、状態は `BackendState` に出る。** ここが非ゼロだと、ロールは
「デーモンに繋がらない」という誤った案内を出す。ロールが状態を取り違えるようになったら、
最初に疑うのはこの前提である。

`Self.DNSName` は未ログイン時は空文字列になる。`Running` のメッセージで tailnet 名を出すのを
やめたのはこのため（`json_query` は `community.general` 依存で、collection を追加しない方針にも
反する）。

### ログインの案内はプロファイルで変える

同じ「未ログイン」でも打つものが違う。ノートは GUI アプリなのでメニューバーから入るのが自然で、
Mac mini には無人復帰の途中でクリックできるメニューバーが無い。`tailscale_login_hint` を
`vars/<profile>.yml` に置いて出し分ける。

cask が入れるのは standalone（`io.tailscale.ipn.macsys`）ビルドなので、ノートでも CLI の `up` は
使える。App Store 版（`io.tailscale.ipn.macos`）ほど制限されていない。

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
| `scheduled-jobs` | **private** |

private は2つある（`scheduled-jobs` は Backlog のプロジェクトキーや Slack のチャンネル名を持つため）。
**どちらも同じ境界の後ろ**にあり、認証が必要になる地点は増えていない。順序はそこを境に分ける。

1. Xcode Command Line Tools〔対話〕
2. `install.sh` — clone して `make init`（Homebrew と Brewfile。ここで `gh` が入る）
3. `gh auth login --git-protocol ssh`〔対話〕— 認証と SSH 鍵の登録
4. `make deploy` — github_known_hosts / dotfiles / tailscale / unattended / ollama /
   scheduled_jobs / macos / claude_config

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

## ロールは root の要否で「収束」と「報告」に分かれる

Phase 3 の3ロールを書いた結果、境目がはっきりした。**root を必要とするものは報告に留め、必要と
しないものは収束させる。**

理由は `make deploy` を**パスワード無しで実行できる状態に保つ**ことにある。この機体は launchd の
ジョブを走らせる側なので、deploy が sudo プロンプトで止まるならジョブから呼べない。

| ロール | 動作 | 根拠 |
|---|---|---|
| `dotfiles` / `claude_config` / `macos` | 収束 | ホーム配下と user defaults のみ |
| `ollama` | 収束 | ホーム配下のファイルとユーザーの LaunchAgent のみ |
| `scheduled_jobs` | 収束 | clone と相手の `make install`。どちらもホーム配下 |
| `tailscale` | 報告 | デーモン起動が root。ログインはブラウザでの承認 |
| `unattended` | 報告 | `pmset` が root。FileVault は設定ウィザードの選択 |

報告に留めても実害が小さいのは、そこで見ている設定が**一度決めれば保たれる**ものだからである。
`pmset` の値も FileVault も Tailscale のログインも、ドリフトしない。手で一度打つコストは1コマンドで、
自動化すると以降すべての deploy にパスワードが付く。

この境目を破りかけたのは `agent-user`（`dscl` でのユーザー作成は root が必要で、かつ「一度打てば
終わり」とも言いにくい）だが、**そのロールを作らない判断をしたため試されずに済んだ**。

## エージェント専用ユーザーは作らない

当初は管理者とは別に**エージェント専用ユーザー**を作る方針だった。**作らないことにした。**

### 隔離はサンドボックスが担っている

専用ユーザーで防ぎたかったのは「エージェントが人間側のファイルと keychain に触れること」である。
それはすでに別の層で満たされている。方針として Docker Sandbox を使わず **Claude Code 内蔵
サンドボックス ＋ devcontainer** で代替すると決めており、`claude-config` の設定がこう効いている。

```json
"filesystem": { "allowWrite": ["~/src"] }
"network":    { "allowedDomains": ["github.com", "api.github.com", ...] }
```

書き込みは `~/src` 配下のみ、ネットワークは GitHub のみ。**Unix ユーザーの境界より細かく、しかも
同一ユーザーの中で効く。**「エージェントが人間のファイルを壊す」という脅威に対しては、専用
ユーザーより直接的である。

### 分離のコストは当初より上がっていた

1. **playbook のほぼ全体が二重化する。** ロールは playbook 実行ユーザーのホームに結びついている
   （`group_vars/all.yml` の `ghq_root`、`dotfiles` / `claude_config` の defaults、`ollama` の
   `~/.homebrew/services` と `~/.ollama/models`）。agent ユーザーで Claude Code をまともに動かすには
   dotfiles も `~/.claude` も必要なので、**1ロールではなく完成済み4ロールを別 identity でもう一周
   させる話**になる
2. **FileVault が意図を反転させる。** 事前起動認証でログインするのは解錠したユーザーだけなので、
   agent の LaunchAgent を動かすには agent ユーザーで解錠することになり、agent が主たる対話
   identity になってしまう
3. **パスワード無し deploy が崩れる。** `dscl` に root が必要になる

### 可逆だが、コストは増える

後から作る方向へは変更できる。ロールの変数化の手間は今やるのと同じである。

ただし**蓄積データの移行コストは増え続ける** — `~/src` のリポジトリ、`~/.claude`、**ollama の
モデル（数十GB規模）**、keychain の項目。早いほど安い。

ジョブを別リポジトリへ出したことで、**この保険は不要になった**。`scheduled-jobs` の `make install`
は `$(HOME)` に置くので、専用ユーザーを作るなら**そのユーザーとして `make install` を呼ぶ**だけで
追随する。playbook 側に変数を用意する必要がない。完成済みロールの変数化は依然として投機的なので
行わない。

### 再検討の契機

エージェントに **sudo を要する作業**をさせたくなった時、または **`~/src` 外への書き込み**が必要に
なった時。前者の場合、設計は「専用ユーザーを作る」ではなく「どのコマンドを `sudoers` で許すか」に
なる。

## 無人稼働の設定は適用せず報告する

`unattended` ロールは `pmset` を書き換えない。状態を読んで、打つべき `sudo pmset -a ...` を出すだけ
である。

理由は `make deploy` を**パスワード無しで実行できる状態に保つこと**にある。このロールが対象にする
のは launchd のジョブを走らせる機体で、deploy が sudo プロンプトで止まるならジョブから呼べない。

代償が小さいのは、ここで見る設定が**ドリフトしない**ためである。`pmset` の値も FileVault も、機体
ごとに一度決めれば再起動をまたいで保たれる。手で一度打つコストは1コマンドだが、自動化すると以降
すべての deploy にパスワードが付く。

## FileVault は有効にする

当初は「FileVault 無効 ＋ 自動ログイン有効」で無人復帰を取る方針だった。**反転させた。** Mac mini は
無人稼働だけでなく手でも使うため、盗難時に電源を入れるだけで中身が読める状態は釣り合わない。

### 自動ログインが不要になる

Apple Silicon では **FileVault の事前起動認証がそのままログインになる**（パスワードを2回打たないのは
このため）。したがって FileVault を有効にすると:

- **自動ログインの設定自体が要らない。** `/etc/kcpassword` に可逆な形でパスワードを書く処理が
  設計から消える
- **login keychain は人が解錠するまで開かない。** 「自動ログインで解錠されるので Keychain に
  閉じ込めても安全ではない」という前提が覆り、Keychain が本来の意味で機能する

この2点目により、「この機体に置く認証情報は最小権限・短命に絞る」という制約の根拠が弱まる。制約
自体は残してよいが、それだけが防御線ではなくなる。

### 代わりに失うもの

**予期しない電源断からの無人復帰。** macOS に FileVault の自動解錠・遠隔解錠は存在しない。

- `fdesetup authrestart` は**自分で発行する再起動1回分**の解錠を預ける。停電やカーネルパニックには
  効かない
- MDM の認証付き再起動は動いている OS から発行するもので、解錠画面で止まった機体には届かない
- `pmset repeat poweron` で電源は入るが、解錠画面で止まる
- Linux の dropbear-initramfs 相当のものは macOS に無い

### UPS が設計の一部になる

穴の埋め方として **UPS を前提に置く**。短時間の停電では再起動そのものを起こさせず、電池が尽きる
前に macOS に正常シャットダウンさせる。これで残るのは「外出中の長時間停電・パニック」だけになる。

ロールは `system_profiler SPPowerDataType` の `UPS Installed` を見て、無ければ指摘する。**あった方が
良い装備ではなく、FileVault を有効にしたことで生まれた穴に対する選択済みの答え**なので、未達の前提
として扱う。

`pmset -g ups` は何も出さず、`pmset -g ps` は「今どこから給電されているか」しか答えない。
`system_profiler` はその有無を直接述べる。

死活監視（tailnet から落ちたら通知）も併せて必要だが、こちらはノート側から動かすのが素直なので
このリポジトリの外側に置く。

ロールは `fdesetup supportsauthrestart` も確認する。これが false だと OS アップデートの再起動まで
物理操作が必要になり、遠隔での維持が現実的でなくなるため。

完了メッセージが「無人稼働できる」と言わずに**UPS を超える停電では止まることを明記している**のは、
このトレードオフを報告が隠してはいけないからである。

### 採らなかった構成

**FileVault 無効 ＋ 自動ログイン無効**も検討した。sshd と tailscaled はユーザーセッションに依存しない
LaunchDaemon なので、ログイン画面で待っている機体にも**SSH で到達できる**。当初案（FileVault 無効 ＋
自動ログイン有効）より明確に良く、`kcpassword` も書かずに済む。

採らなかったのは、盗難時にディスクが読めてしまうこと。手でも使う機体で、電源を入れるだけで中身が
読める状態は釣り合わない。

この構成を採る場合、ジョブの設計も変わる。ログインしないと login keychain が開かないので、
「秘密情報を使うジョブは LaunchAgent」という決定を捨て、System keychain（`/Library/Keychains/System.keychain`）
＋ LaunchDaemon に寄せることになる。**FileVault を有効にした結果、その付け替えは不要になった** —
解錠がログインを兼ねるので、解錠後は login keychain も LaunchAgent も期待どおり動く。

### 管理しないもの

`displaysleep` とスクリーンセーバは**意図的に対象外**にしている。無人で復帰することとディスプレイが
点いていることは無関係で、Mac mini には手で使うモニタが繋がる。点けたままにしてもパネルを消耗する
だけである。

### autorestart は実機でしか確かめられない

電源復旧後に自動起動する設定だが、**ノートの `pmset` 出力には現れない**。Intel 時代の SMC 設定で、
Apple Silicon の Mac mini が公開しているかどうかは未検証である。

ロールは「pmset が報告しない設定は未設定として扱う」ので、出力に無い環境では常に drift として
報告される。`enable_unattended` が付く機体でしか走らないため実害はない。

### 条件式に正規表現を置かない

各設定を `when` の中で正規表現に照合する形を最初に書き、**動かなかった**。

```yaml
# 一致する行があっても False になる
when: not unattended_pmset.stdout is search('(?m)^\s*' ~ item.key ~ '\s+' ~ item.value ~ '\b')
```

同じ式を `{{ }}` で囲むと正しく True を返す。`search('womp')` や `search('womp\s+1')` は素の `when`
でも通るのに、`(?m)^` を含めた時点で通らなくなる。**バックスラッシュを含む条件式は `{{ }}` の中と
評価経路が違う。**

`pmset -g` を一度 dict に起こして**値として比較する**形に変えた。条件式から正規表現を外せば、この
問題自体が起きない。

## ollama は収束させる

`unattended` と違い、`ollama` ロールは**状態を報告せず実際に収束させる**。境目は root の要否である。
このロールが触るのはホーム配下のファイルとユーザーの LaunchAgent だけなので、`make deploy` を
パスワード無しで実行できる状態を崩さない。

`pmset` や FileVault のように root が必要なものだけを報告に留める、という切り分けになる。

### モデル置き場は Homebrew の env ファイルで渡す

`OLLAMA_MODELS` を service に渡す必要があるが、formula の service 定義は
`OLLAMA_FLASH_ATTENTION` と `OLLAMA_KV_CACHE_TYPE` を持つだけで `OLLAMA_MODELS` は無い。

Homebrew には専用の仕組みがある。

```
$HOMEBREW_USER_CONFIG_HOME/services/<formula>.env   （既定 ~/.homebrew/services/<formula>.env）
KEY=value を1行ずつ
```

これを使うと **plist は formula のものであり続ける**。自前で plist を書くと、formula が env を
足したときに追随しなければならなくなる。`launchctl setenv` はセッション全体に効いてしまい、
`~/.ollama/models` への symlink はリポジトリから見えない場所に設定を追い出す。どちらも採らない。

移行は `ansible/vars/mac-mini.yml` の `ollama_models_path` を1行変えるだけになる。env ファイルが
変われば handler が `brew services restart` する（service は読み込み時にしか env を見ない）。

### LaunchAgent と LaunchDaemon の差が消えている

formula の service 定義に `require_root` が無いので、`brew services start` が置くのは
**LaunchAgent** である（`tailscale` は `require_root: true` なので LaunchDaemon）。

以前ならこれは弱い選択だった。LaunchAgent はログインを待つためである。しかし **FileVault を
有効にした結果、解錠より前には何も動かない**。解錠がログインを兼ねるので、この機体では両者が
実質同じタイミングになる。

### OLLAMA_HOST は広げない

既定の `127.0.0.1:11434` のままにしている。ジョブB は同じ機体で動くのでこれで足りる。

ノートから直接叩くには `OLLAMA_HOST` を広げることになるが、**ollama は認証を持たない**。tailnet に
認証なしのエンドポイントを置く判断になるため、必要になった時点で改めて決める。ロールは現在の
待ち受けを報告に含めて、この判断が忘れられないようにしている。

## ジョブはこのリポジトリが持たない

スケジュール実行するジョブは [winky/scheduled-jobs](https://github.com/winky/scheduled-jobs) が
持つ。**このリポジトリが持つのは「この機体でジョブを動かすか」だけ**である
（`enable_scheduled_jobs`）。

一度は逆に作った。`launchd` ロールが `launchd_jobs` というジョブ定義のリストを受け取り、plist を
組み立てて load していた。**それは上の「ロールは対象リポジトリの make ターゲットを呼ぶ」に反して
いる。** あの節はこう述べている。

> リンクの定義がリポジトリ側の1箇所に収まり、**対象が増えても playbook を直す必要がない**

ところが `launchd` ロールは、他所が所有する中身のために plist の形・テンプレート・bootout /
bootstrap を playbook 側に実装しており、**ジョブが増えるたびに playbook を直す設計**だった。

### 分けた理由

1. **変更の頻度が違う。** プロビジョニングは機体や道具を変えた時しか触らない。ジョブの判定基準や
   プロンプトは運用しながら頻繁に触る
2. **検証の仕方が違う。** ここの CI は macOS ランナーで playbook を適用する。ジョブに必要なのは
   Backlog / Slack / LLM を絡めた検証で、ansible を通す必要がない
3. **寿命と移植性が違う。** リポジトリ最新化のジョブは bash ＋ git ＋ ghq だけで動き、macOS 固有の
   要素が無い。機体を入れ替えても Linux に移してもそのまま動く

### 境界

| | 所有者 |
|---|---|
| ジョブが何をするか / **いつ動くか** / plist の設置 | scheduled-jobs（`make install`） |
| **資格情報をどこから取り Keychain のどの名前に入れるか** | **scheduled-jobs**（`make credentials`） |
| この機体でジョブを動かすか | ここ（`enable_scheduled_jobs`） |
| リポジトリを置き `make install` を呼ぶ | ここ（`scheduled_jobs` ロール） |

「いつ動かすか」もジョブ側に置いた。機体の方針ではないかという反論はあり得るが、**ジョブを動かす
機体は1台**で、`enable_scheduled_jobs` が動かすか否かを担う。時刻はジョブの性質（朝のブリーフは朝で
ないと意味がない）なのでジョブ側が自然である。

### 秘密情報の受け渡しも向こうに置いた

当初は「秘密情報を Keychain に入れるのはここ（`secrets` ロール）」という線を引いていた。**引き直した。**
1Password から login keychain へ写す `keychain` ロールを一度書いたが、`launchd` ロールと同じ構図だった
—「どの資格情報を・どこから・どの名前で」はジョブの要件で、keychain に書くのは機械的な部分にすぎない。

移したことで、**ansible では避けられなかった複雑さが消えた**。値に触るタスクは `no_log` を要するが、
`no_log` は失敗の理由まで伏せる。実際に `op://` 参照がカッコで解決できなかったとき、playbook からは
「失敗した、出力は伏せた」としか見えず、失敗した参照の名前だけを別途抽出して報告する仕組みを足す
ことになった。シェルなら値は変数に入るだけで、エラーはそのまま出せる。

結果として、このリポジトリが持つのは**「この機体でジョブを動かすか」だけ**になった。`secrets` ロールは
作らない。

### changed の判定は相手の出力に任せる

`make -C <repo> install` は毎回走る。変更があったかどうかは**相手の出力**で決める — あの Makefile は
plist を実際に書いた時だけ `placed <label>` を出すので、それを見る。

ここで判定を自前で書くと、相手がすでに行っている比較を再実装することになる。それはこの分割で
取り除いた重複そのものである。

なお `make -C` で足りる。あの Makefile は自分の位置を `MAKEFILE_LIST` から解決するので、
`claude-config` のように呼ぶ側の `chdir` を要求しない。

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

### CI が届かない範囲がある

test ジョブが回すのは playbook だけで、**`make init` は回さない**。`Brewfile` の変更も
`scripts/init.sh` も CI の対象外である。

そして `init.sh` で最も壊れやすいのは**まっさらな機体でしか通らない経路**、つまり Homebrew 自体の
インストールである。ランナーには Homebrew が入っているので、この分岐は CI では一度も実行されない。

実際に落ちた。`NONINTERACTIVE=1` はインストーラが RETURN を待つのを止めるために付けていたが、
**このモードは sudo が既に使えることを前提にする**。まっさらな機体では資格情報がキャッシュされて
おらず、`insufficient permissions to install homebrew to "/opt/homebrew"` で停止した。設計メモには
「Homebrew のインストーラが sudo パスワードを要求する〔対話〕」と書いてあったのに、**実装がその
対話を封じていた**。

対処は `sudo -v` を先に置くこと。sudo は stdin ではなく端末からパスワードを読むので、
`curl | bash` で届いたスクリプトからでも働く。Homebrew を入れる分岐の中だけに置き、既に持っている
機体に不要なパスワードを求めない。

この穴を CI で塞ぐのは容易ではない（ランナーから Homebrew を消して試すことになる）。**塞げない
ことを承知の上で、最初の実機が検証の場になる**と認識しておく方が正直である。
