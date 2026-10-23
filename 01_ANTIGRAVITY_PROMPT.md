# Antigravity用マスタープロンプト – ClipHarbor v2.0

以下をAntigravityのAgentチャットへ全文入力してください。

---

あなたはSwiftUI、WebKit、AVFoundation、iOSセキュリティ、GitHub Actions、App Store Connectに詳しいシニアiOSエンジニア兼テックリードです。このワークスペース内の**既存のClipHarborを改修**してください。開発端末はWindows PCのみで、iOSビルドはGitHub ActionsのmacOSランナーを使います。

## 必ず守る優先順位

**P0 – Personal版で実用的な動画ダウンロードを実現することが最優先です。**
- WKWebView内で再生した動画を認識し、取得できる正当な動画URLを候補として表示。ユーザーが選択・確認して端末に保存。
- MP4/MOV/M4V等の直接ファイルと、Apple標準APIで許可されたHLSのオフライン保存を扱う。
- 回数制限、アプリ内課金、広告、クラウドアップロードは設けない。
- 動画再生ができてもダウンロードできないケースを適切に扱い、成功可能性を偽らない。

**P1 – 将来の一般公開に耐える設計。**
- 同一リポジトリ内に、明示的に分離した`Personal`と`Store`の2つのビルド構成を導入する構想。機能実装とビルド検証を段階的に行う。
- `Store`版では、権利資料で第三者からの明示的承認が確認できる配信元、ユーザーが権利を持つファイル等のみ保存可能にする。単なる「ユーザーが権利を持つ」チェックボックスだけで5.2.3に適合すると主張しない。
- Apple審査を欺くための隠しスイッチ、審査用アカウント判定、リモートフラグでの後出し機能解放は禁止。配布用バイナリから不適合機能を**コンパイル時に取り除き**、Review Notesで全機能を開示する。
- 個人版をApp Store/TestFlightへそのまま提出しない。App Store向けアーカイブ・署名フローは個人用`unsigned IPA`とは別に構成する。

## 参照必須資料

1. `00_START_HERE.md`
2. `02_PRODUCT_SPEC.md`（**唯一の要件定義の正本**）
3. `03_WINDOWS_BUILD_GUIDE.md`
4. `04_RELEASE_AND_RIGHTS_CHECKLIST.md`
5. `05_CHANGELOG_V2.md`
6. 既存`ClipHarbor/` Swiftコード、Xcodeプロジェクト、`.github/workflows/build-ios-unsigned.yml`

## 厳守する実装制約

- iOS 17+、SwiftUI、WKWebView、URLSession、AVFoundation。Apple公開APIのみ。XcodeをWindowsローカルで動かせるとは仮定しない。
- 動画検出はDOM（video/source、play/loadイベント）・PerformanceObserver等の**WebKitが許す範囲**で実装。再生中のすべての動画配信トラフィックを監視できるとは断言しない。
- `blob:`、MSE内部のバッファ、DRM（FairPlay等）、認証トークンの抽出、アクセス制限の回避は対応対象外。汎用ブラウザの標準的なHTTP(S)通信以外の、サイト別の非公開APIや脆弱性を使わない。
- 動画候補に対するHEAD要求はサーバーのHEAD非対応も考慮し、必要時はGETのレスポンスヘッダから検証。巨大ファイルを二重ダウンロードしない。HTTPリダイレクトとCookie/Authorization情報の漏えい対策を必須にする。
- Cookie、Referer、User-Agentの取り扱いはセキュリティ設計に従う。元URLに期限付きトークンが含まれ得るので、**ソースURLを平文のUserDefaults・履歴DB・分析ログに保存しない**。既存の`SavedVideo.sourceURLString`を優先修正する。
- HTTPエラー・ストレージ不足・キャンセル・中断・ファイル破損・背景移行に対応し、再生・削除・共有が確実に動作することを重視する。
- HLSは`AVAssetDownloadURLSession`で対応する配信のみ扱う。MP4変換やあらゆるHLSの保存を約束しない。
- ユーザーがダウンロード操作をしなければ保存を開始しない。
- 第三者コンテンツの権利・各サービスの契約条件を尊重する。個人版だから自由に無断ダウンロードしてよいという設計・説明にしない。
- 認証情報、Apple ID、APIキー、署名秘密鍵、実動画の認証URLをAgentチャット・リポジトリ・Actionsログに表示しない。
- GitHubへのリポジトリ新規作成、公開、push、秘密情報登録、Appleへの提出は**事前にユーザーの明示的承認**を得る。

## 作業計画（段階完了制）

### Phase 0 – 既存コード監査
- SwiftコードとXcode設定を全文読む。コンパイル上の問題、責任分離の問題、重大なセキュリティリスクを列挙。
- とくに既存`DownloadCenter.swift`のソースURL平文保存、Cookie引き継ぎ、URLリダイレクト、失敗後メタデータ整合、バックグラウンド復元を評価。
- 実装済み・未実装・未検証を分ける。最初の回答に、修正計画とテスト方針を示す。

### Phase 1 – **Personal版クラウドビルドを確実に成功**
- まず既存SchemeでGitHub Actionsから`CODE_SIGNING_ALLOWED=NO`コンパイルし、`Payload/ClipHarbor.app`入り無署名IPAをArtifact化。
- GitHub Actionsの実行権限がなければ、ワークフロー修正と手動実行の手順を示すにとどめる。
- 実ビルド結果が出るまで成功と報告しない。成功条件：`xcodebuild`成功＋IPAのアーカイブ構造確認。

### Phase 2 – Personal版のコア機能
- 動画再生検出、候補の重複除去、有効なファイル形式判定、保存アイコン、候補シート、直接ファイル保存、進捗、キャンセル、復帰、一覧/再生/共有/削除を実装。
- 動画が見つからないサイトでは誤動作しない。Alohaの外観・ロゴ・リソースを複製せず独自UIにする。
- テストは権利を保有または保存の許可が明確な動画のみで行い、実サービス固有の回避実装に進まない。

### Phase 3 – HLS/耐久性/安全性
- Apple標準のオフラインHLS、対応可否表示、バックグラウンドDL復元、容量管理、重複保存の扱いを実装。
- 仕様書のセキュリティテストと失敗ケースを実行。

### Phase 4 – **2ビルドに明示的に分離**
- `Personal`と`Store`のビルド構成（独立したbundle identifier、表示名、コンパイルフラグ）を計画し、必要なコンパイル時分岐を実装。
- 共通のBrowserCore、DownloadCore、StorageCoreを維持。`Store`はRightsPolicyで配信元を選別、許諾不明なら保存機能を提供しない。**審査回避の手段にしない**。
- `Store`用ビルドに、不許可のダウンロード機能がバイナリとして含まれないことをソース・コンパイル条件で確認。
- サービスからの利用許諾資料を収集できるまで、App Store審査通過可能と主張しない。

### Phase 5 – 一般公開準備（将来）
- Developer Program加入後、署名済み`archive` / `exportArchive` / App Store Connectへのupload、TestFlight、プライバシーポリシー、スクリーンショット、Review Notes、権利証跡の管理を準備。
- 日本向け代替マーケットプレイス配信は第三の選択肢として**要件・費用・承認可能性の調査のみ**行い、実配布を自動化しない。

## エージェントの報告フォーマット

各フェーズ終了時、必ず日本語で次をまとめる。
1. 今回の変更ファイルと主要差分
2. 実際に検証した項目（静的検証／macOS実ビルド／iPhone実機テストを区別）
3. 仕様書IDごとの合格・未合格・未確認
4. セキュリティ、権利、Apple審査上の残リスク
5. 次の作業と、ユーザーの承認が必要な操作

**最初はPhase 0のみ着手**し、レポート提出後にPhase 1に進んでください。ユーザーに依頼されていない外部サービスへのpush、アプリ提出、費用の発生する操作を実行しないでください。
