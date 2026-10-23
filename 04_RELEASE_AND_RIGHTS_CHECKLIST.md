# ClipHarbor – 権利・公開準備・品質チェックリスト v2.0

## A. 権利確認台帳（Rights Register）

Store版で保存対象にする配信元について**1配信元ごと**に以下を埋める。何も記入していない配信元はStore版の保存対象外。

| 必須記録 | 記入欄（サンプルではなく実際の根拠を保管） |
|---|---|
| 提供元・権利者 | 未設定 |
| 許可される動画の範囲（作品/URL形式/API等） | 未設定 |
| ClipHarborでの保存・オフライン閲覧・端末ファイル書き出しの許可根拠 | 未設定 |
| 許諾主体・書面/規約/APIポリシーの参照先 | 未設定 |
| 許諾有効期間・再確認日 | 未設定 |
| 許諾地域・再配布の範囲 | 未設定 |
| Store用の実装条件・除外条件 | 未設定 |
| 必要な認証、API規約、表示義務 | 未設定 |
| Apple審査時に提示できる証憑 | 未設定 |

**注意**: 「動画がインターネット上で見られる」「ログインできる」「取得できるURLがある」「ユーザーが同意欄にチェックした」は第三者からの明示的なダウンロード承認の代わりにはならない。具体的な配信元許諾を確認すること。

## B. 審査適合の設計チェック

- [ ] App Review Guidelines 2.3.1の「隠し機能・未申告機能禁止」に準拠
- [ ] App Review Guidelines 5.2.2の第三者サービス利用許可・証憑を確認
- [ ] App Review Guidelines 5.2.3の第三者音声/動画保存の明示的承認を確認
- [ ] Store版のバイナリに、Personal専用の許諾未確認の動画保存経路が**含まれていない**
- [ ] Store版の表示名、App Store説明、スクリーンショットは実際の機能のみ説明
- [ ] Review Notesで対象となる動画配信元、審査用テスト素材/URL、操作手順を説明
- [ ] 権利元が証憑提出を取り消したら、ストア公開機能を見直す
- [ ] Aloha Browser等のUI・アイコン・ブランド・固有素材をコピーしていない

## C. プライバシーとセキュリティ

- [ ] プライバシーポリシーを公開しApp Store Connectに有効なURLを設定
- [ ] App Privacy申告が実際のSDK、アクセス情報、ログ、収集内容と整合
- [ ] 動画URLの署名クエリ、Cookie、Authorization、完全なRefererを永続化しない
- [ ] Cookieがクロスホスト/リダイレクト時に漏れない
- [ ] DRM、アクセス制限、技術的保護手段を回避しない
- [ ] `WKScriptMessageHandler`入力のスキーム、型、文字数、ホストを検証
- [ ] ファイル名のパストラバーサル対策・容量不足・通信切断時クリーンアップ
- [ ] 保存ボタンの押下前にバックグラウンド取得が開始されない
- [ ] アカウント情報・動画データは本人端末から外部の開発者サーバーへ送信しない（設計どおりなら）

## D. 実機品質

- [ ] 普通のページ表示・戻る・更新
- [ ] 自作テストMP4: 再生を検出、候補表示、保存、オフライン再生
- [ ] 10回連続DLでアプリ固有の回数制限なし
- [ ] ダウンロードのキャンセル/失敗/中断/再試行
- [ ] ファイル共有、削除、ストレージ整理
- [ ] 保存許可のあるHLSテスト配信で動作確認（Apple標準APIの範囲）
- [ ] `blob:`/MSE/DRM/401等で正しい非対応表示
- [ ] iPhoneセーフエリア、文字拡大、ダークモード
- [ ] アプリ更新・Personal版再署名時に保存済動画が消えない（確認とバックアップ）
- [ ] 機密URLがデバッグログ・Git履歴・クラッシュ出力にない

## E. 公開直前

- [ ] Apple Developer Programへ加入
- [ ] Store用Bundle ID、証明書、正規配布署名とアップロード方式を検証
- [ ] Privacy Policy、サポートURL、年齢レーティング、スクリーンショット、説明文
- [ ] 権利資料とReview Notes
- [ ] TestFlight外部テストの審査可能性を理解し、Store版のみ提出
- [ ] 著作権/サービス規約/地域法令について必要に応じ専門家に確認
- [ ] 審査への提出はユーザーが承認する

## 一次情報

- https://developer.apple.com/jp/app-store/review/guidelines/
- https://developer.apple.com/help/app-store-connect/reference/app-privacy/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- https://developer.apple.com/jp/support/app-distribution-in-japan/
