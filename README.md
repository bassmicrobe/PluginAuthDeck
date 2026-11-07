# Plugin Auth Desk

DAWを起動せずに、MacへインストールしたAU / VST3プラグインの認証画面を開くランチャーです。明示的な未認証表示を検出した製品を一覧にまとめ、メーカーの画面で1件ずつ認証できます。

ソースのバージョンは **1.4.0（build 8）** です。配布版は[GitHub Releases](https://github.com/bassmicrobe/PluginAuthDeck/releases)から取得できます。通常の`build.py`はad-hoc署名の開発用アプリを作ります。Developer ID署名とApple公証を行う独立した配布処理は、[公証手順](docs/NOTARIZATION.md)を参照してください。

## できること

- インストール済みAU / VST3とメーカーの認証アプリを一覧に表示する。
- プラグインの画面を独立したホストプロセスで開く。
- 未確認の製品を自動で読み込み、状態ラベル・認証フォーム・プラグイン自身の描画の文字から、対応している未認証表示を調べる。
- 未認証と記録された製品を順番に開き、ユーザーの認証操作後に状態を記録する。
- 自動チェックの中断・再開と、結果のCSV出力を行う。

**すべての製品の認証状態を確実に判定するツールではありません。** 自動確認は画面から取得できる明示的な状態表示などを使います。画像の文字もローカルOCRで確認しますが、再描画できないGPU表示、別プロセスの画面、操作しないと出ない認証表示などは検出できない場合があります。「未判定」「時間切れ」「読み込み失敗」は認証済みを意味しません。認証操作そのものはメーカーの画面で行います。

## 対象環境

- Apple Silicon搭載Mac、macOS 12以降をビルド対象としています。
- ランチャーはarm64、プラグインホストはarm64 / x86_64のUniversalです。**Intel Mac向けのランチャーは含まれません。**
- Intel専用プラグインの読み込みにはRosetta 2が必要です。自動インストールは行いません。
- 対応形式はAU / VST3です。AAX / VST2は対象外です。

プラグイン固有のハードウェア、メーカーのサービス、ライセンス管理ソフト等は別途必要です。すべてのプラグインやmacOSバージョンでの互換性を確認したものではありません。

## ソースからビルドする

Git、Python 3、Xcode Command Line Tools、および`PATH`から実行できるCMake 3.22以上が必要です。リポジトリは[PluginAuthDeck](https://github.com/bassmicrobe/PluginAuthDeck)、アプリ名はPlugin Auth Deskです。

```sh
git clone --recurse-submodules https://github.com/bassmicrobe/PluginAuthDeck.git
cd PluginAuthDeck
python3 build.py
```

JUCEは公式リポジトリのコミット`72782788ce18c2d4d760b28e0921d6ffc6431102`（9.0.2）に固定したサブモジュールです。既存のチェックアウトでは、ビルド前に`git submodule update --init --recursive`を実行してください。GitHubの自動生成ソースZIPにはサブモジュールの中身が含まれないため、Gitでのチェックアウトを使用してください。

アプリは`dist/Plugin Auth Desk.app`へ出力されます。インストールする場合は、アプリとそのホストを終了してから次を実行します。

```sh
python3 build.py --install
```

インストール先は`~/Applications/Plugin Auth Desk.app`です。既存の同アプリがある場合はバックアップを保存して置き換えます。ビルド・インストール手順はDeveloper ID署名やApple公証を行いません。

アプリ内の`Contents/Resources/Source.tar.gz`にも、そのビルド用のソースとJUCEを収録します。このアーカイブからビルドする場合、JUCEのサブモジュール初期化は不要です。

配布用の`scripts/notarize.py`は元アプリを変更せず、独立した作業コピーを署名・公証します。`--prepare-only`で署名まで準備し、`--resume`で同じアプリの申請を続けられます。Accepted後のチケット添付と、最終ZIPの展開後検証まで行います。具体的な配布物の公証状態は、そのrunの検証結果で確認してください。

## 使い方と実行時の注意

操作方法、記録の保存場所、停止方法は[使い方](使い方.md)を参照してください。

プラグインを開くと、第三者のネイティブコードを現在のユーザーと同じ権限で実行します。ホストを別プロセスに分けていますが、**セキュリティサンドボックスではありません**。プラグイン自身の通信やファイルアクセスを制限しません。信頼できるプラグインだけを読み込んでください。

ホスト自身は音声・MIDIデバイスを開かず、オーディオ再生を開始しません。Plugin Auth Deskはライセンスキーやパスワードの収集・自動入力、購入、ライセンスの移動・解除を行いません。読み込んだプラグインやメーカーアプリ自身の動作は、各製品の仕様に従います。

開発・配布ホストともHardened Runtimeを使用し、第三者プラグインの読み込みと実行時の動的コードに必要な2つの例外だけを指定します。ランチャーには例外を付けません。詳細と検証範囲は[Security](SECURITY.md)を参照してください。

セキュリティ上の境界と報告時の注意は[SECURITY.md](SECURITY.md)に記載しています。

## 開発時の検証

次のテストは合成データを使い、インストール済みのプラグインや認証記録を変更しません。

```sh
python3 build_tests.py
python3 model_tests.py
python3 auto_model_tests.py
```

ビルド後、ホストの不正な起動要求への対応も検証できます。

```sh
python3 test_host_requests.py "dist/Plugin Auth Desk.app/Contents/Helpers/AuthPluginHost.app/Contents/MacOS/AuthPluginHost"
```

独自の合成VST3を使う結合テストは[fixtureの手順](tests/fixture/README.md)を参照してください。生成物、ローカルの検査結果、実際のプラグイン一覧・認証記録はGitの管理対象に含めません。

## ライセンス

第一者コードは **AGPL-3.0-only** です。全文は[COPYING](COPYING)を参照してください。JUCEと各依存物のライセンスは[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)にまとめています。

このアプリを再配布するときは、AGPLに従い、対応するソース、ビルドに必要なスクリプト、ライセンス表示へのアクセスを保ってください。実行するだけで、利用者のライセンスキーやサンプル、保有プラグインを公開する必要が生じるという意味ではありません。他社のプラグイン本体・ライセンス・プリセット・サンプルは本リポジトリに含めません。
