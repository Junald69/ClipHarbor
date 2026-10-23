> **重要：開発方針がv2に変更されています。** [`00_START_HERE.md`](00_START_HERE.md) → [`01_ANTIGRAVITY_PROMPT.md`](01_ANTIGRAVITY_PROMPT.md) → [`02_PRODUCT_SPEC.md`](02_PRODUCT_SPEC.md) → [`03_WINDOWS_BUILD_GUIDE.md`](03_WINDOWS_BUILD_GUIDE.md) → [`04_RELEASE_AND_RIGHTS_CHECKLIST.md`](04_RELEASE_AND_RIGHTS_CHECKLIST.md) を参照してください。下記はv1試作ソースの技術説明であり、v2構成の実装完了を意味しません。

# ClipHarbor — iPhone用・個人開発の動画保存ブラウザ（試作版）

SwiftUI + WKWebView + URLSession + AVFoundation で構成したXcode用iOSアプリの試作です。
**アプリ内に課金・広告・ダウンロード回数制限はありません。** 実際の保存可否はコンテンツ配信元の許可、アクセス権、配信方式、端末容量などに依存します。

## 要件
- **Mac**と**Xcode**（iOS 17 SDK以降が必要）
- iOS 17以降のiPhone
- 実機へインストールするためのApple AccountとXcodeの署名設定
- App Storeへの公開やTestFlightでの配布には別途適切なApple Developer Program手続きが必要です。

## 起動方法
1. `ClipHarbor.xcodeproj` をXcodeで開きます。
2. 左側の `ClipHarbor` ターゲット → **Signing & Capabilities** → Team から、自分のApple Accountに紐づくチームを選びます。
3. **Bundle Identifier** `com.example.ClipHarbor` を他と重複しない値（例: `jp.yourname.ClipHarbor`）に変更します。
4. 上部で接続したiPhoneを選択し、▶でビルド・実行します。必要ならiPhone側で「開発者モード」を有効にします。
5. 動画のダウンロードが許可されているサイトにアクセスし、動画を再生します。
6. URLを検出できたときに表示される「動画を保存」をタップ → 候補を選ぶとダウンロードが開始されます。
7. 下部フォルダアイコンから保存した動画の再生・共有・削除ができます。MP4等はiPhoneの「ファイル」アプリ →「このiPhone内」→「ClipHarbor」→「Downloads」でも確認できます。

## 機能と仕組み
| 機能 | 実装 |
| --- | --- |
| ブラウジング、URL/検索、戻る・進む・更新 | WKWebView / SwiftUI |
| 動画再生の検出 | 動画タグの `play` / `loadedmetadata` イベント |
| メディアURL検出 | `<video>` / `<source>` と PerformanceObserver（`.mp4`, `.m3u8` 等） |
| 直接動画ファイル保存 | URLSessionDownloadTask（認証サイト向けにCookie・Refererの一部を引き継ぐ） |
| オフラインHLS | Apple `AVAssetDownloadURLSession`（対応・許可されたHLSのみ） |
| 保存済み動画を再生 | AVKit `VideoPlayer` |
| ファイル共有・削除 | ShareLink / FileManager |

## 制約と既知の課題（重要）
- **Alohaと完全互換ではありません。** 現状は試作版であり、iPhone実機によるビルド/動作検証は未実施です。
- **ニコニコ動画での動作は未検証です。** 動画が再生されても、実体が `blob:` / Media Source Extensions / 期限付きURL / ログイン認証 / サイト独自API などを利用している場合、保存できないことがあります。
- DRM（FairPlay等）で保護されたコンテンツには対応していません。DRMやアクセス制限を解除する機能もありません。
- HLSはAppleが管理する**オフライン再生用のパッケージ**として保存され、通常のMP4ファイルにはなりません。HLSではページのCookie/RefererをAVFoundationに引き継ぐ処理を実装していないため、認証が必要なHLSは失敗する可能性があります。
- 直接動画ファイルはURLSessionの通常セッションを使用しており、アプリが終了すると継続・再開できない場合があります。HLSセッションはOSのバックグラウンドAPIですが、アプリの再起動イベント対応は試作版では未実装です。
- 進捗率、複数タブ、プライベートモード、広告ブロック、ダウンロードの一時停止・再開、並列数制限、バックグラウンドでのファイル保存復元は未実装です。
- ブラウザとしての使い勝手（ログイン画面、ポップアップ、Cookie選択、各サイト固有の再生UI等）は実機検証と改良が必要です。
- 動画サイズ・携帯回線のデータ使用量・ストレージ上限は制限されます。回数が無制限でも**必ず成功するわけではありません**。

## 個人利用と権利
- **ダウンロード機能は、著作権者・配信サイトが保存を許可している動画を対象としてください。** 権利者の許可なくダウンロードしてよいわけではありません。
- Apple App Store Review Guidelines **5.2.3** は、供給元の明示的な承認を得ずにサードパーティの動画を保存・ダウンロードさせるアプリの公開を制限しています。個人開発だからといって、コンテンツの利用規約・著作権の問題がなくなるわけではありません。
- iPhoneへ直接インストールする署名には、無料Apple Accountでは有効期間等の制約がある場合があります。

参考資料:
- https://developer.apple.com/documentation/webkit/wkwebview/
- https://developer.apple.com/documentation/webkit/wkscriptmessagehandler
- https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession
- https://developer.apple.com/documentation/avfoundation/using-avfoundation-to-play-and-persist-http-live-streams
- https://developer.apple.com/jp/app-store/review/guidelines/
