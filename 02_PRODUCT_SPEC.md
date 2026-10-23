# ClipHarbor – 製品・技術仕様書 v2.0

更新日: 2026-10-13 / 状態: 設計仕様・既存コードへの実装は未完 / 開発端末: Windows + Google Antigravity / ビルド: GitHub Actions macOS

## 1. プロジェクトの決定事項

**第一優先: 動画ダウンロード機能の実用性。** App Storeへの一般公開は将来の目標として残すが、それを理由に初期MVPの動画検出や端末内保存を不必要に削らない。代わりに同じコードベースから、配布条件の異なる製品構成を作る。

- **ClipHarbor Personal**: 開発者本人のiPhoneにインストールする汎用動画検出・保存ブラウザ。配布: 個人用開発署名 / Windows Sideloadlyを当面の案とする。ユーザーが保存権限を持つ動画を対象とする。App Store審査の承認を求めるものではない。
- **ClipHarbor Store**: 公開用。第三者サービスからの明示的な許諾が得られた配信元、自ら所有し配布を許可したコンテンツ、利用者が正当に保有するローカルファイルなどの**立証可能な範囲**に保存対象を限定。App Store審査を保証しない。
- **ClipHarbor Marketplace**: 日本のiOS 26.2以降で認められた代替アプリマーケットプレイスの配布を将来調査する構想。Apple公証、Developer Program、マーケットプレイス側の参加条件、規約を要する。Personal/Storeの完成後に判断する。

**絶対的な制約:** 個人インストールは著作権・利用規約・アクセス制御の例外を与えない。DRM解除、認証迂回、アクセス制限回避、第三者サイトの非公開API悪用、違法ファイル共有の促進を製品目標にしない。

## 2. 配布・権利の判断表

| 観点 | Personal | Store | 日本の代替Marketplace（将来） |
|---|---|---|---|
| 想定利用 | 開発者本人のiPhone | 不特定多数 | 参加マーケットプレイス利用者 |
| 主な審査 | 個人開発署名。App Reviewの提出なし | Apple App Review（5.2.2、5.2.3等） | Apple公証とマーケットプレイス側審査・規約 |
| 保存範囲 | 適法・許諾を前提とする一般的なHTTP(S)メディア検出 | 資料で明示的許諾を確認できる配信元などのみに限定 | 別途法務・規約適合性判断が必要 |
| 外部配信 | 非推奨、私的使用 | App Store経由 | 承認された代替マーケット経由 |
| インストール | 無署名IPA作成→Windows等で署名・サイドロード | Appleの正規の署名済アーカイブをApp Store Connectに提出 | 公証・代替配信手続き（方式は要調査） |
| 資格 | 無料Apple Accountで試作可能 | Apple Developer Program加入が必要 | Apple Developer Program等が必要 |
| 制約 | 無料署名は原則7日で失効 | 5.2.3の保存機能制限等 | 公証により無条件に許されるわけではない |

**重要:** TestFlightは「App Reviewを回避した自由配布」ではない。公開に向けて原則App Reviewガイドラインに準拠し、外部テストではBeta App Reviewが行われる場合がある。審査すり抜けのためのPersonal版提出はしない。

## 3. ユーザー体験（Personal版を基準）

1. URL入力、検索、戻る/進む/更新を使って任意のWebページを表示。
2. 動画の再生開始・ロードを検出（動画候補が取れない場合も区別）。
3. 候補があるときだけダウンロードアイコンを有効化。ツールバーや動画上にさりげなく表示。
4. タップで候補リストを開く。ページタイトル、配信元、想定形式、サイズ（取得できた場合）を表示。
5. 「保存」でユーザーが明示操作した後に処理開始。通信・端末制約や権利条件のあるコンテンツについて案内。
6. 進捗を表示し、キャンセル、必要に応じて再試行できる。
7. 完了後は端末内に安全に保管。ファイル一覧からオフライン再生、共有、ファイルへの書き出し、削除を実行。
8. 回数・累計件数によるアプリ内課金・ロックなし。

## 4. 必須要件一覧

| ID | 優先 | 要件・受け入れ基準 | エディション |
|---|---|---|---|
| BR-01 | P0 | HTTPS URL・検索語の区別、URLバー/ブラウザナビゲーション | 共通 |
| BR-02 | P0 | 戻る/進む/再読み込み、ページ読み込み状態 | 共通 |
| VD-01 | P0 | HTML5`video`の`play/loadedmetadata`検出、WebView内ナビゲーションで解除 | Personal |
| VD-02 | P0 | `src/currentSrc/source`・限定的なPerformance API等からHTTP(S)候補を抽出・重複排除 | Personal |
| VD-03 | P0 | 再生検出と保存URL取得を区別。利用可能な候補がないとき保存成功を示唆しない | Personal |
| DL-01 | P0 | 許可されたMP4/M4V/MOV等をURLSessionで取得し原子的に保存 | Personal |
| DL-02 | P0 | 保存一覧、端末内再生、共有、削除が機能 | Personal |
| DL-03 | P0 | アプリ独自の保存回数・件数制限、広告、課金はゼロ | 全版 |
| DL-04 | P0 | 認証URL/トークンの平文永続化禁止、資格情報のログ出力禁止 | 全版 |
| DL-05 | P1 | 通信量・空き容量・ファイル形式・HTTPステータスの検証とエラー表示 | 共通 |
| DL-06 | P1 | キャンセル・失敗復旧・進捗表示・重複名衝突回避 | 共通 |
| DL-07 | P1 | URLSessionバックグラウンドセッションと状態復元（OS制約を説明） | 共通 |
| DL-08 | P1 | 許諾された対応HLSのAVFoundationによるオフライン保存 | Personal / 権利条件に合えばStore |
| DL-09 | P1 | HLSオフラインパッケージと通常MP4をUIで区別 | 全版 |
| R-01 | P0 | Store向け権利適格性Policyを別層に実装し、許諾未確認の外部配信URLの保存を許さない | Store |
| R-02 | P0 | StoreビルドにPersonal用の権利未確認ダウンロード経路がコンパイルされない | Store |
| R-03 | P1 | 配信元・許諾者・証憑・利用目的・期限のRights Registerを保守 | Store |
| B-01 | P0 | GitHub Actions macOSでPersonalの無署名IPAを生成（実行結果で確認） | Personal |
| B-02 | P1 | Personal/Storeで別Bundle ID、表示名、ビルド構成、保存領域 | 両版 |
| B-03 | P2 | Developer Program加入後、App Store向け署名済archive/export/upload | Store |
| PR-01 | P1 | Cookie、Webサイトデータ、ローカル履歴の消去機能と非収集方針 | 全版 |
| UI-01 | P0 | 日本語UI、ダークモードに配慮したSafe Area設計 | 共通 |
| UI-02 | P2 | 複数タブ、ブックマーク、独自のブラウザ体験 | 共通 |

`P0`/`P1`/`P2`は優先順位を示す。表は**実装計画**であり、現時点での完成状況を示さない。

## 5. 技術アーキテクチャ

```text
ClipHarbor shared source
  ├─ BrowserCore (WKWebView, navigation, JS message validation)
  ├─ MediaDetector (DOM video/currentSrc/source, limited Performance APIs)
  ├─ MediaCandidate (URL, type, page origin, transient metadata)
  ├─ DownloadCore
  │    ├─ DirectFileDownload (URLSession; valid HTTP(S), redirect/Cookie isolation)
  │    └─ HLSOfflineDownload (AVAssetDownloadURLSession; only supported HLS)
  ├─ DownloadStore (safe sandbox file storage, metadata WITHOUT credential-bearing URLs)
  ├─ RightsPolicy protocol
  │    ├─ PersonalRightsPolicy (user-initiated, lawful/authorized use)
  │    └─ StoreRightsPolicy (explicitly authorized, evidenced sources only)
  └─ SwiftUI (browser, candidates sheet, progress, local library)

Build configuration / future:
  Personal = com.example.clipharbor.personal + compile flag CLIPHARBOR_PERSONAL
  Store    = com.example.clipharbor.store    + compile flag CLIPHARBOR_STORE
```

- 上記IDは**プレースホルダー**。実装時に固有IDへ置換する。
- どちらの構成も単に設定で隠すのではない。Storeで配布不可の処理は**Storeターゲットにリンクされず、ビルド成果物に含まれない構成**とする。分岐が適切かをソースレビューする。
- 2つのアプリはBundle IDが異なるためデータ領域が別。動画を移す場合はユーザーがFiles経由で明示的にエクスポート/インポートする。認証Cookieは移行しない。
- 将来のMarketplace版の違いもビルド構成で定義するが、技術検証が済むまで配布仕様を固定しない。
- WKWebViewナビゲーションデリゲートだけでサブリソース通信全体はキャプチャできない。`blob:`、MSE、DRM、期限切れURL、認証依存ストリーミングには対応不能なケースがある。
- iOS 17以上を最低対象。日本での代替マーケット経由の配布を考える場合はiOS 26.2以上等の新要件に別途対応。

## 6. 動画の検出・保存ルール

### 6.1 保存候補の分類

- `direct-file`: `.mp4/.mov/.m4v`など、有効なHTTP(S)の直接メディアURL。Content-Type/Content-Disposition等が使える場合は判定に加える。
- `hls`: `.m3u8`、対応するHTTP Live Streaming。Apple公開APIのオフライン保存可能性は実処理結果で判定する。
- `detected-but-unsupported`: 動画の再生は検出したが、`blob:`/MSE/非対応方式で実体のURLが取得できない等。
- `protected`: DRM、権限エラー、アクセス制御が理由で保存を実施できない。
- `unknown`: 動画かどうか確定できない。保存可能な候補として提示しない。

### 6.2 専門的要件

- JSから来たURLは非信頼入力とし、プロトコル、URL長、ファイル名、ホスト、リダイレクト、型を検証。
- CookieやHTTP認証は、適切な配信先とユーザー操作に限定。ドメイン一致だけでなくCookieの`Domain/Path/Secure`、公開サフィックスなどの厳密性を確認。リダイレクト先へ資格情報を不用意に引き継がない。
- リクエストヘッダを無差別にコピーしない。RefererはWebViewページURL全体が機密である場合を想定し、送信要否を慎重に決める。
- URLに認証トークンが含まれ得るため、`SavedVideo`に完全な`sourceURL`を永続化しない。UIにはドメイン程度のみを必要に応じて保存し、個別URLはタスク終了後破棄する。
- HTTP 200でもHTMLログインページの可能性があるため、レスポンスを検証してから保存成功とする。
- 保存ファイルは一時領域で受け取り、検証後に安全なファイル名・拡張子を付けて移動。途中キャンセル時はゴミを除去。
- iOSファイル保護/サンドボックス、`UIDocumentPicker`/共有シート等の公開APIを使用。
- HLSはAVFoundationによるオフライン資産であり「1本のMP4」ではない。非対応DRM保護HLSは保存不可を正しく告知。

## 7. Store版の権利設計（重要）

Apple App Review Guidelinesの**5.2.2（第三者サービス）・5.2.3（音声/動画ダウンロード）**に対し、単なる「利用者に著作権確認をさせるチェックボックス」では足りない可能性が高い。Appleは第三者提供元の明示的承認や証明書類の提示を求める場合がある。

### 7.1 許諾を得たソース

- 配信元の正式な利用規約/APIポリシーにダウンロード許可が明示され、**ClipHarborでの保存**が対象として合理的に立証できること。
- または配信元・権利者からClipHarborの利用形態と配布地域について書面等で明示的に許可されていること。
- アプリ開発者自身が管理するテスト/公開用の動画サーバーやコンテンツ。
- 利用者が正当に保有する動画ファイルをFiles/Photosからアプリに取り込む操作（必要なAPIと許諾を確認）。

### 7.2 保存対象の決定

- 保存候補発見時に`StoreRightsPolicy`を通す。未登録の外部配信元はダウンロードボタンを表示しない／無効化する。
- 許諾が確認できても対象ファイル種類、地域、認証条件、期間、API利用目的等の範囲外は拒否。
- `Rights Register`に証憑URL、取得日、許諾期限、対象ドメイン、機能範囲、最終確認日を記載し、公開前に手動監査。
- ユーザー本人による「保存権限がある」自己申告だけで外部サイトへの一般的ダウンロードを解放しない。
- Appleに提出するReview Notesに、どの提供元の動画をどう保存できるか、実際のテスト方法と根拠を明示。
- 必要な権利証跡が集められない場合、Storeは **Webブラウザ + 自作/許諾済み動画のオフラインライブラリ** として方向転換する。ストア審査の通過は約束しない。

### 7.3 禁止事項

- レビューアー判定や審査時だけ機能を非表示にすること。
- App Store版からPersonal機能をサーバーのフラグで後付け解放すること。
- 同じ公開バイナリに未申告の内部メニューやURLスキームによる禁止機能を仕込むこと。

## 8. UI文言・エラー分類

| 事象 | 想定表示 |
|---|---|
| HTTP(S)候補を取得 | 「保存できる可能性がある動画を検出しました」 |
| 動画再生のみ検出 | 「動画を検出しましたが、保存用のURLを取得できません」 |
| 権限・規約・配信元制限 | 「このコンテンツは保存対象外です」 |
| HTTP 401/403 | 「配信元へのアクセス権を確認できません」 |
| HTTP 404/410 | 「動画が見つからないか、URLの有効期限が切れました」 |
| 容量不足 | 「iPhoneの空き容量が不足しています」 |
| HLS非対応 | 「この配信方式のオフライン保存には対応していません」 |
| DRM | 「保護されたコンテンツは保存できません」 |
| 成功 | 「保存しました」＋一覧から再生できることを確認 |

「検出した」ことだけを根拠に「保存できます」とは断言しない。

## 9. セキュリティ・プライバシー

- 既定で広告SDK、追跡SDK、外部解析、運営サーバーを導入しない。**通信先である閲覧サイト自体へのアクセスは発生する**ので「ネット通信ゼロ」とは誤解させない。
- ソースURL、閲覧履歴、Cookie、認証ヘッダはバックエンドに送らない。ログ・クラッシュレポート・Actions Artifactにも残さない。
- URLに個人情報・署名・アクセス権が含まれることを前提にマスキング。
- 保存一覧メタデータはローカル永続化し、完全な動画URL・Cookieは保持しない。必要な場合はiOS Keychainや一時セッションで必要最小限にする。
- 端末内ファイルの暗号化・File Protection属性とバックアップ方針を検討する。
- 不審なスキームを拒否、クロスオリジン漏えいを防止、WebView JavaScriptメッセージの型検証とライフサイクル管理を行う。
- 外部ダウンロード前にユーザー操作。悪意あるWebページから自動ダウンロードさせない。
- App Store版ではプライバシーポリシーURL、実際のデータ収集有無に合致したApp Privacy申告、必要に応じた利用規約・サポート導線を準備。

## 10. 試験計画・受け入れ基準

### 10.1 クラウドビルド
- [ ] Actions macOSの`xcodebuild`成功（ログを確認）。
- [ ] Personal: IPA内の`Payload/*.app`を確認。
- [ ] Windows署名・iPhone実機インストール成功（本人が確認）。
- [ ] Store: Apple Developer Program加入後、署名済みArchiveとApp Store Connectへの正規アップロードを別に実施。

### 10.2 基本機能
- [ ] 自前HTMLページ上の権利確認済MP4を再生すると検出できる。
- [ ] 保存ボタンをタップするまで通信取得・永続保存しない。
- [ ] MP4の保存完了後、機内モードで再生できる。
- [ ] ファイル一覧で再生・共有・削除できる。
- [ ] 10本連続保存しても回数制限ダイアログが出ない（容量等別要因は許容）。
- [ ] 進捗率・キャンセル・異常終了後の復帰が安定する。
- [ ] 許可済みのHLSテスト配信を対応デバイス上でオフライン保存できるか検証し、未対応は明確に表示する。
- [ ] `blob:`/MSE/DRM/401/期限切れURLで誤った保存成功表示をしない。

### 10.3 セキュリティテスト
- [ ] クエリにダミーAPIトークンの付いたURLがUserDefaults、保存DB、ログ、クラッシュレポートに残らない。
- [ ] リダイレクトで別ホストに移動したときCookie/Authorization情報が漏れない。
- [ ] 正規化前の危険なファイル名・拡張子・パストラバーサルが拒否・サニタイズされる。
- [ ] 無操作のページ再生だけで背景ダウンロードが開始されない。
- [ ] Store構成にPersonal専用の不許可処理が入っていない。

### 10.4 公開前チェック
- [ ] すべてのStore対応サイトの権利証跡がRights Registerにある。
- [ ] App Privacy申告・プライバシーポリシー・スクリーンショット・Review Notesが実態と一致。
- [ ] TestFlightの外部テストの審査が必要であることを理解している。
- [ ] Apple審査提出前にリスクを再評価し、承認を得られると断言していない。

## 11. 開発順序

- M0: ソースコードの監査。資格情報の平文保存リスクへの修正計画。
- M1: Personal版の署名なしIPAをGitHub Actionsで**実際に**ビルド成功。
- M2: Personal版のMP4検出/保存/ファイル管理をiPhone実機で合格。
- M3: 進捗・復帰・HLS保存とセキュリティのテスト。
- M4: Personal/Storeのビルド分離＋権利Policyのコード化。
- M5: Store用許諾先の確保、Apple Developer Program加入、署名済みビルド、TestFlight、審査提出。
- M6: 日本の代替マーケット流通を比較検討（任意）。

## 12. 外部参照（公式）

- App Review Guidelines 2.3.1, 2.5.6, 5.2.2, 5.2.3: https://developer.apple.com/jp/app-store/review/guidelines/
- 日本の代替配信と公証: https://developer.apple.com/jp/support/app-distribution-in-japan/
- Apple開発アカウント: https://developer.apple.com/help/account/basics/about-your-developer-account/
- TestFlight overview: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Apple WebKit: https://developer.apple.com/documentation/webkit/wkwebview/
- Apple HLS offline: https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession
- Apple Privacy Policy URL: https://developer.apple.com/help/app-store-connect/reference/app-privacy/
