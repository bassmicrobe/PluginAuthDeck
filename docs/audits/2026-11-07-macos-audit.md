# Plugin Auth Desk macOS監査・修正記録（2026-11-07）

## A. 対象と確認範囲

開始コミットは `36d24fdc5ef807d69681386a8a1492ab378be4b1`、開始時は `main`・変更なし。修正は `codex/macos-audit-20261107` で検証したソース変更です。アプリの一般配布は未実施です。バージョンは1.3.2（build 6）のままです。別途依頼されたGitHubリポジトリdescriptionは反映・再読込確認済みです。

| 項目 | 確認した事実 |
|---|---|
| 構成 | Swift/AppKit/SwiftUIランチャー、C++17/Objective-C++のJUCEホスト、Pythonビルド・公証スクリプト |
| 固定依存 | JUCE 9.0.2、submodule `72782788ce18c2d4d760b28e0921d6ffc6431102`。今回バージョン更新なし |
| 仕様上の対象 | macOS 12以降、arm64ランチャー、arm64+x86_64ホスト。Intel Mac用ランチャーは対象外 |
| 実機 | Apple M5、メモリ32 GiB、macOS 27.2（26B123）、arm64ネイティブ |
| ツール | Xcode 27.2（27B52）、macOS SDK 27.2、Swift 6.4.2（アプリはSwift 5言語モード）、CMake 4.3.2、Python 3.14.5 |
| アプリ種別 | 通常ウィンドウ型。最後のウィンドウを閉じると終了。メニューバー常駐、ログイン項目、自動更新なし |
| 主な機能 | AU/VST3の一覧・検索、お気に入り、独立ホストで画面表示、未認証の明示表示検出、手動記録、順次確認、自動チェックの中断・再開、CSV |
| 保存 | Application Support内の一覧・製品カタログ・認証記録・セッション・自動チェック、UserDefaultsのお気に入り。DB/Keychain/パスワード保存なし |
| 配布 | 通常buildはad-hoc署名のローカル開発用。別スクリプトにDeveloper ID/Hardened Runtime/公証手順あり。Mac App Store配布は現要件にない |
| 権限境界 | プラグインは同一ユーザー権限の別プロセス。Sandboxではない。ランチャー独自の通信・HTTP待受・課金・ログインなし |
| OS権限 | 第一者コードはマイク・カメラ・画面収録・入力監視・他アプリのAccessibility制御・Automationを要求しない。ホスト内の画面要素のみ検査。第三者プラグイン自身の権限・通信は別境界 |
| 検証データ | 一時ディレクトリ、合成JSON/Mach-Oヘッダー、独自合成VST3。実プラグインの実行、実認証、実利用者データの変更なし |

監査項目の分類は以下のとおりです。「確認した範囲では指摘なし」は未実施の実機条件まで保証するものではありません。

| 依頼の監査項目 | 分類 | 確認範囲・限界 |
|---|---|---|
| ①機能・業務処理 | 指摘あり | CSV失敗時動作、キャッシュ保存、認証記録の形式/製品/版分離、順次確認、正常/拒否経路 |
| ②起動・終了・復帰 | 指摘あり | 特殊ファイルによる起動停止、終了状態機械、実UIの起動/終了、fixtureホスト回収。実スリープ/画面ロックは未確認 |
| ③UI・日本語 | 指摘あり | アプリ情報の版表示、空状態、検索、貼り付け、タブ・キーボード操作。IME変換途中のEnterは未確認 |
| ④アクセシビリティ | 指摘あり | AXツリーで検索解除が「閉じる」と判明、読み上げ名を修正。VoiceOver音声操作・Inspector・設定組合せ全体は未確認 |
| ⑤OS権限・Sandbox | 確認した範囲では指摘なし | plist/entitlements/第一者コードを照合。直接配布のためSandbox無効だけを不具合扱いしない。第三者権限ダイアログは未確認 |
| ⑥セキュリティ | 指摘あり | ホスト要求の深いJSON、不正UTF-8、特殊ファイル、署名準備時の隔離属性削除。独自サーバー/セッション認証は対象外 |
| ⑦保存・整合性 | 指摘あり | 新旧自動チェック混在、特殊ファイル、サイズ境界、破損保護、競合、atomic保存、旧形式読込。実容量不足/電源断は未確認 |
| ⑧通信・非同期 | 指摘あり | 自動チェック保存と子プロセスの順序、停止/再開、遅延・消える未認証表示。外部API・同期は第一者コードに存在せず対象外 |
| ⑨性能・メモリー | 確認した範囲では指摘なし | 合成5,000件の前後比較、限定した実プロセス観測。長時間リーク、GPU、電力、Instrumentsは未確認 |
| ⑩OS・CPU・周辺機器 | 未確認 | 本体/ホストのアーキテクチャと最低OS設定を検査し、macOS 27.2 arm64で検証。macOS 12実機・Rosettaプラグイン・外付機器は未確認。ホスト自身は音声/MIDIを開始しない |
| ⑪ビルド・署名・公証 | 指摘あり | Release成果物、ad-hoc署名、リソース、隔離属性保持を確認。Developer ID・新規公証・ダウンロード初回起動は未実施 |
| ⑫更新・削除・復旧 | 確認した範囲では指摘なし | 合成appで更新失敗/旧版保持/rollback、旧チェック形式移行。利用中appの置換・削除は実施せず、実配布物更新は未確認 |
| ⑬ログ・保守 | 指摘あり | バージョン表示、保存失敗通知。依存版固定とソース同梱を確認。クラッシュシンボル保管/世代保持上限は改善余地 |
| ⑭技術固有 | 確認した範囲では指摘なし | SwiftUI更新のmain queue、タイマー停止、親の寿命監視、UI検査の入力/保護要素除外。Electron/Tauri/WebView/AI/課金は対象外 |

## B. 確認できた不具合と修正結果

### AUD-01：特殊ファイルで起動・保存・ホスト要求読込が停止（中）

期待：壊れた保存先・メタデータを拒否し、アプリと停止操作が応答し続けること。実際：書き手のないFIFOを読み込む`FileHandle`、書込み用lockのopen、JUCEのrequest openが待ち続けました。inventory/license/autoscanは専用プロセスで2秒timeout、実HostはFIFOとsymlink FIFOで1.5秒停止し、追加テストも10秒timeoutになりました。これは当該ユーザーの可用性障害であり、権限昇格・遠隔からの侵入は確認していません。

[Inventory.swift:11](../../Inventory.swift#L11)の共通readerで非ブロッキングopen、同fdへの通常ファイル確認、容量上限・読込中のサイズ変化確認を実装。[LicenseState.swift:214](../../LicenseState.swift#L214)、[AutoScan.swift:271](../../AutoScan.swift#L271)の状態・lockにも適用。[Host.cpp:92](../../Host.cpp#L92)はsymlinkも拒否します。通常のプラグイン情報ファイルへのsymlinkは既存互換性を維持します。

回帰は通常ファイル、ディレクトリ、FIFO、リンクFIFO、巨大sparseファイル、境界サイズを確認。拒否時に認証記録やホスト状態が勝手に生成されないことも確認。修正済みです。

### AUD-02：新しい自動チェックの開始失敗で旧結果が一部消失（中）

期待：新しい全workerを開始できるか、旧結果をそのまま保持すること。実際：旧2製品の結果を保存後、worker-1の有効JSONへ改行を追記して競合を作り新2製品を開始すると、worker-0だけ更新され、再読込後「旧結果1件＋新未処理1件」が混在して再開可能になりました。自動チェックの結果・再開対象に影響し、メーカーのライセンスには影響しません。

[AutoScan.swift:315](../../AutoScan.swift#L315)で新実行IDのディレクトリに全workerを保存し、全保存成功後だけ`current-run.json`をatomic切替。manifest/各workerのロック・競合検知を行います。[AutomaticScanner.swift:137](../../AutomaticScanner.swift#L137)から利用します。途中失敗、同時controller、旧形式移行、破損/未知version/不正パス/参照先欠落を検証。失敗時は旧結果のバイト列を保護しホストを起動しません。

修正済み。旧世代は復旧用に残します。旧版は新manifestを認識できないため最新進捗を再開できません。[使い方.md:77](../../使い方.md#L77)に保存構成と戻す際の注意を追記しました。認証記録の形式は変更していません。

### AUD-03：サイズ制限内の深いJSONでJUCE解析がクラッシュ（中）

期待：不正requestをプラグイン実行前に拒否すること。実際：同じJUCE 9.0.2の`JSON::parse(File)`をリンクした隔離プロセスで、60,001 bytes・30,000段のJSONがSIGSEGV。従来の65,536 bytes制限内で、Hostではwatchdog開始前にそのparserへ渡していました。実Hostをクラッシュさせた結果と同一視せず、parser再現と修正後実Host拒否を区別します。

[Host.cpp:8](../../Host.cpp#L8)で32段の事前構造上限、NUL/不整合拒否、UTF-8検証と上限付きreadを追加。引用文字列・escapeを考慮し、その後にJSON構文解析を行います。policy30ケース、実Host12拒否ケースで確認。正常日本語は保持、不正入力はプラグイン未読込・heartbeatなしで拒否。修正済みですが、JUCE全体の既知問題を修正したわけではありません（E参照）。

### AUD-04：署名準備時に隔離属性まで削除（低）

`build.py`、公証準備、fixtureの`xattr -cr`は、元コピーにquarantineがある場合それも削除します。署名に不要なFinderInfo/ResourceForkだけを除去すべき条件で過剰でした。[signing_metadata.py:15](../../scripts/signing_metadata.py#L15)へ集約し、この2属性だけを除去。symlink・非通常ファイルを検査してから処理します。実xattrテストでquarantine/その他属性保持と、symlink拒否時の無変更を確認。ソースアーカイブにも新スクリプトを収録。修正済みです。

Appleの[QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html)で署名を妨げる2属性を確認しました。Gatekeeper/SIP/OS権限は無効化していません。

### AUD-05：キャッシュの書込上限不一致と無言のI/O失敗（低）

製品名カタログは読込4 MiB上限なのに書込無制限で、受理可能な4,096件の長い名前により次回読めないファイルへ上書きできました。[Inventory.swift:217](../../Inventory.swift#L217)で書込にも同じ上限を適用し、超過時は元ファイルを保持します。

一覧は起動時の無制限readと保存失敗の握りつぶしがありました。[main.swift:116](../../main.swift#L116)で16 MiBの読み書き上限と独立した画面エラーを実装。壊れたキャッシュ・特殊ファイル・保存先がディレクトリの失敗、メモリ内一覧保持、保存復旧時のエラー解除と実ファイル内容を検証。認証記録をキャッシュ再生成で消しません。修正済みです。

### AUD-06：CSV保存失敗でも古い結果を開く（低）

期待：CSVを生成できなければ失敗を表示し、以前のファイルを今回の結果として開かないこと。実際：UIは`writeReport()`の失敗に関係なく`NSWorkspace.open`を呼んでいました。[AutomaticScanner.swift:349](../../AutomaticScanner.swift#L349)がBoolを返し、UIは成功時だけ開くよう修正。書込み不可の専用ディレクトリで失敗通知・元CSV保持、CSV式注入・Unicode・引用符を検証。修正済みです。

### AUD-07：検索解除・お気に入り操作の読み上げ名が不明確（低）

実AXツリーで検索解除が「閉じる」、お気に入りフィルタが「お気に入り」となり、操作目的が区別できませんでした。[main.swift:642](../../main.swift#L642)で「検索を消去」「お気に入りだけ表示」、追加/削除ボタンには目的と登録状態を指定。見た目の好みではなく操作名の修正です。AXツリー確認とVoiceOver音声操作は別で、後者は未実施です。

### AUD-08：アプリ情報が実バージョンと一致しない（低）

実ダイアログが固定値「Plugin Auth Desk 1.3」を表示し、1.3.2 build 6と照合できませんでした。[main.swift:1015](../../main.swift#L1015)でBundleのversion/buildを使用し、arm64ランチャーとUniversalホストの説明を区別しました。機能停止ではありませんが障害報告・版確認に影響するため修正しました。

## C. 検証結果

既存の修正前チェックは成功しました：build21、notarize16、model83、automatic55＋CSV12、inventory36、license54、autoscan51、workflow/lifecycle。修正時に追加した回帰テストのREDは上記の不具合再現です。並行編集中にSwiftの「input file was modified during the build」が発生しましたが、製品の実行不具合や修正前の失敗ではありません。編集完了後の最終確認は成功しました。

| 検証 | コマンド・方法 | 結果 |
|---|---|---|
| 一覧 | `xcrun swiftc Inventory.swift inventory_tests.swift -o /tmp/plugin-auth-audit-inventory` → 実行 | 52ケース成功 |
| 認証保存 | `xcrun swiftc Inventory.swift LicenseState.swift license_tests.swift -o /tmp/plugin-auth-audit-license` → 実行 | 59ケース成功 |
| workflow | Inventory/LicenseState/ActivationWorkflowと`workflow_tests.swift`をコンパイル・実行 | snapshot、製品分離、終了待ち、二重操作、遅延callback成功 |
| lifecycle | `SessionLifecycle.swift lifecycle_tests.swift`をコンパイル・実行 | crash、遅延/回復heartbeat、明示停止、error-close成功 |
| 自動チェック状態 | `xcrun swiftc Inventory.swift AutoScan.swift autoscan_tests.swift ...` → 実行 | 51ケース成功 |
| scanner結合 | `python3 auto_model_tests.py` | 82チェック＋FIFO4＋CSV12成功 |
| model結合 | `python3 model_tests.py` | 91チェック成功。保存失敗後の復旧と実ファイル内容も確認 |
| ビルド/更新 | `python3 build_tests.py` | 23ケース成功。コピー/署名/更新/rollback失敗時の旧版保護を含む |
| 公証手順（模擬） | `python3 scripts/notarize_tests.py` | 16ケース成功。実Apple申請ではない |
| Host policy | `xcrun clang++ -std=c++17 -DPLUGIN_AUTH_HOST_POLICY_TEST Host.cpp ...` → 実行 | 30ケース成功 |
| 実Host入力拒否 | `python3 test_host_requests.py build/AuthPluginHost_artefacts/Release/AuthPluginHost.app/Contents/MacOS/AuthPluginHost` | 12ケース成功、プラグイン未実行 |
| 状態検出 | `xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa LicenseProbe.mm license_probe_tests.mm ...` → 実行 | 61状態文字列＋保護/入力/不可視要素除外、循環/深さ/時間制限、main thread制約成功 |
| Release fixture | CMakeで独自VST3をRelease/arm64ビルド。`verify_installed_host.py --host ... --variant normal/delayed/transient` | 3方式成功。検出3.380秒、遅延表示5.363秒、一過性候補消去5.372秒。全てquit.requestで終了0、子残留なし |
| Release app | `python3 build.py`（installなし） | 成功。dist/Plugin Auth Desk.app生成、修正ソースと署名用helperの同梱一致を確認 |
| 静的差分 | `git diff --check`、全変更レビュー、別担当による独立レビュー | 成功。今回変更に起因する具体的な重大回帰の指摘なし。秘密値を出力・追加していない |

fixtureの秒数はその実行での観測時間で、起動性能目標や修正による高速化率ではありません。公開配布用appは存在せず、既存の~/Applicationsおよび/Applicationsにも対象appはありませんでした。

### macOS上の画面操作

ソースのUIを使用し、一覧・管理アプリ取得と保存先だけを合成fixtureへ差し替え、専用Bundle IDの検証appで実行しました。通常ユーザーのプラグイン一覧・認証データを変更しないための分離です。この検証を未変更の配布用ランチャーや実メーカー製品のE2Eと同一視しません。

修正前UIで空状態、カテゴリ切替、日本語/全角/絵文字の貼り付け、検索解除、Tab移動、About、Cmd-Q終了を確認。文字列の直接キー入力は自動操作ツールで非ASCII文字が欠落したため、日本語入力成功の根拠は貼り付け結果のみです。IME変換の確認済みとはしていません。

修正後の専用UIアプリで、自動チェック開始→1/1完了・未認証1件→順次確認→手動確認保存→未認証一覧0件・動作中0件を確認しました。保存したJSONは1件・status=activated・source=userで画面と一致しました。これは合成製品の記録操作で、実ライセンス認証を行ったものではありません。Unicode貼り付けと「検索を消去」のAX名、お気に入りの追加/削除名と登録状態、Aboutの1.3.2 (build 6)表示を実UIで確認しました。終了・再起動後も自動チェック結果、認証済みの手動記録、お気に入りが復元されました。さらにホストを開いたままCmd-Qで終了し、ランチャーと所有ホストの両方が終了して残留しないことを確認しました。

### 生成したアプリの検査

- `codesign --verify --deep --strict`：成功。`codesign -dvvv`：ad-hoc、TeamIdentifierなし、Hardened Runtimeフラグなし。通常の開発ビルドの仕様どおりで、Developer ID検査の代用にはなりません。
- `codesign -d --entitlements -`：本体/ホストとも付与entitlementsなし。配布スクリプトのhost用例外と、このローカル成果物の実entitlementsを区別しています。
- `lipo -archs`：ランチャーarm64、ホストx86_64/arm64。`vtool -show-build`：全sliceのminos=12.0、sdk=27.2。
- `spctl --assess --type execute -vv`：rejected（終了3）。`xcrun stapler validate`：チケットなし（終了65）。公証済み一般配布物ではありません。
- コピー時の再署名によりビルドディレクトリのHostとパッケージ内Hostの全体hashが異なったため、最終パッケージのHostに対して12入力拒否ケースとfixture3方式を再実行し、全成功を確認しました。最終パッケージのfixture観測時間は通常3.203秒、遅延5.105秒、一過性5.236秒、全子プロセス終了0です。
- Source.tar.gzの4,879収録ファイルから、変更した主要Swift/C++/Pythonファイルを現在の作業ツリーと比較し一致。秘密情報や実利用者データを含む再帰的なプロジェクト全体収録はしていません。
- 署名検査、公証ticket、Gatekeeper評価、専用UI操作は別々に検証しています。隔離属性削除や保護の無効化は行っていません。

### 性能計測

同じ合成5,000件（JSON 1,527,231 bytes）で、修正前コミットと修正後を各7回交互に測定。Apple M5/10コア/32 GiB/macOS 27.2、`-O -swift-version 5 -target arm64-apple-macosx12.0`。専用保存先、refreshOnLaunch=false、メーカーアプリ列挙とお気に入り読込だけをベンチコピーで空にしました。7種類×10回の検索は全14試行で件数・集計が一致しました。

| 指標 | 修正前 | 修正後 |
|---|---:|---:|
| 初期化中央値 | 68.803 ms | 60.018 ms |
| 初期化の範囲 | 54.462–77.850 ms | 52.405–149.459 ms |
| 70検索合計中央値 | 952.172 ms | 1,027.350 ms |
| 同範囲 | 841.729–2,090.446 ms | 832.756–1,291.875 ms |
| 最大RSS中央値 | 27.359 MiB | 27.703 MiB |
| 全試行中の最大RSS | 27.719 MiB | 29.531 MiB |

並行ビルド等による時間のばらつきが大きいため改善・悪化率は断定しません。RSSはfixture生成から検索までのプロセスピークでGUI常駐値ではありません。別途、修正後の専用UIアプリ（合成1製品・チェック完了後）を1秒間隔5回観測し、psのCPU表示は全回0.0%、RSSは114,800〜114,960 KiB（約112 MiB）、数値FDは全回3でした。短時間の観測であり長時間リークや省電力効果は判断できません。全測定値と再現条件はローカルの検証用記録（`RESULTS.md`、`samples.json`、`run.py`）に保存し、リポジトリには測定条件と集計値を記載しています。

## D. 改善提案（確定不具合とは分離）

- JUCE 9.0.5等のセキュリティ修正版へ、依存変更とUniversalホスト互換性を確認して更新する。今回の第一者request境界対策を、JUCE内部の全parser/画像/XML対策とみなさない。
- 自動チェックの旧実行と過去セッション/バックアップの保持期間・件数を仕様化し、利用者が選べる削除/復旧UIを用意する。今回は結果保護を優先して旧世代を保持したため、実行数に応じて保存量が増える。
- main.swiftのモデル/画面/アプリ起動の分割、定期CI、UIテスト、coverage収集を整備する。現在のstandaloneテストからプロジェクト全体80%のcoverageは確認できない。重複した静的チェックで代用しない。
- ReleaseのdSYMと実配布物hashを保存し、クラッシュレポートとの対応を残す。今回のローカル成果物には公開リリース識別を新設していない。
- 成功通知の色、任意のエラーの復旧導線、カタログ上限到達時の削減方針は追加改善の余地がある。未測定の使いやすさ・省電力効果は断定しない。

## E. 未確認・未解決事項と利用・配布の判断

| 未確認・残件 | 理由と次に必要な確認 |
|---|---|
| JUCE全体のセキュリティ更新 | 固定9.0.2のまま。[9.0.4告知](https://forum.juce.com/t/juce-9-0-4-8-0-16-security-7-0-13-security/69682)、[9.0.5告知](https://forum.juce.com/t/juce-9-0-5-8-0-17-security-7-0-14-security/69810)に文字列/JSON/XML/画像等の修正がある。今回再現したrequest経路は修正したが他の到達可能性・影響は現時点ではわかりません。依存更新と実製品互換性検証が必要 |
| Developer ID・公証・配布初回起動 | 新規提出は依頼で未許可。手順確認/模擬テストとローカルad-hoc検査のみ。実証明書、Accepted対象hash、staple、ダウンロードした同一成果物を要する |
| macOS 12等/Intel・Rosetta | 実行環境は27.2 arm64のみ。[Apple説明](https://support.apple.com/en-us/102527)では一般Rosetta対応は27以前、28以降は限定用途。将来OSのIntelプラグイン対応を保証しない。別OSと合成x86_64プラグインが必要 |
| Privacy manifest/SDK申告 | 第一者アプリは独自データ送信を実装せず、App Store配布要件は現対象外。将来の配布先・追加SDKに応じた申告要件の網羅判定は未確認。配布手段確定時に公式適用条件を再確認する |
| 実プラグイン・メーカーサービス | 許可された専用ライセンス/機器/テストアカウントなし。実認証、ネットワーク断、課金、第三者権限拒否/再許可、AUメーカー互換性は未確認。サーバーコードも監査対象として渡されていない |
| 実機条件 | スリープ/ロック復帰、外部ディスプレイ切断、VoiceOver、アクセシビリティ各設定、IME確定、ライト表示、最小サイズ、全画面・倍率の全組合せは未確認。ユーザーの通常環境設定を変更していない |
| 永続化限界 | 模擬失敗・競合・破損・旧形式・途中開始失敗は確認。実ディスク満杯、ネットワーク保存先切断、電源断時のfsync耐性は未確認 |
| 性能限界 | 合成データと限定観測のみ。長時間のメモリ/FD/スレッド増加、Instruments、電力/GPU、全製品のタイムアウト妥当性は未確認 |
| 更新・復旧 | 合成appのテストのみ。実インストール・公開配布・新規公証・証明書作成/失効は行っていない。新方式自動チェック進捗を旧版では再開できない |

Appleの[公証説明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)と[Library Validation例外](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)を照合し、第三者プラグインを読むホストだけの例外という構成を確認しました。App Sandbox、Hardened Runtime、公証、TCCの許可は別々の仕組みです。

ローカル成果物は `dist/Plugin Auth Desk.app`、検証ログは専用の一時ディレクトリに保存しました。成果物SHA-256はローカルの `artifact-hashes.json` に記録しています。生成物と生の検証ログはリポジトリに収録していません。

現時点の判断：今回のローカル環境・合成データで確認できた不具合に修正を実施しました。一般配布可能性、全macOS/実プラグイン互換性、外部メーカーサービス、アプリ全体の安全性を保証する監査ではありません。上記残件を確認するまで、公証済みの配布版が完成したとは扱えません。
