import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var translator = LiveTranslator()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                controlBar
            }
            .navigationTitle("Dịch Anh → Việt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Xóa") { translator.clear() }
                        .disabled(translator.lines.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Cài đặt")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(translator: translator)
            }
            .alert("Thông báo", isPresented: Binding(
                get: { translator.alertMessage != nil },
                set: { if !$0 { translator.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(translator.alertMessage ?? "")
            }
        }
        .translationTask(translator.translationConfig) { session in
            await translator.runTranslationLoop(session: session)
        }
    }

    // MARK: Danh sách câu

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if translator.lines.isEmpty && translator.partialText.isEmpty {
                        emptyState
                    }
                    ForEach(translator.lines) { line in
                        LineCard(line: line)
                            .id(line.id)
                    }
                    if !translator.partialText.isEmpty {
                        Text(translator.partialText)
                            .font(.body)
                            .italic()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: translator.lines) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: translator.partialText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cách dùng", systemImage: "info.circle")
                .font(.headline)
            Text("1. Chạm nút **Bắt đầu nghe** ở dưới.")
            Text("2. Để điện thoại gần người nói tiếng Anh.")
            Text("3. Hết mỗi câu, bản dịch tiếng Việt hiện ra và được đọc to. Micro vẫn tiếp tục nghe câu tiếp theo.")
            Text("Mẹo: đeo tai nghe để nghe bản dịch rõ hơn và nhận dạng chính xác hơn.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Thanh điều khiển

    private var controlBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(translator.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(translator.statusText)
                    .font(.footnote)
                    .lineLimit(2)
                Spacer()
                if translator.isSpeaking {
                    Label("Đang đọc", systemImage: "speaker.wave.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
            }
            if !translator.translatorNote.isEmpty {
                Text(translator.translatorNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                translator.toggle()
            } label: {
                Label(translator.isRunning ? "Dừng" : "Bắt đầu nghe",
                      systemImage: translator.isRunning ? "stop.fill" : "mic.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(translator.isRunning ? .red : .blue)
        }
        .padding()
        .background(.bar)
    }
}

struct LineCard: View {
    let line: TranslatedLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.english)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let vi = line.vietnamese {
                Text(vi)
                    .font(.title3.weight(.semibold))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .textSelection(.enabled)
    }
}

// MARK: - Cài đặt

struct SettingsView: View {
    @ObservedObject var translator: LiveTranslator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Đọc bản dịch ra loa", isOn: $translator.speakVietnamese)
                    VStack(alignment: .leading) {
                        Text("Tốc độ đọc")
                        HStack {
                            Text("Chậm").font(.caption)
                            Slider(value: $translator.speechRate, in: 0.38...0.62)
                            Text("Nhanh").font(.caption)
                        }
                    }
                    LabeledContent("Giọng hiện tại", value: translator.voiceName)
                    Button("Nghe thử giọng đọc") { translator.testVoice() }
                } header: {
                    Text("Giọng đọc tiếng Việt")
                } footer: {
                    Text("Muốn giọng hay hơn: Cài đặt iPhone → Trợ năng → Nội dung được đọc → Giọng nói → Tiếng Việt → tải giọng có chữ “Nâng cao”. Sau đó mở lại app.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Chốt câu sau khi im lặng \(translator.pauseSeconds, specifier: "%.1f") giây")
                        Slider(value: $translator.pauseSeconds, in: 0.5...2.0, step: 0.1)
                    }
                } header: {
                    Text("Ngắt câu")
                } footer: {
                    Text("Ngắn hơn: dịch nhanh hơn nhưng dễ cắt ngang câu. Dài hơn: câu trọn vẹn hơn nhưng chờ lâu hơn. Câu có dấu chấm được chốt ngay, không phải chờ.")
                }

                Section {
                    Toggle("Khử tiếng vọng", isOn: $translator.echoCancellation)
                    Toggle("Tạm ngưng nghe khi đang đọc", isOn: $translator.muteMicWhileSpeaking)
                } header: {
                    Text("Micro và loa")
                } footer: {
                    Text("“Khử tiếng vọng” giúp micro không nghe lại tiếng Việt phát ra từ loa, nên app vừa đọc vừa nghe được câu mới. Nếu dùng loa ngoài mà thấy app dịch lung tung tiếng vọng, hãy bật “Tạm ngưng nghe khi đang đọc” (khi đó câu nói chen vào lúc đang đọc có thể bị sót) hoặc đeo tai nghe.")
                }
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }
}
