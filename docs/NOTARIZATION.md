# Developer ID署名とApple公証

`build.py`はローカル開発用のad-hoc署名アプリを`dist/Plugin Auth Desk.app`へ作ります。配布用の処理は`scripts/notarize.py`に分離しています。この文書は手順の説明であり、特定のバージョンの公証完了やGitHub公開を示すものではありません。

## 前提

- 対応する秘密鍵を持つ、有効なDeveloper ID Application証明書。
- 明示する証明書のSHA-1、署名用キーチェーンのパス、Developer Team ID。
- 同じチーム用に設定済みの`notarytool`キーチェーンプロファイル。
- Xcodeのコマンドラインツール、Python 3、Appleへのネットワーク接続。

証明書やプロファイルの値をリポジトリへ書き込まないでください。パスワード、API秘密鍵、`.p12`はスクリプトの引数にも渡しません。キーチェーンの解除や認証情報の登録は、macOS／Appleの正規の画面や安全な対話操作で済ませてください。スクリプトはキーチェーン設定を変更しません。

`--keychain`は署名鍵を選ぶための指定です。公証の`--profile`は、notarytoolの通常のキーチェーン検索対象から取得します。両者のキーチェーンが同じである必要はありません。

## 署名まで準備する

まず`python3 build.py`で対象ソースをビルドします。次の環境変数は、実行する環境で選んだ値を設定してください。

```sh
python3 scripts/notarize.py \
  --identity "$DEVELOPER_ID_SHA1" \
  --keychain "$SIGNING_KEYCHAIN" \
  --profile "$NOTARY_PROFILE" \
  --team-id "$DEVELOPER_TEAM_ID" \
  --prepare-only
```

既定では`results/notarization/run-.../`を新規作成し、元の`dist`アプリをコピーします。元アプリと`~/Applications`の既存アプリは変更せず、アプリやプラグインも起動しません。必要なら`--source-app`と`--output-root`で入出力先を指定できます。

ホストを先にDeveloper ID・Hardened Runtime・安全なタイムスタンプ付きで署名します。ホストに許可する例外は、異なる提供元のプラグインを読み込むための`com.apple.security.cs.disable-library-validation`だけです。ランチャーに例外は付けません。その後、厳密な署名検証、各アーキテクチャ、署名証明書、Team ID、runtime、タイムスタンプ、entitlementsを確認します。

ランチャーはarm64、ホストはarm64 / x86_64です。配布ZIPはランチャーに合わせて`PluginAuthDesk-macOS-arm64-v<version>.zip`と命名します。Universalアプリとしては配布しません。

署名時に鍵へのアクセスが待ち続ける場合、コマンドは時間制限で終了し、作業コピーとログを残します。安全な操作で鍵へのアクセスを解決した後、表示された`RUN_DIR`を`--resume ... --prepare-only`へ渡すと準備を再開できます。未完了の準備を再開すると、以前の作業コピーをrun内の`failed-preparation-...app`へ退避し、内容が変わっていない元ビルドを新規コピーして、ホストから署名し直します。中断されたcodesignの一時ファイルを次の署名へ混入させないためです。コピー途中や署名検証中の中断でも同様です。元ビルドが変わった場合は、新しいrunを作成してください。申請IDを保存したrunへ、この再署名処理を適用することはありません。

## 署名後の確認と申請

準備したコピーを対象に、必要な合成プラグインの互換性テストなどを行います。[fixture手順](../tests/fixture/README.md)を参照してください。このスクリプト自体はテスト用を含めてプラグインを起動しません。

Hardened Runtimeを使用するため、JITや動的コード生成などを必要とする製品は読み込めない場合があります。広い例外を一括で追加せず、再現した要件と影響範囲を確認してから検討してください。別プロセス化と署名は、第三者プラグインを封じ込めるsandboxを提供するものではありません。

準備したアプリを変更せず、同じrunで申請を続けます。

```sh
python3 scripts/notarize.py --resume "/absolute/path/to/RUN_DIR"
```

申請ZIPを作成し、送信前に状態を保存します。Appleが返した申請IDを保存してから、同じIDを待機します。待機は1回最大10分で、タイムアウトしてもApple側の処理は続きます。完了していなければ同じ`--resume`を実行してください。保存済みのIDがある場合は再送しません。

送信自体が中断され、IDを保存できなかった場合も自動で再送しません。使用したプロファイルの`notarytool history`などで今回の送信を確認し、対応するIDが確定した場合に限って復旧します。

```sh
python3 scripts/notarize.py --resume "/absolute/path/to/RUN_DIR" \
  --submission-id "CONFIRMED-SUBMISSION-UUID"
```

Acceptedのログに記載された申請IDとZIPのSHA-256が一致することを確認してから進みます。拒否・不明・通信失敗ではstapleせず、ログと作業データを保持します。署名後のアプリを修正した場合は、既存runを再署名して再利用せず、新しいビルドとrunで申請してください。

## 配布物の検証

Acceptedを確認したアプリにチケットを添付し、署名・チケット・Gatekeeper評価を検証してから最終ZIPを作ります。さらに、そのZIPを別ディレクトリへ展開し、同じ検証を繰り返します。展開後のGatekeeper評価が`Notarized Developer ID`であることも確認します。

全検証成功後に、最終ZIPのSHA-256を`.zip.sha256`へ記録し、`COMPLETE=...`を表示します。Appleのログにある申請ZIPのハッシュと、チケット添付後の最終ZIPのハッシュは異なり得ます。GitHubへの公開や既存アプリへのインストールはこのスクリプトでは行いません。

run内の`state.json`、標準出力・標準エラー、コマンドの終了コード・タイムアウト記録を調査に使えます。これらはローカルパスや証明書識別情報等を含み、`results/`としてGitから除外されています。未加工のログやrun全体を公開しないでください。

合成データだけで状態遷移・再送防止・ZIP構造を検証するには、`python3 scripts/notarize_tests.py`を実行します。このテストはAppleへ送信せず、実際の署名も行いません。

## 公式資料

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
