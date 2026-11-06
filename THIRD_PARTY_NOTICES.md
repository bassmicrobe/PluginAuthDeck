# Third-party notices

Plugin Auth Deskの第一者コードは **AGPL-3.0-only** です。ライセンス全文は[COPYING](COPYING)に収録しています。第三者のソースは、それぞれに付随するライセンス・著作権表示に従います。

## JUCE

- 提供元: [JUCE公式リポジトリ](https://github.com/juce-framework/JUCE)
- バージョン: 9.0.2
- 固定コミット: `72782788ce18c2d4d760b28e0921d6ffc6431102`
- ライセンス: AGPL-3.0-only またはJUCE商用ライセンス。本プロジェクトはAGPLの条件を使用します。
- 正式な説明: [JUCE/LICENSE.md](JUCE/LICENSE.md)
- 依存物の一覧: [JUCE/JUCE.spdx.json](JUCE/JUCE.spdx.json)

JUCEはGitサブモジュールで取得します。アプリのソースアーカイブにはJUCEソースと各依存物のライセンスを含めます。アプリのResourcesには`JUCE-LICENSE.md`と`JUCE.spdx.json`も収録します。

## JUCEに含まれる主なSDK

| SDK | 固定版のライセンス | ライセンス本文 |
| --- | --- | --- |
| Steinberg VST3 SDK 3.8.0 | MIT | [LICENSE.txt](JUCE/modules/juce_audio_processors_headless/format_types/VST3_SDK/LICENSE.txt) |
| Apple AudioUnitSDK 1.1.0 | Apache-2.0 | [LICENSE.txt](JUCE/modules/juce_audio_plugin_client/AU/AudioUnitSDK/LICENSE.txt) |

VST3 SDKの著作権・MITライセンス表示を保持してください。VST3 SDK自体の条件とは別に、JUCEを組み込んだ本アプリには上記のAGPL条件が適用されます。[SteinbergのライセンスFAQ](https://steinbergmedia.github.io/vst3_dev_portal/pages/FAQ/Licensing.html)も参照できます。

上表はJUCEの全依存物を列挙したものではありません。画像、フォント、圧縮などのライブラリや、今回のホストでは使わないSDKもJUCEソースに含まれます。正確なバージョン、ライセンス、収録場所はSPDX一覧と各ソースの表示を参照し、再配布時にも保持してください。

## ビルド環境と利用者のプラグイン

Python、CMake、Xcode Command Line Toolsは利用者のビルド環境から使用します。Xcode/macOS SDK全体や、利用者がインストールしたプラグイン本体、ライセンスファイル、プリセット、サンプルは本プロジェクトの配布物に含めません。JUCE内のApache-2.0のAudioUnitSDKソースは、Xcode/macOS SDK全体とは別の配布物です。

対応形式やメーカーアプリ名は互換性・操作方法の説明のために使用しています。各製品・商標はそれぞれの権利者に帰属します。本プロジェクトと各メーカーの提携や推奨を示すものではありません。

## ソースとバイナリの再配布

AGPL本文、第一者ソース、固定したJUCEソース、必要なビルド・インストールスクリプトと第三者のライセンス表示を保持してください。バイナリを提供する場合は、そのバージョンに対応するソースを受領者が入手できるようにします。異なる条件でJUCEを利用・配布する場合は、[JUCEの正式なライセンス](https://github.com/juce-framework/JUCE/blob/72782788ce18c2d4d760b28e0921d6ffc6431102/LICENSE.md)を確認してください。
