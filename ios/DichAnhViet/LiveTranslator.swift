import Foundation
import AVFoundation
import Speech
import UIKit
import Translation

// MARK: - Dữ liệu

struct TranslatedLine: Identifiable, Equatable {
    let id = UUID()
    let english: String
    var vietnamese: String?
}

struct TranslationJob {
    let lineID: UUID
    let text: String
}

// MARK: - Cầu nối luồng âm thanh -> bộ nhận dạng

/// Giữ request nhận dạng hiện tại. Luồng âm thanh (micro) đẩy dữ liệu vào đây,
/// luồng chính có thể đổi request bất cứ lúc nào mà không làm mất âm thanh.
final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var muted = false

    func setRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = newRequest; lock.unlock()
    }

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let target = muted ? nil : request
        lock.unlock()
        target?.append(buffer)
    }
}

// MARK: - Phát giọng đọc qua AVAudioEngine (để bộ khử tiếng vọng hoạt động)

/// Giọng đọc được phát qua cùng AVAudioEngine với micro, nhờ vậy chế độ
/// voice processing của iOS biết loa đang phát gì và trừ nó khỏi micro.
final class BufferPlayer: @unchecked Sendable {
    let node = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var active = false

    func setActive(_ value: Bool) {
        lock.lock(); active = value; lock.unlock()
        if !value { node.stop() }
    }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active, buffer.frameLength > 0, let output = convert(buffer) else { return }
        node.scheduleBuffer(output, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    /// Đặt một mẩu im lặng rất ngắn ở cuối câu; khi nó phát xong nghĩa là câu đã đọc xong.
    func scheduleEndMarker(_ done: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard active, let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) else {
            done(); return
        }
        silent.frameLength = 64
        if let channel = silent.floatChannelData?[0] {
            for i in 0..<64 { channel[i] = 0 }
        }
        node.scheduleBuffer(silent, completionCallbackType: .dataPlayedBack) { _ in done() }
        if !node.isPlaying { node.play() }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converterInput != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            converterInput = input.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return (error == nil && output.frameLength > 0) ? output : nil
    }
}

// MARK: - Dịch trực tuyến (dự phòng)

enum OnlineTranslator {
    /// Dùng khi bộ dịch của Apple chưa sẵn sàng (chưa tải gói ngôn ngữ…).
    static func translate(_ text: String) async -> String? {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "en"),
            URLQueryItem(name: "tl", value: "vi"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let parts = json.first as? [Any] else { return nil }
            let result = parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }
}

// MARK: - Bộ điều khiển chính

@MainActor
final class LiveTranslator: NSObject, ObservableObject {

    // Trạng thái hiển thị
    @Published private(set) var lines: [TranslatedLine] = []
    @Published private(set) var partialText = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var statusText = "Chạm “Bắt đầu” rồi để người nói tiếng Anh"
    @Published private(set) var translatorNote = ""
    @Published var alertMessage: String?

    // Cài đặt (tự lưu lại)
    @Published var speakVietnamese: Bool { didSet { defaults.set(speakVietnamese, forKey: "speakVietnamese") } }
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    @Published var pauseSeconds: Double { didSet { defaults.set(pauseSeconds, forKey: "pauseSeconds") } }
    @Published var echoCancellation: Bool {
        didSet {
            defaults.set(echoCancellation, forKey: "echoCancellation")
            if isRunning { restartAll() }
        }
    }
    @Published var muteMicWhileSpeaking: Bool {
        didSet {
            defaults.set(muteMicWhileSpeaking, forKey: "muteMicWhileSpeaking")
            updateMute()
        }
    }

    let translationConfig = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "vi")
    )

    var voiceName: String {
        guard let v = vietnameseVoice else { return "Chưa có giọng tiếng Việt" }
        let quality: String
        switch v.quality {
        case .premium: quality = "cao cấp"
        case .enhanced: quality = "nâng cao"
        default: quality = "cơ bản"
        }
        return "\(v.name) (\(quality))"
    }

    // Âm thanh
    private let defaults = UserDefaults.standard
    private let engine = AVAudioEngine()
    private let bufferPlayer = BufferPlayer()
    private var playerAttached = false
    private let feed = RecognitionFeed()
    private let speaker = AVSpeechSynthesizer()   // đọc trực tiếp ra loa
    private let writer = AVSpeechSynthesizer()    // tạo âm thanh để phát qua engine (có khử vọng)
    private var vietnameseVoice: AVSpeechSynthesisVoice?

    // Nhận dạng
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var committedWordCount = 0
    private var silenceTask: Task<Void, Never>?
    private var failureStreak = 0

    // Dịch và đọc
    private var jobContinuation: AsyncStream<TranslationJob>.Continuation?
    private var nextSpeakIndex = 0
    private var activeSpeech = Set<UUID>()
    private var utteranceIDs: [ObjectIdentifier: UUID] = [:]

    private var observers: [NSObjectProtocol] = []

    override init() {
        let d = UserDefaults.standard
        speakVietnamese = d.object(forKey: "speakVietnamese") as? Bool ?? true
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        pauseSeconds = d.object(forKey: "pauseSeconds") as? Double ?? 0.8
        echoCancellation = d.object(forKey: "echoCancellation") as? Bool ?? true
        muteMicWhileSpeaking = d.object(forKey: "muteMicWhileSpeaking") as? Bool ?? false
        super.init()
        speaker.delegate = self
        vietnameseVoice = Self.bestVietnameseVoice()
        observeSystemEvents()
    }

    // MARK: Bắt đầu / dừng

    func toggle() {
        if isRunning {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRunning else { return }
        statusText = "Đang xin quyền micro…"
        guard await Self.requestSpeechPermission() else {
            alertMessage = "Ứng dụng chưa được phép dùng Nhận dạng giọng nói.\nVào Cài đặt → Dịch Anh Việt → bật Nhận dạng lời nói."
            statusText = "Thiếu quyền nhận dạng giọng nói"
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            alertMessage = "Ứng dụng chưa được phép dùng micro.\nVào Cài đặt → Dịch Anh Việt → bật Micrô."
            statusText = "Thiếu quyền micro"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            alertMessage = "Nhận dạng tiếng Anh chưa sẵn sàng. Kiểm tra kết nối Internet, hoặc vào Cài đặt → Cài đặt chung → Bàn phím → bật Đọc chính tả."
            statusText = "Nhận dạng chưa sẵn sàng"
            return
        }
        vietnameseVoice = Self.bestVietnameseVoice()
        do {
            try configureAudioSession()
            try startEngine()
        } catch {
            tearDownAudio()
            alertMessage = "Không mở được micro: \(error.localizedDescription)"
            statusText = "Lỗi micro"
            return
        }
        isRunning = true
        failureStreak = 0
        nextSpeakIndex = lines.count
        UIApplication.shared.isIdleTimerDisabled = true
        startRecognitionTask()
        statusText = "Đang nghe tiếng Anh…"
    }

    func stop() {
        guard isRunning else { return }
        flushPending()
        isRunning = false
        silenceTask?.cancel()
        generation += 1
        task?.cancel()
        task = nil
        feed.setRequest(nil)
        tearDownAudio()
        speaker.stopSpeaking(at: .immediate)
        writer.stopSpeaking(at: .immediate)
        activeSpeech.removeAll()
        utteranceIDs.removeAll()
        isSpeaking = false
        updateMute()
        nextSpeakIndex = lines.count
        UIApplication.shared.isIdleTimerDisabled = false
        statusText = "Đã dừng"
    }

    func clear() {
        lines.removeAll()
        partialText = ""
        nextSpeakIndex = 0
        if isRunning {
            // Bỏ phần đang nghe dở để bắt đầu sạch
            startRecognitionTask()
        }
    }

    func testVoice() {
        speak("Xin chào, đây là giọng đọc tiếng Việt của ứng dụng.", force: true)
    }

    private func restartAll() {
        stop()
        Task { await start() }
    }

    // MARK: Âm thanh

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // defaultToSpeaker: phát ra loa ngoài thay vì loa thoại.
        // allowBluetoothA2DP: tai nghe Bluetooth phát nhạc chất lượng cao, micro vẫn là micro điện thoại.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != echoCancellation {
            try input.setVoiceProcessingEnabled(echoCancellation)
        }
        if !playerAttached {
            engine.attach(bufferPlayer.node)
            engine.connect(bufferPlayer.node, to: engine.mainMixerNode, format: bufferPlayer.format)
            playerAttached = true
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "DichAnhViet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy micro"])
        }
        Self.installTap(on: input, format: format, feed: feed)
        engine.prepare()
        try engine.start()
        bufferPlayer.setActive(true)
    }

    private func tearDownAudio() {
        bufferPlayer.setActive(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, feed: RecognitionFeed) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            feed.append(buffer)
        }
    }

    nonisolated private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        // Có cuộc gọi đến, Siri… -> dừng lại
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop()
                self.statusText = "Bị gián đoạn (cuộc gọi…). Chạm Bắt đầu để tiếp tục"
            }
        })
        // Cắm/rút tai nghe -> khởi động lại âm thanh
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.restartAll()
            }
        })
    }

    // MARK: Nhận dạng giọng nói

    private func startRecognitionTask() {
        task?.cancel()
        task = nil
        silenceTask?.cancel()
        generation += 1
        let currentGeneration = generation
        committedWordCount = 0
        partialText = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true   // nhanh hơn, không giới hạn 1 phút
        }
        feed.setRequest(request)

        guard let recognizer else { return }
        task = Self.makeTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, failed in
            Task { @MainActor in
                self?.handleResult(generation: currentGeneration, text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    nonisolated private static func makeTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private func handleResult(generation gen: Int, text: String?, isFinal: Bool, failed: Bool) {
        guard gen == generation, isRunning else { return }

        if let text {
            failureStreak = 0
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let start = min(committedWordCount, words.count)
            var pending = Array(words[start...])

            // Chốt ngay những câu đã có dấu chấm/hỏi/than, không cần chờ người nói ngừng
            if let cut = Self.sentenceCut(in: pending) {
                commit(pending[...cut].joined(separator: " "))
                committedWordCount = start + cut + 1
                pending = Array(pending[(cut + 1)...])
            }
            // Câu quá dài mà không ngắt -> chốt luôn để không phải chờ
            if pending.count >= 35 {
                commit(pending.joined(separator: " "))
                committedWordCount = words.count
                pending = []
            }
            partialText = pending.joined(separator: " ")
            scheduleSilenceCommit()
        }

        if isFinal || failed {
            flushPending()
            if failed { failureStreak += 1 }
            if failureStreak > 8 {
                statusText = "Nhận dạng đang gặp lỗi, đang thử lại…"
            }
            let delay: Double = failed ? min(0.25 * Double(failureStreak), 2.0) : 0
            Task { [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, self.isRunning, gen == self.generation else { return }
                self.startRecognitionTask()
            }
        }
    }

    /// Vị trí từ cuối cùng kết thúc câu, nếu phía sau đã có thêm ít nhất 2 từ
    /// (dấu câu lúc đó mới ổn định).
    private static func sentenceCut(in words: [String]) -> Int? {
        guard words.count >= 3 else { return nil }
        let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "vs.", "e.g.", "i.e.", "etc.", "prof."]
        for i in stride(from: words.count - 3, through: 0, by: -1) {
            let w = words[i]
            guard let last = w.last, ".?!".contains(last) else { continue }
            if abbreviations.contains(w.lowercased()) { continue }
            return i
        }
        return nil
    }

    private func scheduleSilenceCommit() {
        silenceTask?.cancel()
        guard !partialText.isEmpty else { return }
        let gen = generation
        let wait = pauseSeconds
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            guard let self, self.isRunning, gen == self.generation else { return }
            // Người nói đã ngừng -> chốt câu và mở phiên nghe mới ngay lập tức
            self.flushPending()
            self.startRecognitionTask()
        }
    }

    private func flushPending() {
        let text = partialText.trimmingCharacters(in: .whitespaces)
        partialText = ""
        if !text.isEmpty { commit(text) }
    }

    // MARK: Dịch

    private func commit(_ english: String) {
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.rangeOfCharacter(from: .letters) != nil else { return }
        let line = TranslatedLine(english: text)
        lines.append(line)
        trimHistory()
        let job = TranslationJob(lineID: line.id, text: text)
        if let jobContinuation {
            jobContinuation.yield(job)
        } else {
            Task { [weak self] in
                let vi = await OnlineTranslator.translate(text)
                self?.deliver(lineID: line.id, vietnamese: vi ?? "[Không dịch được, kiểm tra Internet]")
            }
        }
    }

    /// Chạy suốt thời gian app mở. Dịch bằng bộ dịch của Apple (trên máy, miễn phí),
    /// lỗi thì chuyển sang dịch trực tuyến.
    func runTranslationLoop(session: TranslationSession) async {
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationJob.self)
        jobContinuation = continuation
        defer { jobContinuation = nil }

        do {
            try await session.prepareTranslation()   // lần đầu: hỏi tải gói Anh - Việt
            translatorNote = "Dịch bằng Apple (ngay trên máy)"
        } catch {
            translatorNote = "Chưa tải gói dịch Apple, đang dịch trực tuyến"
        }

        for await job in stream {
            var result: String?
            do {
                result = try await session.translate(job.text).targetText
            } catch {
                result = nil
            }
            if result?.isEmpty ?? true {
                result = await OnlineTranslator.translate(job.text)
            }
            deliver(lineID: job.lineID, vietnamese: result ?? "[Không dịch được, kiểm tra Internet]")
        }
    }

    private func deliver(lineID: UUID, vietnamese: String) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index].vietnamese = vietnamese
        // Đọc đúng thứ tự câu
        while nextSpeakIndex < lines.count, let vi = lines[nextSpeakIndex].vietnamese {
            speak(vi)
            nextSpeakIndex += 1
        }
    }

    private func trimHistory() {
        let maxLines = 300
        guard lines.count > maxLines else { return }
        let drop = lines.count - maxLines
        lines.removeFirst(drop)
        nextSpeakIndex = max(0, nextSpeakIndex - drop)
    }

    // MARK: Đọc tiếng Việt

    private func speak(_ text: String, force: Bool = false) {
        guard force || (speakVietnamese && isRunning) else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = vietnameseVoice ?? AVSpeechSynthesisVoice(language: "vi-VN")
        // Nhiều câu đang chờ đọc -> đọc nhanh hơn một chút để đuổi kịp người nói
        let backlog = Double(activeSpeech.count)
        utterance.rate = Float(min(speechRate + backlog * 0.04, 0.66))

        let id = UUID()
        activeSpeech.insert(id)
        isSpeaking = true
        updateMute()

        if echoCancellation && engine.isRunning {
            Self.write(utterance, with: writer, into: bufferPlayer) { [weak self] in
                Task { @MainActor in self?.finishSpeech(id) }
            }
        } else {
            utteranceIDs[ObjectIdentifier(utterance)] = id
            speaker.speak(utterance)
        }

        // Phòng hờ: nếu vì lý do nào đó không nhận được tín hiệu đọc xong
        let estimate = 4.0 + Double(text.count) * 0.12 * (backlog + 1)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(estimate))
            self?.finishSpeech(id)
        }
    }

    nonisolated private static func write(_ utterance: AVSpeechUtterance,
                                          with synthesizer: AVSpeechSynthesizer,
                                          into player: BufferPlayer,
                                          done: @escaping @Sendable () -> Void) {
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                player.scheduleEndMarker(done)
            } else {
                player.schedule(pcm)
            }
        }
    }

    private func finishSpeech(_ id: UUID) {
        guard activeSpeech.remove(id) != nil else { return }
        isSpeaking = !activeSpeech.isEmpty
        updateMute()
    }

    private func updateMute() {
        feed.setMuted(muteMicWhileSpeaking && isSpeaking)
    }

    private static func bestVietnameseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("vi") }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "vi-VN")
    }
}

// MARK: - Nhận tín hiệu đọc xong (chế độ không khử vọng)

extension LiveTranslator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.speechEnded(key) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.speechEnded(key) }
    }

    private func speechEnded(_ key: ObjectIdentifier) {
        if let id = utteranceIDs.removeValue(forKey: key) {
            finishSpeech(id)
        }
    }
}
