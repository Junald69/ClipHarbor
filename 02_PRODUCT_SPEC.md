# ClipHarbor – 製品・技術仕様書 v2.1

更新日: 2026-10-24 / 状態: Personal版 v2.1 実装済（実機検証待ち） / 開発端末: Windows + Google Antigravity / ビルド: GitHub Actions macOS (`macos-26`)

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

## 3. ユーザー体験（Personal版 v2.1 を基準）

1. iPhone画面全体（Safe Area内の上部URLバー・下部ツールバー＋全面WebView）を使用し、上下に不要な黒帯を出さない。
2. URL入力、検索、戻る/進む/更新/ホームを使って任意のWebページを表示。
3. HTML5 `video` 要素の再生イベント（`play`, `playing`, `pause`, `ended`, `loadedmetadata`, `emptied`）と表示領域を監視し、現在再生中または直近操作されたメイン動画を自動特定。
4. 再生中のインライン動画の右上（シークバーや再生操作を妨げない位置、44×44pt以上）に、Aloha風のダウンロードボタン（↓）を自動表示。クロスオリジンiframe等で座標が取れない場合はWebView右下に表示。
5. ↓ボタンをタップすると、ネイティブの「動画を保存」シートを表示。動画名（編集可能なTextField、初期値は動画タイトルまたはページタイトル）、保存形式（MP4等またはオフラインHLS）、保存先を確認して「ダウンロード」を実行。
6. 複数動画が同時再生されていてメイン動画を1つに特定できない場合は、タイトル・形式・サムネイル（poster）・再生状態・保存不可理由を備えた候補一覧シート（フォールバック）を表示。
7. ダウンロード中は準備中・進捗（%およびバイト数）・保存完了・保存失敗・キャンセルを表示し、キャンセルや再試行が可能。
8. 完了後は端末内に安全に保管。ダウンロード一覧からアプリ内全画面プレイヤーでのオフライン再生、ファイルアプリ等への共有・書き出し（直接ファイル）、削除を実行。
9. 回数・累計件数によるアプリ内課金・ロックなし。

## 4. 必須要件一覧

| ID | 優先 | 要件・受け入れ基準 | エディション |
|---|---|---|---|
| BR-01 | P0 | HTTPS URL・検索語の区別、URLバー/ブラウザナビゲーション | 共通 |
| BR-02 | P0 | 戻る/進む/再読み込み、ページ読み込み状態 | 共通 |
| VD-01 | P0 | HTML5`video`の`play/playing/pause/ended/loadedmetadata/emptied`検出、ページ移動で解除 | Personal |
| VD-02 | P0 | `src/currentSrc/source`・限定的なPerformance API等からHTTP(S)候補を抽出・重複排除 | Personal |
| VD-03 | P0 | 再生検出と保存URL取得を区別。`blob:`等で利用可能な候補がないとき保存成功を示唆しない | Personal |
| VD-04 | P0 | 動画ごとに一時ID・表示領域・再生状態を追跡し、複数動画時はメイン動画を優先選択 | Personal |
| DL-01 | P0 | 許可されたMP4/M4V/MOV等をURLSessionで取得し原子的に保存 | Personal |
| DL-02 | P0 | 保存一覧、端末内再生、共有、削除が機能 | Personal |
| DL-03 | P0 | アプリ独自の保存回数・件数制限、広告、課金はゼロ | 全版 |
| DL-04 | P0 | 認証URL/トークンの平文永続化禁止、資格情報のログ出力禁止 | 全版 |
| DL-05 | P1 | 通信量・空き容量・ファイル形式（マジックナンバー確認）・HTTPステータスの検証とエラー表示 | 共通 |
| DL-06 | P1 | キャンセル・失敗復旧・進捗表示・重複名衝突回避 | 共通 |
| DL-07 | P1 | URLSessionバックグラウンドタスク・HLS状態復元（OS制約を説明） | 共通 |
| DL-08 | P1 | 許諾された対応HLSのAVFoundationによるオフライン保存 | Personal / 権利条件に合えばStore |
| DL-09 | P1 | HLSオフラインパッケージと通常MP4をUIで区別（HLSをMP4変換可能と誤認させない） | 全版 |
| DL-10 | P0 | 保存開始前にファイル名入力・確認シートを表示し、不正文字除去・拡張子一致・重複回避を行う | 全版 |
| R-01 | P0 | Store向け権利適格性Policyを別層に実装し、許諾未確認の外部配信URLの保存を許さない | Store |
| R-02 | P0 | StoreビルドにPersonal用の権利未確認ダウンロード経路がコンパイルされない | Store |
| R-03 | P1 | 配信元・許諾者・証憑・利用目的・期限のRights Registerを保守 | Store |
| B-01 | P0 | GitHub Actions macOS (`macos-26`) でPersonalの無署名IPAを生成 | Personal |
| B-02 | P1 | Personal/Storeで別Bundle ID、表示名、ビルド構成、保存領域 | 両版 |
| B-03 | P2 | Developer Program加入後、App Store向け署名済archive/export/upload | Store |
| PR-01 | P1 | Cookie、Webサイトデータ、ローカル履歴の消去機能と非収集方針 | 全版 |
| UI-01 | P0 | 日本語UI、ダークモードに配慮したSafe Area設計 | 共通 |
| UI-02 | P2 | 複数タブ、ブックマーク、独自のブラウザ体験 | 共通 |
| UI-03 | P0 | `UILaunchScreen` 自動生成とSafe Areaレイアウトにより、iPhone上下の不要な黒帯を解消 | 全版 |

## 5. 技術アーキテクチャ（v2.1 ファイル構成）

```text
ClipHarbor/
  ├─ ClipHarborApp.swift      (Appエントリーポイント、バックグラウンドURLSession用AppDelegate)
  ├─ BrowserScreen.swift      (全画面レイアウト、Aloha風動画右上↓オーバーレイ、ツールバー)
  ├─ SaveVideoSheet.swift     (ファイル名入力シート、候補一覧シート、ダウンロード進捗・保存済み一覧、オフライン再生プレイヤー)
  ├─ BrowserModel.swift       (WKWebView管理、ナビゲーション、隔離ワールドからのJSメッセージ検証・動画追跡)
  ├─ MediaScannerScript.swift (DOM video要素イベント・表示座標・MutationObserver・PerformanceObserver監視JS)
  ├─ TrackedVideo.swift       (動画ごとの再生状態・表示領域モデル、複数動画からのメイン動画選択ロジック)
  ├─ MediaCandidate.swift     (保存候補モデル、blob:等を除外するMediaClassifier)
  ├─ DownloadModels.swift     (元URLを含まないSavedVideoモデル、v1移行用デコーダ、DownloadJob/DownloadState)
  ├─ DownloadCenter.swift     (直接ファイル・HLSオフライン保存、進捗監視、キャンセル・再試行、容量・形式検証)
  ├─ RequestSecurity.swift    (RFC 6265準拠Cookieフィルタ、リダイレクト時資格情報隔離、MediaSniffer、エラー文言)
  └─ FileNaming.swift         (ファイル名サニタイズ、拡張子整合、重複名回避、パストラバーサル対策)
```

## 6. 動画の検出・選択・保存ルール（v2.1）

### 6.1 再生イベント追跡とメイン動画の特定
- `WKUserScript` を隔離されたコンテンツワールド（`.defaultClient`）および全フレーム（`forMainFrameOnly: false`）に注入する。
- インライン再生を優先するため、`video` 要素に `playsinline` / `webkit-playsinline` を補完する。
- 監視イベント：`play`, `playing`, `pause`, `ended`, `loadedmetadata`, `emptied`, `encrypted`, `webkitneedkey`, `webkitbeginfullscreen`, `webkitendfullscreen`。
- 各 `video` 要素に一時IDを付与し、再生状態、表示割合（`visibleRatio`）、トップレベルvisual viewport基準の矩形（`rectInCSS`）、直近の再生時刻・ユーザータップ時刻を追跡する。
- 複数動画が存在する場合は、再生中・直近のユーザー操作・表示割合・非ミュートを優先してメイン動画を1つ選ぶ。スコアが拮抗して特定できない場合は候補一覧シートへフォールバックする。
- iOS標準の全画面動画プレイヤーには公開APIでカスタムボタンを追加できないため、非公開APIや内部View階層のハックは行わず、全画面移行時に案内を表示し、インライン復帰時に↓ボタンから保存できる設計とする。保存済み動画や直接再生可能な動画はClipHarbor内の全画面プレイヤー（`OfflineVideoPlayerSheet`）で再生する。

### 6.2 保存候補の分類
- `file(.mp4/.m4v/.mov/.webm/.unknown)`: 有効なHTTP(S)の直接メディアURL。ダウンロード完了後にファイルの先頭バイト（`MediaSniffer`）を検査し、実際のコンテナ形式と拡張子を一致させる。
- `hls`: `.m3u8`、対応するHTTP Live Streaming。`AVAssetDownloadURLSession` でオフライン保存し、MP4へ変換できるとは誤認させない。
- `unsupported`: `blob:` / MSE / `mediastream:` / `data:` など、直接保存先を表さないURL。通常のMP4 URLとして扱わず、保存不可理由を案内する。
- `protected`: DRM（`mediaKeys` / `encrypted` イベント等）が検出された動画。

### 6.3 専門的セキュリティ要件
- JSから来た入力はすべて非信頼入力とし、型・長さ・スキーム・ホストを検証する。
- Cookieは `CookiePolicy` によりドメイン・パス・Secure属性・有効期限が一致するもののみ付与し、リダイレクト時には前の宛先のCookie/Authorizationヘッダを破棄して再判定する。
- Refererは完全なURLではなくオリジン（`scheme://host/`）のみを送信し、HTTPSからHTTPへのダウングレード時は送信しない。
- `SavedVideo` には元の動画URL全文（`sourceURLString`）を保存せず、ホーム相対パス（`relativePath`）とホスト名（`sourceHost`）のみを永続化する。旧v1データが存在する場合は起動時にURLを破棄してv2形式へ移行する。

### 6.4 アプリ内ゴミ箱機能と将来仕様（保持期間設定）
- **現在の実装**: 削除操作時は実ファイルを `Library/Application Support/Trash/`（非公開領域）へ隔離移動し、72時間（3日間）経過後に次回アプリ起動時・フォアグラウンド復帰時に自動完全削除。サムネイルも同ディレクトリ内に隔離永続化。
- **将来予定仕様（ファイル管理設定からの選択機能）**:
  - 選択肢: 1日 / 3日（初期値） / 7日 / 30日 / 自動削除しない
  - 適用ルール: 設定変更は、変更後にゴミ箱へ移動するファイルから適用。すでにゴミ箱にあるファイルの期限は変更しない。
  - 「自動削除しない」設定時も手動での完全削除および「ゴミ箱を空にする」は常に実行可能。
  - （※ 今回のリリースでは72時間の仕様を維持し、UI設定項目は将来対応として告知のみとする）

## 7. Store版の権利設計（重要）

Apple App Review Guidelinesの**5.2.2（第三者サービス）・5.2.3（音声/動画ダウンロード）**に対し、単なる「利用者に著作権確認をさせるチェックボックス」では足りない可能性が高い。Store版をビルド・提出する段階（Phase 4〜5）では、第三者提供元の明示的承認や証明書類がある配信元のみに制限する `StoreRightsPolicy` を別ターゲット構成で導入する。

## 8. UI文言・エラー分類

| 事象 | 想定表示 |
|---|---|
| HTTP(S)候補を取得 | 動画右上の↓ボタンを青色で有効化、タップで「動画を保存」シートを表示 |
| 動画再生のみ検出（`blob:`等） | 「この動画はblob/MSE方式で再生されているため、保存用のURLを取得できません。」 |
| DRM検出 | 「保護されたコンテンツ（DRM）は保存できません。」 |
| HTTP 401/403 | 「配信元へのアクセス権を確認できません（HTTP 401/403）」 |
| HTTP 404/410 | 「動画が見つからないか、URLの有効期限が切れました（HTTP 404/410）」 |
| 容量不足 | 「iPhoneの空き容量が不足しています」 |
| HLS非対応 | 「この配信方式のオフライン保存には対応していません」 |
| 成功 | 「保存しました：（ファイル名）」＋ダウンロード一覧からオフライン再生可能 |

## 9. セキュリティ・プライバシー

- 広告SDK、追跡SDK、外部解析、開発者サーバーを導入しない。
- ソースURL、Cookie、認証ヘッダを永続化せず、ログ・クラッシュレポート・Actions Artifactにも残さない。
- 保存ファイルには `FileProtectionType.completeUntilFirstUserAuthentication` を設定し、ファイル名のサニタイズとパストラバーサル検査（`FileNaming.isDirectChild`）を徹底する。

## 10. 試験計画・受け入れ基準（v2.1）

### 10.1 v2.1 実機受け入れテスト
1. [ ] iPhoneの上下の不要な黒帯が消え、ディスプレイ全体が使用される。
2. [ ] 保存許諾のあるMP4を再生すると、その動画の右上に↓アイコンが出る。
3. [ ] ↓をタップすると、ファイル名の入力画面（「動画を保存」シート）が出る。
4. [ ] 任意のファイル名で保存でき、不正文字除去や重複名回避が機能する。
5. [ ] 保存動画を機内モード（オフライン）で再生でき、ファイルアプリへ共有・書き出しできる。
6. [ ] 複数動画のページでも、再生中・操作されたメイン動画が優先され、判断不能時は候補一覧シートが表示される。
7. [ ] 対応できない全画面プレイヤー、`blob:`/MSE、DRM、非対応HLSでは、正しく制約を案内する。
