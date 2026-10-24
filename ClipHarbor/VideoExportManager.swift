import Foundation
import AVFoundation
import CoreMedia

/// 非DRM・非暗号化・保存許諾のある fMP4（Fragmented MP4 / CMAF）形式の VOD HLS から、
/// 既存の HLS ダウンロードエンジン（AVAssetDownloadURLSession）とは完全に独立して標準 MP4 ファイルを生成・検証する管理クラス。
/// - 第1段階の対象: 映像と音声が単一ストリームに含まれる非暗号化 fMP4 VOD HLS（#EXT-X-MAP + .m4s/.mp4 セグメント）
/// - MPEG-TS（.ts）独自リマックスおよび分離音声（#EXT-X-MEDIA:TYPE=AUDIO）結合は現段階では対象外とし、明確な理由を返す。
@MainActor
final class VideoExportManager: ObservableObject {
    static let shared = VideoExportManager()

    struct ExportJob: Identifiable, Equatable {
        enum State: Equatable {
            case analyzingPlaylist
            case downloadingSegments(completed: Int, total: Int, progress: Double)
            case remuxingToMP4
            case verifyingMP4
            case completed(VerificationSummary)
            case failed(String)
            case cancelled

            var isActive: Bool {
                switch self {
                case .analyzingPlaylist, .downloadingSegments, .remuxingToMP4, .verifyingMP4:
                    return true
                default:
                    return false
                }
            }

            var label: String {
                switch self {
                case .analyzingPlaylist:
                    return "HLSプレイリストとfMP4構造を解析中…"
                case .downloadingSegments(let done, let total, let p):
                    return "fMP4セグメント取得中 (\(done)/\(total) · \(Int(p * 100))%)"
                case .remuxingToMP4:
                    return "AVAssetExportSessionでMP4へ書き出し中…"
                case .verifyingMP4:
                    return "生成されたMP4の品質（トラック・再生時間・冒頭/中間/終端フレーム）を検証中…"
                case .completed(let summary):
                    return "MP4変換・検証完了（\(String(format: "%.1f秒", summary.durationSeconds))）"
                case .failed(let reason):
                    return "MP4変換不可：\(reason)"
                case .cancelled:
                    return "キャンセルしました"
                }
            }
        }

        let id: UUID
        let displayName: String
        let targetFolder: String
        let host: String
        var state: State
    }

    struct VerificationSummary: Equatable {
        let byteSize: Int64
        let durationSeconds: Double
        let expectedPlaylistDuration: Double
        let videoCodec: String
        let audioCodec: String?
        let segmentCount: Int
        let decodedCheckpoints: Int
        let exportPresetUsed: String
    }

    enum ExportError: LocalizedError, Equatable {
        case httpError(statusCode: Int, stage: String)
        case invalidPlaylist
        case encryptedStream(String)
        case liveStream
        case separateAudioNotSupportedYet
        case notFMP4Format(String)
        case discontinuityNotSupported(String)
        case unsupportedCodec(String)
        case segmentDownloadFailed(index: Int, total: Int, reason: String)
        case invalidInitSegment(String)
        case invalidMediaSegment(index: Int, reason: String)
        case timestampDiscontinuity(trackID: UInt32, segmentIndex: Int, previousDTS: UInt64, currentDTS: UInt64)
        case combinedFMP4NotPlayable(String)
        case exportSessionNotCompatible(String)
        case exportSessionFailed(String)
        case verificationFailed(String)
        case fileSaveFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let stage):
                return "配信元からの取得に失敗しました（\(stage): HTTP \(code)）。URLの有効期限切れやアクセス制限の可能性があります。"
            case .invalidPlaylist:
                return "有効なHLSプレイリスト（#EXTM3U）として解析できませんでした。"
            case .encryptedStream(let detail):
                return "暗号化またはDRM保護された配信（\(detail)）のため、MP4として保存できません。「オフラインHLS」での保存をご利用ください。"
            case .liveStream:
                return "ライブ配信（#EXT-X-ENDLISTなし）のため、MP4として保存できません。"
            case .separateAudioNotSupportedYet:
                return "映像と音声が別プレイリストに分離されたHLS配信（#EXT-X-MEDIA:TYPE=AUDIO）です。現段階では単一ストリーム（映像・音声統合型）のfMP4のみ対応しています。「オフラインHLS」で保存してください。"
            case .notFMP4Format(let detail):
                return "fMP4（Fragmented MP4 / #EXT-X-MAP）形式のHLSではありません（\(detail)）。MPEG-TS（.ts）形式等は「オフラインHLS」で保存してください。"
            case .discontinuityNotSupported(let detail):
                return "プレイリスト内に不連続区間（\(detail)）が含まれているため、fMP4結合によるMP4変換の対象外です。「オフラインHLS」で保存してください。"
            case .unsupportedCodec(let detail):
                return "MP4書き出しに対応していないコーデック構成です（\(detail)）。"
            case .segmentDownloadFailed(let idx, let total, let reason):
                return "セグメント \(idx)/\(total) の取得に失敗しました（\(reason)）。セグメント欠落のあるMP4は保存しません。"
            case .invalidInitSegment(let detail):
                return "fMP4初期化セグメント（#EXT-X-MAP）の構造が不正です（\(detail)）。"
            case .invalidMediaSegment(let idx, let reason):
                return "セグメント \(idx) のfMP4ボックス構造（moof/mdat）が不正です（\(reason)）。"
            case .timestampDiscontinuity(let trackID, let idx, let prev, let curr):
                return "セグメント \(idx)（track_ID=\(trackID)）でタイムスタンプの不連続（\(prev) → \(curr)）を検出したため中止しました。"
            case .combinedFMP4NotPlayable(let detail):
                return "結合したfMP4をAVFoundationで読み込めませんでした（\(detail)）。"
            case .exportSessionNotCompatible(let detail):
                return "AVAssetExportSession で通常のMP4へ変換できないストリーム構成です（\(detail)）。"
            case .exportSessionFailed(let detail):
                return "AVAssetExportSession によるMP4書き出しに失敗しました（\(detail)）。"
            case .verificationFailed(let detail):
                return "生成されたMP4の品質検証に失敗しました（\(detail)）。"
            case .fileSaveFailed(let detail):
                return "MP4ファイルの保存に失敗しました（\(detail)）。"
            case .cancelled:
                return "MP4変換をキャンセルしました。"
            }
        }
    }

    @Published private(set) var exportJobs: [ExportJob] = []
    @Published private(set) var statusMessage: String?
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var statusClearTask: Task<Void, Never>?

    var activeCount: Int {
        exportJobs.filter { $0.state.isActive }.count
    }

    private lazy var exportURLSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 2 * 60 * 60
        return URLSession(configuration: config)
    }()

    // MARK: - 公開API

    /// HLS候補（fMP4 VOD）から独立して標準MP4を生成・検証し、成功時のみ保存済み一覧へ登録する
    @discardableResult
    func startFMP4Export(
        candidate: MediaCandidate,
        displayName: String,
        targetFolder: String = "",
        context: RequestContext
    ) -> UUID {
        var cleanName = FileNaming.sanitizedBaseName(displayName)
        if cleanName.isEmpty { cleanName = FileNaming.sanitizedBaseName(candidate.suggestedName) }
        if cleanName.isEmpty { cleanName = "Video" }
        let cleanFolder = VideoFolderManager.sanitizedFolderName(targetFolder)

        let jobID = UUID()
        let job = ExportJob(
            id: jobID,
            displayName: cleanName,
            targetFolder: cleanFolder,
            host: candidate.host,
            state: .analyzingPlaylist
        )
        exportJobs.insert(job, at: 0)
        setStatus("fMP4→MP4変換を開始：\(cleanName)")

        let session = exportURLSession
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.runExportPipeline(
                jobID: jobID,
                candidateURL: candidate.url,
                baseName: cleanName,
                targetFolder: cleanFolder,
                sourceHost: candidate.url.host,
                context: context,
                session: session
            )
        }
        runningTasks[jobID] = task
        return jobID
    }

    func cancelExport(_ jobID: UUID) {
        runningTasks[jobID]?.cancel()
        runningTasks[jobID] = nil
        updateJob(jobID) { $0.state = .cancelled }
        setStatus("MP4変換をキャンセルしました")
    }

    func dismissExportJob(_ jobID: UUID) {
        guard let job = exportJobs.first(where: { $0.id == jobID }), !job.state.isActive else { return }
        exportJobs.removeAll { $0.id == jobID }
        runningTasks[jobID] = nil
    }

    // MARK: - 実機PoC検証用エントリ（テストA / テストB / テストC）

    /// テストA: Apple公式の保存許諾テスト素材（BipBop fMP4: v2映像 avc1 + a1音声 mp4a）から
    /// 単一ストリーム（映像・音声統合型）の非暗号化fMP4 VOD HLSを生成し、MP4変換・8項目品質検証を実行する
    @discardableResult
    func startPoCTestA_MuxedFMP4() -> UUID {
        let jobID = UUID()
        let displayName = "PoC_TestA_Muxed_fMP4"
        let job = ExportJob(
            id: jobID,
            displayName: displayName,
            targetFolder: "",
            host: "devstreaming-cdn.apple.com (統合fMP4テストA)",
            state: .analyzingPlaylist
        )
        exportJobs.insert(job, at: 0)
        setStatus("PoCテストA（映像・音声統合型fMP4→MP4）を開始…")

        let session = exportURLSession
        let context = RequestContext(cookies: [], userAgent: nil, pageURL: nil)
        let task = Task { [weak self] in
            guard let self = self else { return }
            let synthDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipHarborPoCTestA_\(jobID.uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: synthDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: synthDir)
            }

            do {
                let appleBase = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/")!
                let vURL = appleBase.appendingPathComponent("v2/main.mp4")
                let aURL = appleBase.appendingPathComponent("a1/main.mp4")

                let vInit = try await self.fetchSegmentData(
                    url: vURL,
                    byteRange: .init(length: 719, offset: 0),
                    stage: "テストA映像init取得",
                    context: context,
                    session: session
                )
                let aInit = try await self.fetchSegmentData(
                    url: aURL,
                    byteRange: .init(length: 616, offset: 0),
                    stage: "テストA音声init取得",
                    context: context,
                    session: session
                )

                let vRanges: [HLSFMP4PlaylistParser.ByteRange] = [
                    .init(length: 274201, offset: 719),
                    .init(length: 280451, offset: 274920),
                    .init(length: 282332, offset: 555371)
                ]
                let aRanges: [HLSFMP4PlaylistParser.ByteRange] = [
                    .init(length: 121090, offset: 616),
                    .init(length: 121201, offset: 121706),
                    .init(length: 121198, offset: 242907)
                ]

                var vSegs: [Data] = []
                var aSegs: [Data] = []
                for i in 0..<3 {
                    try Task.checkCancellation()
                    let vd = try await self.fetchSegmentData(
                        url: vURL,
                        byteRange: vRanges[i],
                        stage: "テストA映像素材 \(i + 1)/3",
                        context: context,
                        session: session
                    )
                    let ad = try await self.fetchSegmentData(
                        url: aURL,
                        byteRange: aRanges[i],
                        stage: "テストA音声素材 \(i + 1)/3",
                        context: context,
                        session: session
                    )
                    vSegs.append(vd)
                    aSegs.append(ad)
                }

                let masterURL = try FMP4BoxInspector.buildMuxedTestHLS(
                    in: synthDir,
                    videoInit: vInit,
                    videoSegments: vSegs,
                    audioInit: aInit,
                    audioSegments: aSegs
                )

                await self.runExportPipeline(
                    jobID: jobID,
                    candidateURL: masterURL,
                    baseName: displayName,
                    targetFolder: "",
                    sourceHost: "devstreaming-cdn.apple.com",
                    context: context,
                    session: session
                )
            } catch is CancellationError {
                self.updateJob(jobID) { $0.state = .cancelled }
                self.setStatus("PoCテストAをキャンセルしました")
                self.runningTasks[jobID] = nil
            } catch let err as ExportError {
                let msg = err.localizedDescription
                self.updateJob(jobID) { $0.state = .failed(msg) }
                self.setStatus("PoCテストA失敗：\(msg)")
                self.runningTasks[jobID] = nil
            } catch {
                let msg = error.localizedDescription
                self.updateJob(jobID) { $0.state = .failed(msg) }
                self.setStatus("PoCテストAエラー：\(msg)")
                self.runningTasks[jobID] = nil
            }
        }
        runningTasks[jobID] = task
        return jobID
    }

    /// テストB: Apple公式の分離音声fMP4 HLS（#EXT-X-MEDIA:TYPE=AUDIO,URI="a1/prog_index.m3u8"）が
    /// 現段階で正常に非対応判定（.separateAudioNotSupportedYet）されることを確認する
    @discardableResult
    func startPoCTestB_AppleSeparateAudioFMP4() -> UUID {
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!
        let candidate = MediaCandidate(
            url: url,
            kind: .hls,
            videoTitle: "PoC_TestB_Apple_SeparateAudio",
            pageTitle: "Apple BipBop Separate Audio fMP4",
            posterURL: nil,
            videoID: nil
        )
        return startFMP4Export(
            candidate: candidate,
            displayName: "PoC_TestB_Apple_SeparateAudio",
            targetFolder: "",
            context: RequestContext(cookies: [], userAgent: nil, pageURL: nil)
        )
    }

    /// テストC: MPEG-TS (.ts) 形式のHLS配信が、現段階で正常に非対応判定（.notFMP4Format）されることを確認する
    @discardableResult
    func startPoCTestC_MPEGTS() -> UUID {
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let candidate = MediaCandidate(
            url: url,
            kind: .hls,
            videoTitle: "PoC_TestC_MPEGTS",
            pageTitle: "Mux Big Buck Bunny MPEG-TS",
            posterURL: nil,
            videoID: nil
        )
        return startFMP4Export(
            candidate: candidate,
            displayName: "PoC_TestC_MPEGTS",
            targetFolder: "",
            context: RequestContext(cookies: [], userAgent: nil, pageURL: nil)
        )
    }

    // MARK: - 変換パイプライン本体

    private func runExportPipeline(
        jobID: UUID,
        candidateURL: URL,
        baseName: String,
        targetFolder: String,
        sourceHost: String?,
        context: RequestContext,
        session: URLSession
    ) async {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHarborFMP4Export_\(jobID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
            runningTasks[jobID] = nil
        }

        do {
            // 1. 初回プレイリストの取得と解析（マスタープレイリスト or メディアプレイリスト）
            try Task.checkCancellation()
            let (initialText, resolvedPlaylistURL) = try await fetchPlaylistText(
                url: candidateURL,
                stage: "プレイリスト取得",
                context: context,
                session: session
            )

            let mediaPlaylistURL: URL
            let mediaPlaylistText: String
            let masterExpectedAudio: Bool

            if HLSFMP4PlaylistParser.isMasterPlaylist(initialText) {
                let selection = try HLSFMP4PlaylistParser.selectMuxedVariant(
                    masterPlaylist: initialText,
                    baseURL: resolvedPlaylistURL
                )
                mediaPlaylistURL = selection.variantURL
                masterExpectedAudio = selection.declaresAudioCodec
                let fetched = try await fetchPlaylistText(
                    url: mediaPlaylistURL,
                    stage: "メディアプレイリスト取得",
                    context: context,
                    session: session
                )
                mediaPlaylistText = fetched.text
            } else {
                mediaPlaylistURL = resolvedPlaylistURL
                mediaPlaylistText = initialText
                masterExpectedAudio = false
            }

            // 2. メディアプレイリストの解析（#EXT-X-MAP / #EXT-X-BYTERANGE / #EXT-X-KEY / #EXT-X-DISCONTINUITY 検査）
            let parsedMedia = try HLSFMP4PlaylistParser.parseMediaPlaylist(
                mediaPlaylistText,
                baseURL: mediaPlaylistURL
            )

            // 3. 初期化セグメント（#EXT-X-MAP）の取得と ISO-BMFF (ftyp / moov / mvex / trak) 検証
            try Task.checkCancellation()
            let initData = try await fetchSegmentData(
                url: parsedMedia.initSegment.url,
                byteRange: parsedMedia.initSegment.byteRange,
                stage: "初期化セグメント(#EXT-X-MAP)",
                context: context,
                session: session
            )

            let initInfo = try FMP4BoxInspector.inspectInitSegment(initData)
            if masterExpectedAudio && !initInfo.hasAudio {
                // マスタープレイリストで音声コーデックが宣言されているのに初期化セグメントに音声トラックがない場合は分離音声
                throw ExportError.separateAudioNotSupportedYet
            }

            // 4. 一時結合ファイルへの初期化セグメント書き込みと、全メディアセグメントの順次取得・タイムスタンプ連続性検証
            let combinedFMP4URL = workDir.appendingPathComponent("combined_source.mp4")
            FileManager.default.createFile(atPath: combinedFMP4URL.path, contents: nil)
            let writerHandle = try FileHandle(forWritingTo: combinedFMP4URL)
            defer { try? writerHandle.close() }
            try writerHandle.write(contentsOf: initData)

            var initialDecodeTimeByTrack: [UInt32: UInt64] = [:]
            var lastDecodeTimeByTrack: [UInt32: UInt64] = [:]
            var nextSequenceNumber: UInt32 = 1
            let totalSegments = parsedMedia.segments.count

            for (idx, seg) in parsedMedia.segments.enumerated() {
                try Task.checkCancellation()
                let segNumber = idx + 1
                let progress = Double(idx) / Double(max(totalSegments, 1))
                updateJob(jobID) {
                    $0.state = .downloadingSegments(completed: idx, total: totalSegments, progress: progress)
                }

                let segData: Data
                do {
                    segData = try await fetchSegmentData(
                        url: seg.url,
                        byteRange: seg.byteRange,
                        stage: "セグメント \(segNumber)/\(totalSegments)",
                        context: context,
                        session: session
                    )
                } catch let err as ExportError {
                    throw ExportError.segmentDownloadFailed(
                        index: segNumber,
                        total: totalSegments,
                        reason: err.localizedDescription
                    )
                } catch {
                    throw ExportError.segmentDownloadFailed(
                        index: segNumber,
                        total: totalSegments,
                        reason: error.localizedDescription
                    )
                }

                let normalized = try FMP4BoxInspector.inspectAndNormalizeMediaSegment(
                    segData,
                    segmentIndex: segNumber,
                    initialDecodeTimes: &initialDecodeTimeByTrack,
                    lastDecodeTimes: &lastDecodeTimeByTrack,
                    nextSequenceNumber: &nextSequenceNumber
                )

                try writerHandle.write(contentsOf: normalized.normalizedData)
            }
            try writerHandle.synchronize()
            try writerHandle.close()

            // 初期化セグメントに音声トラックが存在する場合、メディアセグメントにもその track_ID のフラグメントが含まれているか確認
            if initInfo.hasAudio {
                let audioTrackIDs = initInfo.tracks.filter { $0.handlerType == "soun" }.map(\.trackID)
                let hasAnyAudioFragment = audioTrackIDs.contains { lastDecodeTimeByTrack[$0] != nil }
                if !hasAnyAudioFragment {
                    throw ExportError.invalidMediaSegment(
                        index: totalSegments,
                        reason: "初期化セグメントに音声トラックがありますが、メディアセグメントに音声フラグメントが含まれていません"
                    )
                }
            }

            updateJob(jobID) {
                $0.state = .downloadingSegments(completed: totalSegments, total: totalSegments, progress: 1.0)
            }

            // 5. 結合したfMP4を AVFoundation (AVURLAsset) が読み込めるか検証
            try Task.checkCancellation()
            updateJob(jobID) { $0.state = .remuxingToMP4 }

            let combinedAsset = AVURLAsset(url: combinedFMP4URL)
            let isCombinedPlayable = (try? await combinedAsset.load(.isPlayable)) ?? false
            guard isCombinedPlayable else {
                throw ExportError.combinedFMP4NotPlayable("AVURLAsset.isPlayable が false です。")
            }

            // 6. AVAssetExportSession で通常のMP4（単一moov・FastStart）として書き出せるか検証・実行
            let exportedTempURL = workDir.appendingPathComponent("exported_final.mp4")
            let presetUsed = try await remuxToStandardMP4(sourceAsset: combinedAsset, outputURL: exportedTempURL)

            // 7. 生成されたMP4の8項目品質検証（ファイル存在・AVURLAsset・映像/音声トラック・再生時間・冒頭/中間/終端デコード）
            try Task.checkCancellation()
            updateJob(jobID) { $0.state = .verifyingMP4 }

            let summary = try await verifyExportedMP4(
                at: exportedTempURL,
                initInfo: initInfo,
                expectedPlaylistDuration: parsedMedia.totalDuration,
                segmentCount: totalSegments,
                exportPresetUsed: presetUsed
            )

            // 8. Documents/Downloads（または指定サブフォルダ）へ移動し、成功後にのみ DownloadCenter へ登録
            let savedVideo = try moveVerifiedMP4ToDownloads(
                tempMP4URL: exportedTempURL,
                baseName: baseName,
                targetFolder: targetFolder,
                sourceHost: sourceHost,
                byteSize: summary.byteSize
            )

            _ = DownloadCenter.shared.registerExportedVideo(savedVideo)
            VideoFolderManager.shared.syncWithFileSystemAndSavedVideos()

            updateJob(jobID) { $0.state = .completed(summary) }
            setStatus("MP4変換・検証完了：\(baseName).mp4")
        } catch is CancellationError {
            updateJob(jobID) { $0.state = .cancelled }
            setStatus("MP4変換をキャンセルしました")
        } catch let exportErr as ExportError {
            let msg = exportErr.localizedDescription
            updateJob(jobID) { $0.state = .failed(msg) }
            setStatus("MP4変換不可：\(msg)")
        } catch {
            let msg = error.localizedDescription
            updateJob(jobID) { $0.state = .failed(msg) }
            setStatus("MP4変換エラー：\(msg)")
        }
    }

    // MARK: - AVAssetExportSession による標準MP4書き出し

    private func remuxToStandardMP4(sourceAsset: AVURLAsset, outputURL: URL) async throws -> String {
        let passthroughCompatible = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough,
            with: sourceAsset,
            outputFileType: .mp4
        )
        let highQualityCompatible = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetHighestQuality,
            with: sourceAsset,
            outputFileType: .mp4
        )

        var candidatePresets: [(name: String, label: String)] = []
        if passthroughCompatible {
            candidatePresets.append((AVAssetExportPresetPassthrough, "Passthrough"))
        }
        if highQualityCompatible {
            candidatePresets.append((AVAssetExportPresetHighestQuality, "HighestQuality"))
        }
        guard !candidatePresets.isEmpty else {
            throw ExportError.exportSessionNotCompatible("Passthrough / HighestQuality いずれのプリセットも .mp4 出力に非対応です。")
        }

        var errorLogs: [String] = []
        for preset in candidatePresets {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            guard let exportSession = AVAssetExportSession(asset: sourceAsset, presetName: preset.name) else {
                errorLogs.append("\(preset.label): 初期化失敗")
                continue
            }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            await exportSession.export()

            switch exportSession.status {
            case .completed:
                if errorLogs.isEmpty {
                    return preset.label
                } else {
                    return "\(preset.label) (Fallback)"
                }
            case .cancelled:
                throw ExportError.cancelled
            case .failed:
                let nsErr = exportSession.error as NSError?
                let detail = nsErr.map { "\($0.domain) (\($0.code)): \($0.localizedDescription)" } ?? "不明なエラー"
                errorLogs.append("\(preset.label)=[\(detail)]")
            default:
                errorLogs.append("\(preset.label)=[status:\(exportSession.status.rawValue)]")
            }
        }

        throw ExportError.exportSessionFailed(errorLogs.joined(separator: " / "))
    }

    // MARK: - 書き出し後のMP4品質検証（全8項目）

    private func verifyExportedMP4(
        at mp4URL: URL,
        initInfo: FMP4BoxInspector.InitSegmentInfo,
        expectedPlaylistDuration: Double,
        segmentCount: Int,
        exportPresetUsed: String
    ) async throws -> VerificationSummary {
        // 1. ファイル存在・サイズ・マジックバイト検査
        guard FileManager.default.fileExists(atPath: mp4URL.path) else {
            throw ExportError.verificationFailed("書き出し後のMP4ファイルが存在しません。")
        }
        let byteSize = (try? FileManager.default.attributesOfItem(atPath: mp4URL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard byteSize > 0 else {
            throw ExportError.verificationFailed("書き出し後のMP4ファイルサイズが0バイトです。")
        }
        guard MediaSniffer.sniff(fileAt: mp4URL) == .mp4 else {
            throw ExportError.verificationFailed("出力ファイルのヘッダーが標準MP4（ftyp）ではありません。")
        }

        // 2. AVURLAsset での読み込み可能性
        let asset = AVURLAsset(url: mp4URL)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        guard isPlayable else {
            throw ExportError.verificationFailed("出力されたMP4の AVURLAsset.isPlayable が false です。")
        }

        // 3. 映像トラックの存在確認
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !videoTracks.isEmpty else {
            throw ExportError.verificationFailed("出力されたMP4に映像トラックが存在しません。")
        }

        // 4. 入力に音声がある場合、出力にも音声トラックが存在することを確認
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if initInfo.hasAudio && audioTracks.isEmpty {
            throw ExportError.verificationFailed("入力fMP4には音声トラックが存在しましたが、出力MP4で音声トラックが欠落しました。")
        }

        // 5. 再生時間が元動画（プレイリスト合計時間）と概ね一致することを確認
        let cmDuration = try await asset.load(.duration)
        guard cmDuration.isNumeric, !cmDuration.isIndefinite, cmDuration.seconds > 0 else {
            throw ExportError.verificationFailed("出力されたMP4の再生時間（duration）が不明または0秒です。")
        }
        let actualDuration = cmDuration.seconds
        if expectedPlaylistDuration > 0 {
            let tolerance = max(2.5, expectedPlaylistDuration * 0.12)
            let diff = abs(actualDuration - expectedPlaylistDuration)
            if diff > tolerance {
                throw ExportError.verificationFailed(
                    String(
                        format: "再生時間が元プレイリストと一致しません（出力: %.1f秒 / プレイリスト合計: %.1f秒）。",
                        actualDuration,
                        expectedPlaylistDuration
                    )
                )
            }
        }

        // 6. 冒頭・中間・終端を正常にデコード・再生できることを確認
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tol = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol

        let checkpoints: [Double] = [
            min(0.5, actualDuration * 0.10),
            actualDuration * 0.50,
            max(0.0, actualDuration * 0.90)
        ]
        var decodedCount = 0
        for sec in checkpoints {
            let time = CMTime(seconds: sec, preferredTimescale: 600)
            do {
                _ = try await generator.image(at: time)
                decodedCount += 1
            } catch {
                throw ExportError.verificationFailed(
                    String(format: "%.1f秒地点（冒頭/中間/終端検査）のフレームデコードに失敗しました。", sec)
                )
            }
        }

        return VerificationSummary(
            byteSize: byteSize,
            durationSeconds: actualDuration,
            expectedPlaylistDuration: expectedPlaylistDuration,
            videoCodec: initInfo.videoCodecs.first ?? "vide",
            audioCodec: initInfo.audioCodecs.first,
            segmentCount: segmentCount,
            decodedCheckpoints: decodedCount,
            exportPresetUsed: exportPresetUsed
        )
    }

    // MARK: - Documents/Downloads への配置

    private func moveVerifiedMP4ToDownloads(
        tempMP4URL: URL,
        baseName: String,
        targetFolder: String,
        sourceHost: String?,
        byteSize: Int64
    ) throws -> SavedVideo {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsRoot = documents.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let cleanFolder = VideoFolderManager.sanitizedFolderName(targetFolder)
        let targetDir: URL
        if cleanFolder.isEmpty {
            targetDir = downloadsRoot
        } else {
            let sub = downloadsRoot.appendingPathComponent(cleanFolder, isDirectory: true)
            guard FileNaming.isDirectChild(sub, of: downloadsRoot) else {
                throw ExportError.fileSaveFailed("保存先サブフォルダ名が不正です。")
            }
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            targetDir = sub
        }

        let destinationURL = FileNaming.uniqueDestination(
            in: targetDir,
            baseName: baseName,
            fileExtension: "mp4"
        )
        guard FileNaming.isDirectChild(destinationURL, of: targetDir) else {
            throw ExportError.fileSaveFailed("保存先ファイル名が不正です。")
        }

        try FileManager.default.moveItem(at: tempMP4URL, to: destinationURL)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destinationURL.path
        )

        guard let relativePath = SavedVideo.relativePath(for: destinationURL) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ExportError.fileSaveFailed("保存先相対パスを解決できませんでした。")
        }

        return SavedVideo(
            id: UUID(),
            title: baseName,
            relativePath: relativePath,
            format: .mp4,
            sourceHost: sourceHost,
            createdAt: Date(),
            byteSize: byteSize
        )
    }

    // MARK: - ネットワーク取得ヘルパー（ByteRange対応）

    private func fetchPlaylistText(
        url: URL,
        stage: String,
        context: RequestContext,
        session: URLSession
    ) async throws -> (text: String, finalURL: URL) {
        let request = context.makeRequest(for: url)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ExportError.httpError(statusCode: http.statusCode, stage: stage)
        }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("#EXTM3U") else {
            throw ExportError.invalidPlaylist
        }
        let finalURL = (response as? HTTPURLResponse)?.url ?? url
        return (text, finalURL)
    }

    private func fetchSegmentData(
        url: URL,
        byteRange: HLSFMP4PlaylistParser.ByteRange?,
        stage: String,
        context: RequestContext,
        session: URLSession
    ) async throws -> Data {
        var request = context.makeRequest(for: url)
        if let range = byteRange {
            let endByte = range.offset + range.length - 1
            request.setValue("bytes=\(range.offset)-\(endByte)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw ExportError.httpError(statusCode: http.statusCode, stage: stage)
            }
            if let range = byteRange {
                if http.statusCode == 206 {
                    guard data.count == Int(range.length) else {
                        throw ExportError.invalidMediaSegment(
                            index: 0,
                            reason: "ByteRange長不一致 (期待: \(range.length)B / 実際: \(data.count)B)"
                        )
                    }
                    return data
                } else {
                    // サーバーが Range ヘッダーを無視して 200 OK でファイル全体を返した場合は該当範囲を切り出す
                    let start = Int(range.offset)
                    let end = start + Int(range.length)
                    guard data.count >= end else {
                        throw ExportError.invalidMediaSegment(
                            index: 0,
                            reason: "ByteRange切り出し範囲外 (\(end) > \(data.count))"
                        )
                    }
                    return data.subdata(in: start..<end)
                }
            }
        } else if url.isFileURL {
            if let range = byteRange {
                let start = Int(range.offset)
                let end = start + Int(range.length)
                guard data.count >= end else {
                    throw ExportError.invalidMediaSegment(
                        index: 0,
                        reason: "ローカルByteRange切り出し範囲外 (\(end) > \(data.count))"
                    )
                }
                return data.subdata(in: start..<end)
            }
        } else {
            throw ExportError.invalidMediaSegment(index: 0, reason: "HTTP応答がありません")
        }

        guard !data.isEmpty else {
            throw ExportError.invalidMediaSegment(index: 0, reason: "セグメントデータが0バイトです")
        }
        return data
    }

    private func updateJob(_ id: UUID, _ mutate: (inout ExportJob) -> Void) {
        guard let idx = exportJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = exportJobs[idx]
        mutate(&job)
        if job != exportJobs[idx] {
            exportJobs[idx] = job
        }
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.statusMessage == message {
                self?.statusMessage = nil
            }
        }
    }
}

// MARK: - HLS プレイリスト解析器（マスター / メディア / EXT-X-MAP / EXT-X-BYTERANGE / EXT-X-DISCONTINUITY）

enum HLSFMP4PlaylistParser {

    struct ByteRange: Equatable {
        let length: Int64
        let offset: Int64
    }

    struct SegmentRef: Equatable {
        let url: URL
        let duration: Double
        let byteRange: ByteRange?
    }

    struct ParsedMediaPlaylist: Equatable {
        let initSegment: SegmentRef
        let segments: [SegmentRef]
        let totalDuration: Double
    }

    struct VariantSelection: Equatable {
        let variantURL: URL
        let bandwidth: Int
        let declaresAudioCodec: Bool
    }

    static func isMasterPlaylist(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    /// マスタープレイリストを解析し、単一ストリームに映像（または映像＋音声）が含まれるバリアントを選択する。
    /// すべてのバリアントが外部の分離音声（#EXT-X-MEDIA:TYPE=AUDIO,URI="..."）を要求する場合は `.separateAudioNotSupportedYet` を返す。
    static func selectMuxedVariant(
        masterPlaylist text: String,
        baseURL: URL
    ) throws -> VariantSelection {
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // セッションキー暗号化チェック
        for line in lines where line.hasPrefix("#EXT-X-SESSION-KEY:") {
            if !line.contains("METHOD=NONE") {
                throw VideoExportManager.ExportError.encryptedStream("#EXT-X-SESSION-KEY")
            }
        }

        // #EXT-X-MEDIA:TYPE=AUDIO のグループごとに外部 URI の有無を記録
        var audioGroupsWithExternalURI: Set<String> = []
        var audioGroupsWithMuxedStream: Set<String> = []

        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attrs["TYPE"]?.uppercased() == "AUDIO",
                  let groupID = attrs["GROUP-ID"] else { continue }
            if let uri = attrs["URI"], !uri.isEmpty {
                audioGroupsWithExternalURI.insert(groupID)
            } else {
                audioGroupsWithMuxedStream.insert(groupID)
            }
        }

        struct CandidateVariant {
            let url: URL
            let bandwidth: Int
            let codecs: String
            let audioGroup: String?
        }

        var variants: [CandidateVariant] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                let bw = Int(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "0") ?? 0
                let codecs = (attrs["CODECS"] ?? "").lowercased()
                let audioGroup = attrs["AUDIO"]

                var j = i + 1
                while j < lines.count && (lines[j].isEmpty || lines[j].hasPrefix("#")) {
                    j += 1
                }
                if j < lines.count,
                   let resolved = URL(string: lines[j], relativeTo: baseURL)?.absoluteURL {
                    variants.append(
                        CandidateVariant(
                            url: resolved,
                            bandwidth: bw,
                            codecs: codecs,
                            audioGroup: audioGroup
                        )
                    )
                }
                i = j + 1
            } else {
                i += 1
            }
        }

        guard !variants.isEmpty else {
            throw VideoExportManager.ExportError.invalidPlaylist
        }

        // 外部音声URIに依存しない単一ストリームのバリアントを抽出
        let singleStreamVariants = variants.filter { v in
            guard let group = v.audioGroup else { return true }
            if audioGroupsWithMuxedStream.contains(group) { return true }
            return !audioGroupsWithExternalURI.contains(group)
        }

        guard !singleStreamVariants.isEmpty else {
            throw VideoExportManager.ExportError.separateAudioNotSupportedYet
        }

        // H.264 (avc1) / HEVC (hvc1) かつ AAC (mp4a) を優先し、帯域幅の大きいものを選択
        let sorted = singleStreamVariants.sorted { a, b in
            let aScore = codecCompatibilityScore(a.codecs)
            let bScore = codecCompatibilityScore(b.codecs)
            if aScore != bScore { return aScore > bScore }
            return a.bandwidth > b.bandwidth
        }

        let best = sorted[0]
        let declaresAudio = best.codecs.contains("mp4a")
            || best.codecs.contains("ac-3")
            || best.codecs.contains("ec-3")
        return VariantSelection(
            variantURL: best.url,
            bandwidth: best.bandwidth,
            declaresAudioCodec: declaresAudio
        )
    }

    private static func codecCompatibilityScore(_ codecs: String) -> Int {
        if codecs.isEmpty { return 1 }
        var score = 0
        if codecs.contains("avc1") { score += 10 }
        else if codecs.contains("hvc1") || codecs.contains("hev1") { score += 8 }
        if codecs.contains("mp4a") { score += 5 }
        return score
    }

    /// メディアプレイリストを解析し、#EXT-X-MAP と各メディアセグメント（#EXT-X-BYTERANGE 対応）を抽出する
    static func parseMediaPlaylist(_ text: String, baseURL: URL) throws -> ParsedMediaPlaylist {
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else {
            throw VideoExportManager.ExportError.invalidPlaylist
        }

        // 1. 暗号化（#EXT-X-KEY）チェック
        for line in lines where line.hasPrefix("#EXT-X-KEY:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-KEY:".count)))
            let method = (attrs["METHOD"] ?? "NONE").uppercased()
            if method != "NONE" {
                throw VideoExportManager.ExportError.encryptedStream("METHOD=\(method)")
            }
        }

        // 2. VOD（#EXT-X-ENDLIST）チェック
        guard lines.contains(where: { $0 == "#EXT-X-ENDLIST" }) else {
            throw VideoExportManager.ExportError.liveStream
        }

        // 3. #EXT-X-DISCONTINUITY チェック
        if lines.contains(where: { $0.hasPrefix("#EXT-X-DISCONTINUITY") }) {
            throw VideoExportManager.ExportError.discontinuityNotSupported("#EXT-X-DISCONTINUITY")
        }

        var initSegment: SegmentRef?
        var segments: [SegmentRef] = []
        var totalDuration: Double = 0
        var pendingDuration: Double?
        var pendingByteRangeRaw: String?
        var nextByteOffsetByURL: [URL: Int64] = [:]

        for line in lines {
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MAP:") {
                if initSegment != nil {
                    // 複数の初期化セグメントが存在する場合は単一fMP4連結の対象外
                    throw VideoExportManager.ExportError.discontinuityNotSupported("複数の #EXT-X-MAP")
                }
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attrs["URI"], !uri.isEmpty,
                      let resolvedURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                    throw VideoExportManager.ExportError.invalidInitSegment("#EXT-X-MAP の URI が不正です")
                }
                var mapRange: ByteRange?
                if let rangeStr = attrs["BYTERANGE"] {
                    let prevEnd = nextByteOffsetByURL[resolvedURL] ?? 0
                    let parsed = try parseByteRange(rangeStr, defaultOffset: prevEnd)
                    nextByteOffsetByURL[resolvedURL] = parsed.offset + parsed.length
                    mapRange = parsed
                }
                initSegment = SegmentRef(url: resolvedURL, duration: 0, byteRange: mapRange)
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                let rawVal = String(line.dropFirst("#EXTINF:".count))
                let numberPart = rawVal.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                pendingDuration = Double(numberPart.trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRangeRaw = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            // セグメントURI行
            guard let resolvedURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                continue
            }
            let lowerPath = resolvedURL.path.lowercased()
            if lowerPath.hasSuffix(".ts") && initSegment == nil {
                throw VideoExportManager.ExportError.notFMP4Format("MPEG-TS (.ts) セグメントです")
            }

            var segByteRange: ByteRange?
            if let rangeRaw = pendingByteRangeRaw {
                let prevEnd = nextByteOffsetByURL[resolvedURL] ?? 0
                let parsed = try parseByteRange(rangeRaw, defaultOffset: prevEnd)
                nextByteOffsetByURL[resolvedURL] = parsed.offset + parsed.length
                segByteRange = parsed
                pendingByteRangeRaw = nil
            }

            let dur = pendingDuration ?? 0
            pendingDuration = nil
            totalDuration += max(dur, 0)
            segments.append(SegmentRef(url: resolvedURL, duration: dur, byteRange: segByteRange))
        }

        guard let validInit = initSegment else {
            throw VideoExportManager.ExportError.notFMP4Format("#EXT-X-MAP 初期化セグメントがありません")
        }
        guard !segments.isEmpty else {
            throw VideoExportManager.ExportError.notFMP4Format("メディアセグメントが0件です")
        }

        return ParsedMediaPlaylist(
            initSegment: validInit,
            segments: segments,
            totalDuration: totalDuration
        )
    }

    static func parseByteRange(_ raw: String, defaultOffset: Int64) throws -> ByteRange {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        let parts = cleaned.split(separator: "@", maxSplits: 1).map(String.init)
        guard let length = Int64(parts[0]), length > 0 else {
            throw VideoExportManager.ExportError.invalidInitSegment("BYTERANGE長が不正です: \(raw)")
        }
        let offset: Int64
        if parts.count == 2 {
            guard let explicitOffset = Int64(parts[1]), explicitOffset >= 0 else {
                throw VideoExportManager.ExportError.invalidInitSegment("BYTERANGEオフセットが不正です: \(raw)")
            }
            offset = explicitOffset
        } else {
            offset = defaultOffset
        }
        return ByteRange(length: length, offset: offset)
    }

    static func parseAttributeList(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey = ""
        var currentValue = ""
        var inQuotes = false
        var parsingKey = true

        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "=" && parsingKey && !inQuotes {
                parsingKey = false
            } else if ch == "," && !inQuotes {
                let k = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let v = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { result[k] = v }
                currentKey = ""
                currentValue = ""
                parsingKey = true
            } else {
                if parsingKey {
                    currentKey.append(ch)
                } else {
                    currentValue.append(ch)
                }
            }
        }
        let k = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { result[k] = v }
        return result
    }
}

// MARK: - ISO-BMFF (fMP4) ボックス構造・コーデック・タイムスタンプ検証器

enum FMP4BoxInspector {

    struct TrackInfo: Equatable {
        let trackID: UInt32
        let handlerType: String
        let codecFourCC: String
        let timescale: UInt32
    }

    struct InitSegmentInfo: Equatable {
        let tracks: [TrackInfo]
        var hasVideo: Bool { tracks.contains { $0.handlerType == "vide" } }
        var hasAudio: Bool { tracks.contains { $0.handlerType == "soun" } }
        var videoCodecs: [String] { tracks.filter { $0.handlerType == "vide" }.map(\.codecFourCC) }
        var audioCodecs: [String] { tracks.filter { $0.handlerType == "soun" }.map(\.codecFourCC) }
    }

    struct MediaSegmentInfo: Equatable {
        let trackDecodeTimes: [UInt32: UInt64]
        let moofCount: Int
        let mdatPayloadBytes: Int64
    }

    /// `#EXT-X-MAP` の初期化セグメント（ftyp + moov + mvex + trak）を解析・検証する
    static func inspectInitSegment(_ data: Data) throws -> InitSegmentInfo {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else {
            throw VideoExportManager.ExportError.invalidInitSegment("データサイズが小さすぎます (\(bytes.count)B)")
        }

        var hasFtyp = false
        var hasMoov = false
        var hasMvex = false
        var tracks: [TrackInfo] = []

        var pos = 0
        while let box = nextBox(in: bytes, from: pos, limit: bytes.count) {
            if box.type == "ftyp" || box.type == "styp" {
                hasFtyp = true
            } else if box.type == "moov" {
                hasMoov = true
                parseMoov(in: bytes, start: box.payloadStart, end: box.boxEnd, tracks: &tracks, hasMvex: &hasMvex)
            }
            pos = box.boxEnd
        }

        guard hasFtyp, hasMoov else {
            throw VideoExportManager.ExportError.invalidInitSegment("ftyp または moov ボックスが存在しません")
        }
        guard hasMvex else {
            throw VideoExportManager.ExportError.invalidInitSegment("moov 内に mvex（Fragmented MP4 拡張）が存在しません")
        }
        guard !tracks.isEmpty else {
            throw VideoExportManager.ExportError.invalidInitSegment("moov 内に有効なトラック（trak）が存在しません")
        }

        let info = InitSegmentInfo(tracks: tracks)
        guard info.hasVideo else {
            throw VideoExportManager.ExportError.invalidInitSegment("映像トラック（vide）が含まれていません")
        }

        // 対応コーデック確認（H.264 avc1 / HEVC hvc1, hev1）
        let supportedVideo = Set(["avc1", "avc3", "hvc1", "hev1", "mp4v"])
        for vc in info.videoCodecs where !vc.isEmpty && !supportedVideo.contains(vc) {
            throw VideoExportManager.ExportError.unsupportedCodec("映像コーデック \(vc) はMP4書き出し非対応です")
        }

        return info
    }

    /// 各メディアセグメント（moof + mdat）の構造と tfdt（baseMediaDecodeTime）を解析・検証し、
    /// 先頭セグメントの初期オフセット（10秒オフセット等）を 0 基準へ正規化（リベース）および mfhd 連番を整列する
    static func inspectAndNormalizeMediaSegment(
        _ data: Data,
        segmentIndex: Int,
        initialDecodeTimes: inout [UInt32: UInt64],
        lastDecodeTimes: inout [UInt32: UInt64],
        nextSequenceNumber: inout UInt32
    ) throws -> (normalizedData: Data, info: MediaSegmentInfo) {
        var bytes = [UInt8](data)
        guard bytes.count >= 16 else {
            throw VideoExportManager.ExportError.invalidMediaSegment(
                index: segmentIndex,
                reason: "サイズが小さすぎます (\(bytes.count)B)"
            )
        }
        if bytes[0] == 0x47 {
            throw VideoExportManager.ExportError.notFMP4Format("セグメント \(segmentIndex) が MPEG-TS (0x47) です")
        }

        var moofCount = 0
        var mdatPayloadBytes: Int64 = 0
        var segmentTrackDecodeTimes: [UInt32: UInt64] = [:]

        var pos = 0
        while let box = nextBox(in: bytes, from: pos, limit: bytes.count) {
            if box.type == "moof" {
                moofCount += 1
                try normalizeMoof(
                    in: &bytes,
                    start: box.payloadStart,
                    end: box.boxEnd,
                    segmentIndex: segmentIndex,
                    initialDecodeTimes: &initialDecodeTimes,
                    lastDecodeTimes: &lastDecodeTimes,
                    segmentTrackDecodeTimes: &segmentTrackDecodeTimes,
                    nextSequenceNumber: &nextSequenceNumber
                )
            } else if box.type == "mdat" {
                mdatPayloadBytes += Int64(max(0, box.boxEnd - box.payloadStart))
            }
            pos = box.boxEnd
        }

        guard moofCount > 0, mdatPayloadBytes > 0 else {
            throw VideoExportManager.ExportError.invalidMediaSegment(
                index: segmentIndex,
                reason: "moof (\(moofCount)個) または mdat (\(mdatPayloadBytes)B) が見つかりません"
            )
        }

        return (
            Data(bytes),
            MediaSegmentInfo(
                trackDecodeTimes: segmentTrackDecodeTimes,
                moofCount: moofCount,
                mdatPayloadBytes: mdatPayloadBytes
            )
        )
    }

    /// テストA用：Apple公式の保存許諾fMP4素材（映像 v2/main.mp4 + 音声 a1/main.mp4）から
    /// 単一ストリーム（映像 track_ID=1 + 音声 track_ID=2 統合型）の非暗号化 fMP4 VOD HLS 一式を生成する
    static func buildMuxedTestHLS(
        in dir: URL,
        videoInit: Data,
        videoSegments: [Data],
        audioInit: Data,
        audioSegments: [Data]
    ) throws -> URL {
        let vInitBytes = [UInt8](videoInit)
        let aInitBytes = [UInt8](audioInit)

        var ftypBox: [UInt8] = []
        var mvhdBox: [UInt8] = []
        var vTrakBox: [UInt8] = []
        var vTrexBox: [UInt8] = []

        var pos = 0
        while let box = nextBox(in: vInitBytes, from: pos, limit: vInitBytes.count) {
            let boxStart = pos
            if box.type == "ftyp" {
                ftypBox = Array(vInitBytes[boxStart..<box.boxEnd])
            } else if box.type == "moov" {
                var mpos = box.payloadStart
                while let mbox = nextBox(in: vInitBytes, from: mpos, limit: box.boxEnd) {
                    if mbox.type == "mvhd" {
                        mvhdBox = Array(vInitBytes[mpos..<mbox.boxEnd])
                    } else if mbox.type == "trak" {
                        vTrakBox = Array(vInitBytes[mpos..<mbox.boxEnd])
                    } else if mbox.type == "mvex" {
                        var xpos = mbox.payloadStart
                        while let xbox = nextBox(in: vInitBytes, from: xpos, limit: mbox.boxEnd) {
                            if xbox.type == "trex" {
                                vTrexBox = Array(vInitBytes[xpos..<xbox.boxEnd])
                            }
                            xpos = xbox.boxEnd
                        }
                    }
                    mpos = mbox.boxEnd
                }
            }
            pos = box.boxEnd
        }

        var aTrakBox: [UInt8] = []
        var aTrexBox: [UInt8] = []
        pos = 0
        while let box = nextBox(in: aInitBytes, from: pos, limit: aInitBytes.count) {
            if box.type == "moov" {
                var mpos = box.payloadStart
                while let mbox = nextBox(in: aInitBytes, from: mpos, limit: box.boxEnd) {
                    if mbox.type == "trak" {
                        aTrakBox = Array(aInitBytes[mpos..<mbox.boxEnd])
                    } else if mbox.type == "mvex" {
                        var xpos = mbox.payloadStart
                        while let xbox = nextBox(in: aInitBytes, from: xpos, limit: mbox.boxEnd) {
                            if xbox.type == "trex" {
                                aTrexBox = Array(aInitBytes[xpos..<xbox.boxEnd])
                            }
                            xpos = xbox.boxEnd
                        }
                    }
                    mpos = mbox.boxEnd
                }
            }
            pos = box.boxEnd
        }

        guard !ftypBox.isEmpty, mvhdBox.count >= 16, !vTrakBox.isEmpty, !aTrakBox.isEmpty,
              vTrexBox.count >= 16, aTrexBox.count >= 16 else {
            throw VideoExportManager.ExportError.invalidInitSegment("テストA用統合init生成に必要なボックスが不足しています")
        }

        // mvhd の next_track_ID を 3 に更新
        writeUInt32(&mvhdBox, at: mvhdBox.count - 4, value: 3)

        // 音声 trak 内の tkhd.track_ID を 2 に更新
        var tpos = 8
        while let tbox = nextBox(in: aTrakBox, from: tpos, limit: aTrakBox.count) {
            if tbox.type == "tkhd" {
                let ver = aTrakBox[tbox.payloadStart]
                let tidOffset = tbox.payloadStart + (ver == 1 ? 20 : 12)
                if tidOffset + 4 <= tbox.boxEnd {
                    writeUInt32(&aTrakBox, at: tidOffset, value: 2)
                }
            }
            tpos = tbox.boxEnd
        }

        // 音声 trex の track_ID を 2 に更新
        writeUInt32(&aTrexBox, at: 12, value: 2)

        // mvex = header(8) + vTrex + aTrex
        var mvexBox = makeBoxHeader(type: "mvex", payloadLength: vTrexBox.count + aTrexBox.count)
        mvexBox.append(contentsOf: vTrexBox)
        mvexBox.append(contentsOf: aTrexBox)

        // moov = header(8) + mvhd + vTrak + aTrak + mvex
        let moovPayloadCount = mvhdBox.count + vTrakBox.count + aTrakBox.count + mvexBox.count
        var moovBox = makeBoxHeader(type: "moov", payloadLength: moovPayloadCount)
        moovBox.append(contentsOf: mvhdBox)
        moovBox.append(contentsOf: vTrakBox)
        moovBox.append(contentsOf: aTrakBox)
        moovBox.append(contentsOf: mvexBox)

        var muxedInit = ftypBox
        muxedInit.append(contentsOf: moovBox)
        let initURL = dir.appendingPathComponent("init.mp4")
        try Data(muxedInit).write(to: initURL)

        let count = min(videoSegments.count, audioSegments.count)
        var mediaLines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:6",
            "#EXT-X-MEDIA-SEQUENCE:1",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"init.mp4\""
        ]

        for idx in 0..<count {
            var aSegBytes = [UInt8](audioSegments[idx])
            // 音声セグメント内の moof -> traf -> tfhd.track_ID を 2 に更新
            var apos = 0
            while let box = nextBox(in: aSegBytes, from: apos, limit: aSegBytes.count) {
                if box.type == "moof" {
                    var mpos = box.payloadStart
                    while let mbox = nextBox(in: aSegBytes, from: mpos, limit: box.boxEnd) {
                        if mbox.type == "traf" {
                            var trpos = mbox.payloadStart
                            while let trbox = nextBox(in: aSegBytes, from: trpos, limit: mbox.boxEnd) {
                                if trbox.type == "tfhd", trbox.payloadStart + 8 <= trbox.boxEnd {
                                    writeUInt32(&aSegBytes, at: trbox.payloadStart + 4, value: 2)
                                }
                                trpos = trbox.boxEnd
                            }
                        }
                        mpos = mbox.boxEnd
                    }
                }
                apos = box.boxEnd
            }

            var muxedSeg = Data(videoSegments[idx])
            muxedSeg.append(contentsOf: aSegBytes)
            let segName = "seg\(idx + 1).m4s"
            try muxedSeg.write(to: dir.appendingPathComponent(segName))
            mediaLines.append("#EXTINF:6.00000,")
            mediaLines.append(segName)
        }
        mediaLines.append("#EXT-X-ENDLIST")

        let mediaURL = dir.appendingPathComponent("prog_index.m3u8")
        try mediaLines.joined(separator: "\n").write(to: mediaURL, atomically: true, encoding: .utf8)

        let masterLines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-STREAM-INF:BANDWIDTH=660000,AVERAGE-BANDWIDTH=640000,CODECS=\"avc1.640015,mp4a.40.2\",RESOLUTION=480x270,FRAME-RATE=30.000",
            "prog_index.m3u8"
        ]
        let masterURL = dir.appendingPathComponent("master.m3u8")
        try masterLines.joined(separator: "\n").write(to: masterURL, atomically: true, encoding: .utf8)
        return masterURL
    }

    // MARK: - 内部ボックスパーサー

    private struct BoxHeader {
        let type: String
        let payloadStart: Int
        let boxEnd: Int
    }

    private static func nextBox(in bytes: [UInt8], from pos: Int, limit: Int) -> BoxHeader? {
        guard pos + 8 <= limit else { return nil }
        let size32 = readUInt32(bytes, at: pos)
        let type = String(bytes: bytes[pos + 4 ..< pos + 8], encoding: .ascii) ?? "????"
        var headerSize = 8
        let totalSize: Int

        if size32 == 1 {
            guard pos + 16 <= limit else { return nil }
            let size64 = readUInt64(bytes, at: pos + 8)
            guard size64 <= UInt64(Int.max) else { return nil }
            totalSize = Int(size64)
            headerSize = 16
        } else if size32 == 0 {
            totalSize = limit - pos
        } else {
            totalSize = Int(size32)
        }

        guard totalSize >= headerSize, pos + totalSize <= limit else { return nil }
        return BoxHeader(type: type, payloadStart: pos + headerSize, boxEnd: pos + totalSize)
    }

    private static func parseMoov(
        in bytes: [UInt8],
        start: Int,
        end: Int,
        tracks: inout [TrackInfo],
        hasMvex: inout Bool
    ) {
        var pos = start
        while let box = nextBox(in: bytes, from: pos, limit: end) {
            if box.type == "mvex" {
                hasMvex = true
            } else if box.type == "trak" {
                if let track = parseTrak(in: bytes, start: box.payloadStart, end: box.boxEnd) {
                    tracks.append(track)
                }
            }
            pos = box.boxEnd
        }
    }

    private static func parseTrak(in bytes: [UInt8], start: Int, end: Int) -> TrackInfo? {
        var trackID: UInt32 = 0
        var handlerType = ""
        var codecFourCC = ""
        var timescale: UInt32 = 0

        var pos = start
        while let box = nextBox(in: bytes, from: pos, limit: end) {
            if box.type == "tkhd" {
                let ver = box.payloadStart < box.boxEnd ? bytes[box.payloadStart] : 0
                let tidOffset = box.payloadStart + (ver == 1 ? 20 : 12)
                if tidOffset + 4 <= box.boxEnd {
                    trackID = readUInt32(bytes, at: tidOffset)
                }
            } else if box.type == "mdia" {
                var mdiaPos = box.payloadStart
                while let mbox = nextBox(in: bytes, from: mdiaPos, limit: box.boxEnd) {
                    if mbox.type == "mdhd" {
                        let ver = mbox.payloadStart < mbox.boxEnd ? bytes[mbox.payloadStart] : 0
                        let tsOffset = mbox.payloadStart + (ver == 1 ? 20 : 12)
                        if tsOffset + 4 <= mbox.boxEnd {
                            timescale = readUInt32(bytes, at: tsOffset)
                        }
                    } else if mbox.type == "hdlr" {
                        if mbox.payloadStart + 12 <= mbox.boxEnd {
                            handlerType = String(
                                bytes: bytes[mbox.payloadStart + 8 ..< mbox.payloadStart + 12],
                                encoding: .ascii
                            ) ?? ""
                        }
                    } else if mbox.type == "minf" {
                        codecFourCC = parseMinfForCodec(in: bytes, start: mbox.payloadStart, end: mbox.boxEnd)
                    }
                    mdiaPos = mbox.boxEnd
                }
            }
            pos = box.boxEnd
        }

        guard !handlerType.isEmpty else { return nil }
        return TrackInfo(
            trackID: trackID,
            handlerType: handlerType,
            codecFourCC: codecFourCC,
            timescale: timescale
        )
    }

    private static func parseMinfForCodec(in bytes: [UInt8], start: Int, end: Int) -> String {
        var pos = start
        while let box = nextBox(in: bytes, from: pos, limit: end) {
            if box.type == "stbl" {
                var stblPos = box.payloadStart
                while let sbox = nextBox(in: bytes, from: stblPos, limit: box.boxEnd) {
                    if sbox.type == "stsd", sbox.payloadStart + 16 <= sbox.boxEnd {
                        return String(
                            bytes: bytes[sbox.payloadStart + 12 ..< sbox.payloadStart + 16],
                            encoding: .ascii
                        ) ?? ""
                    }
                    stblPos = sbox.boxEnd
                }
            }
            pos = box.boxEnd
        }
        return ""
    }

    private static func normalizeMoof(
        in bytes: inout [UInt8],
        start: Int,
        end: Int,
        segmentIndex: Int,
        initialDecodeTimes: inout [UInt32: UInt64],
        lastDecodeTimes: inout [UInt32: UInt64],
        segmentTrackDecodeTimes: inout [UInt32: UInt64],
        nextSequenceNumber: inout UInt32
    ) throws {
        var pos = start
        while let box = nextBox(in: bytes, from: pos, limit: end) {
            if box.type == "mfhd", box.payloadStart + 8 <= box.boxEnd {
                writeUInt32(&bytes, at: box.payloadStart + 4, value: nextSequenceNumber)
                nextSequenceNumber += 1
            } else if box.type == "traf" {
                var currentTrackID: UInt32?
                var currentDTS: UInt64?
                var tfdtVersion: UInt8 = 0
                var tfdtValueOffset: Int?

                var trafPos = box.payloadStart
                while let tbox = nextBox(in: bytes, from: trafPos, limit: box.boxEnd) {
                    if tbox.type == "tfhd", tbox.payloadStart + 8 <= tbox.boxEnd {
                        currentTrackID = readUInt32(bytes, at: tbox.payloadStart + 4)
                    } else if tbox.type == "tfdt", tbox.payloadStart + 8 <= tbox.boxEnd {
                        let ver = bytes[tbox.payloadStart]
                        tfdtVersion = ver
                        tfdtValueOffset = tbox.payloadStart + 4
                        if ver == 1, tbox.payloadStart + 12 <= tbox.boxEnd {
                            currentDTS = readUInt64(bytes, at: tbox.payloadStart + 4)
                        } else {
                            currentDTS = UInt64(readUInt32(bytes, at: tbox.payloadStart + 4))
                        }
                    }
                    trafPos = tbox.boxEnd
                }

                if let tid = currentTrackID, let dts = currentDTS {
                    if let prevDTS = lastDecodeTimes[tid], dts < prevDTS {
                        throw VideoExportManager.ExportError.timestampDiscontinuity(
                            trackID: tid,
                            segmentIndex: segmentIndex,
                            previousDTS: prevDTS,
                            currentDTS: dts
                        )
                    }
                    lastDecodeTimes[tid] = dts
                    if initialDecodeTimes[tid] == nil {
                        initialDecodeTimes[tid] = dts
                    }
                    let baseDTS = initialDecodeTimes[tid] ?? 0
                    let rebasedDTS = dts >= baseDTS ? (dts - baseDTS) : 0
                    if let valOff = tfdtValueOffset {
                        if tfdtVersion == 1 {
                            writeUInt64(&bytes, at: valOff, value: rebasedDTS)
                        } else {
                            writeUInt32(&bytes, at: valOff, value: UInt32(clamping: rebasedDTS))
                        }
                    }
                    if segmentTrackDecodeTimes[tid] == nil {
                        segmentTrackDecodeTimes[tid] = rebasedDTS
                    }
                }
            }
            pos = box.boxEnd
        }
    }

    private static func makeBoxHeader(type: String, payloadLength: Int) -> [UInt8] {
        let total = UInt32(8 + payloadLength)
        var out: [UInt8] = [0, 0, 0, 0]
        writeUInt32(&out, at: 0, value: total)
        out.append(contentsOf: type.utf8.prefix(4))
        return out
    }

    private static func writeUInt32(_ bytes: inout [UInt8], at offset: Int, value: UInt32) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeUInt64(_ bytes: inout [UInt8], at offset: Int, value: UInt64) {
        writeUInt32(&bytes, at: offset, value: UInt32((value >> 32) & 0xFFFFFFFF))
        writeUInt32(&bytes, at: offset + 4, value: UInt32(value & 0xFFFFFFFF))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (UInt64(readUInt32(bytes, at: offset)) << 32)
            | UInt64(readUInt32(bytes, at: offset + 4))
    }
}
