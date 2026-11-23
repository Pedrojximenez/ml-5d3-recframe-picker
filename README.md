# 5D Mark III REC frame + video mode picker

Canon EOS 5D Mark III **firmware 1.1.3** の Magic Lantern 用 Lua スクリプト2本です。赤い録画枠と動画モードピッカーだけに切り詰めた交換セットに収録した版を、そのまま公開しています。フルビルド、モジュール、動画プリセットの設定ファイル、カード内の撮影データは含みません。

## 収録ファイルと機能

- `recframe.lua` — REC frame v3.3。録画中、Magic Lantern の 720×480 描画面の周囲に幅6 pxの赤枠を描きます。`Scripts → REC frame status` で動作状態を確認できます。
- `picker.lua` — Mode Picker v3.4.8 の動画専用派生。9つの動画プリセットを一覧から選択し、選択内容を保存して再起動を要求します。プリセットごとの Dual ISO / Recovery ISO 設定ページと診断ログがあります。動画モードから TRASH キーで Film Roll に直行するショートカットは無効です。ログ識別子は `PICKER348V` です。Film Roll に関する保護コードは残っており、完全な機能分離は実機で未検証です。

## 必要な環境と導入

既に 5D Mark III FW 1.1.3 対応の Magic Lantern と Lua モジュールが動くカードが必要です。ピッカーの9モード切替には、対象の `ML/SETTINGS/` 内に対応する動画プリセットと設定が必要です。このリポジトリだけでは起動可能なカードは作れません。

1. カメラの電源を切り、カード全体を別の場所にバックアップしてから、既存の `ML/scripts/recframe.lua` と `ML/scripts/picker.lua` を退避します。Film Roll の状態や未処理データがある場合は、状態を確認してから交換してください。
2. このリポジトリの2ファイルをカードの `ML/scripts/` にコピーします。他の `ML` ファイルや撮影データは上書きしません。
3. Magic Lantern の `Scripts` メニューで両スクリプトの自動起動を有効にします。プリセット別に設定を使うビルドでは、使う各プリセットにも自動起動設定が必要です。交換セットでは `ML/SETTINGS/` と9つの動画プリセットそれぞれに `recframe.LEN` と `PICKER.LEN` を置いています。
4. カードを安全に取り出し、カメラで起動、表示、保存と再起動を確認します。実機での動作と録画結果は、この公開物のオフライン検証だけでは保証できません。

## 使い方

- 録画を開始すると赤枠が現れ、録画を止めると描画しなくなります。
- ピッカーは `Scripts → Mode Picker` から開くか、Live Viewでジョイスティック中央を約1.2秒押して離して開きます。ジョイスティックで移動し、`SET` で選択します。保存後は画面の指示に従って再起動します。
- `Q` またはジョイスティック中央でピッカーを閉じます。`MENU` は Magic Lantern メニューへ移ります。動画モードでの `TRASH` は Film Roll 直行に使いません。
- `Scripts → Picker status` と `ML/scripts/picker_log.txt` で診断できます。ステータスメニューの一部ヘルプ文には元版の TRASH 動作が残っていますが、この派生版の `TRASH_SHORTCUT` は `false` です。

## クレジットとライセンス

このスクリプトは [Magic Lantern プロジェクト](https://www.magiclantern.fm/) の Lua API と、[Danne の 5D Mark III 向け Magic Lantern 派生ビルド](https://github.com/dannephoto/magiclantern_hg_02) を土台とする環境で開発・改変されました。Magic Lantern とその先行開発者、Danne、および関連モジュールの作者に感謝します。Danne がこの `picker.lua` を執筆したという意味ではありません。

このリポジトリの2つの Lua スクリプトは [GNU GPL version 3](LICENSE) で公開します。Magic Lantern 本体や他のモジュールはこのリポジトリに含まず、それぞれのライセンスに従います。
