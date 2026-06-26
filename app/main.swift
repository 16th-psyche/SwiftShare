//
//  SwiftShare — menu bar app
//
//  A single-file AppKit + SwiftUI menu bar utility for URL shortening and
//  temporary file/folder uploads. Compiled with `swiftc` (see ../build.sh) —
//  no Xcode project required.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Upload host configuration

/// One entry in the §4-style fallback matrix. The uploader walks the list and
/// stops at the first host that returns a usable URL.
struct UploadHost: Sendable {
    let name: String
    let url: URL
    let retention: String
    let fileFieldName: String
    let extraFields: [String: String]
    let userAgent: String?
    let maxBytes: Int64?
}

let uploadHosts: [UploadHost] = [
    UploadHost(
        name: "litterbox.catbox.moe",
        url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!,
        retention: "72 hours",
        fileFieldName: "fileToUpload",
        extraFields: ["reqtype": "fileupload", "time": "72h"],
        userAgent: nil,
        maxBytes: 200 * 1024 * 1024
    ),
    UploadHost(
        name: "0x0.st",
        url: URL(string: "https://0x0.st")!,
        retention: "30 days",
        fileFieldName: "file",
        extraFields: [:],
        userAgent: "SwiftShare/1.0",
        maxBytes: 512 * 1024 * 1024
    ),
]

// MARK: - URL shorteners

/// Shorteners that perform a DIRECT redirect (no interstitial / preview page),
/// tried in order. is.gd is the established primary; da.gd is the fallback.
/// Both expose a no-auth API that returns the short URL as plain text.
let shortenerHosts: [(name: String, base: String)] = [
    ("is.gd", "https://is.gd/create.php?format=simple"),
    ("da.gd", "https://da.gd/s"),
]

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case shorten, upload }
    var id = UUID()
    let kind: Kind
    let title: String   // original URL (shorten) or file name (upload)
    let link: String
    let date: Date
}

// MARK: - Staged upload item

/// One file/folder staged for the next upload. Items upload together as a single
/// bundle, so an item is only ever `.pending` or `.failed` (flagged too-large).
struct StagedItem: Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case pending
        case failed(String)
    }
    let id = UUID()
    let url: URL
    let name: String
    let sizeText: String
    let byteSize: Int64?                      // nil for folders (size known after zip)
    var state: State = .pending

    var isFailed: Bool { if case .failed = state { return true } else { return false } }
}

// MARK: - Blocking helpers (run off the main actor via Task.detached)

enum SwiftShareError: LocalizedError {
    case zipFailed
    case hostRejected
    case noHost

    var errorDescription: String? {
        switch self {
        case .zipFailed:    return "Could not compress the folder."
        case .hostRejected: return "The upload host rejected the file."
        case .noHost:       return "All upload hosts are unavailable. Please try again."
        }
    }
}

/// Compress a directory into /tmp/<name>.zip and return the archive URL.
func zipDirectory(_ dir: URL) throws -> URL {
    let name = dir.lastPathComponent
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
    try? FileManager.default.removeItem(at: out)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    proc.arguments = ["-r", "-q", out.path, name]
    proc.currentDirectoryURL = dir.deletingLastPathComponent()
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { throw SwiftShareError.zipFailed }
    return out
}

/// Bundle several files/folders (possibly from different parent directories)
/// into a single /tmp archive and return its URL. Each item is appended with
/// its own basename as the top-level entry by running `zip` from its parent.
func zipMultiple(_ urls: [URL], archiveName: String) throws -> URL {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(archiveName)
    try? FileManager.default.removeItem(at: out)

    for url in urls {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-r", "-q", out.path, url.lastPathComponent]
        proc.currentDirectoryURL = url.deletingLastPathComponent()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw SwiftShareError.zipFailed }
    }
    return out
}

/// Stream a multipart/form-data body to a temp file (so large uploads don't
/// sit in memory) and return its URL.
func buildMultipartBody(
    boundary: String,
    fields: [String: String],
    fileField: String,
    fileURL: URL,
    fileName: String
) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ss-body-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    let out = try FileHandle(forWritingTo: tmp)
    defer { try? out.close() }

    func write(_ s: String) { out.write(Data(s.utf8)) }

    for (key, value) in fields {
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
        write("\(value)\r\n")
    }

    write("--\(boundary)\r\n")
    write("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
    write("Content-Type: application/octet-stream\r\n\r\n")

    let input = try FileHandle(forReadingFrom: fileURL)
    defer { try? input.close() }
    while true {
        let chunk = input.readData(ofLength: 1024 * 1024)
        if chunk.isEmpty { break }
        out.write(chunk)
    }

    write("\r\n--\(boundary)--\r\n")
    return tmp
}

/// Raw byte size for a file, or nil for a folder (size is only known after zipping).
func rawByteSize(of url: URL) -> Int64? {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if isDir.boolValue { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
}

/// Human-readable size for a file or directory path.
func humanReadableSize(of url: URL) -> String {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if isDir.boolValue { return "Folder" }
    guard let bytes = rawByteSize(of: url) else { return "" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Largest upload cap across all hosts (used for an up-front size check).
let largestHostCap: Int64 = uploadHosts.compactMap { $0.maxBytes }.max() ?? .max

// MARK: - Upload progress delegate

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - View model

@MainActor
final class SwiftShareModel: ObservableObject {
    enum Tab: Hashable { case shorten, upload, history }

    @Published var tab: Tab = .shorten

    // Shortener state
    @Published var urlInput = ""
    @Published var shortResult: String?
    @Published var shortError: String?
    @Published var isShortening = false

    // Upload state — a set of staged inputs that upload together as one bundle.
    @Published var items: [StagedItem] = []
    @Published var isUploading = false
    @Published var batch: BatchState = .idle

    enum BatchState: Equatable {
        case idle
        case preparing                       // zipping / bundling
        case uploading(Double)               // progress 0...1
        case done(link: String, retention: String)
        case failed(String)
    }

    /// Inputs eligible to upload (excludes items flagged too-large at staging).
    var uploadableCount: Int { items.filter { !$0.isFailed }.count }

    // History
    @Published private(set) var history: [HistoryEntry] = []

    // Toast — driven by token so identical repeated messages still re-animate.
    @Published var toast: Toast?
    private var toastToken = 0
    struct Toast: Equatable { let id: Int; let message: String }

    // Focus signalling for the Shorten field.
    @Published var focusURLField = false

    private let historyKey = "ss.history.v1"
    private let historyLimit = 50

    init() { loadHistory() }

    // MARK: Toast

    func showToast(_ message: String) {
        toastToken &+= 1
        let token = toastToken
        toast = Toast(id: token, message: message)
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.toastToken == token { self.toast = nil }
        }
    }

    // MARK: Clipboard / open

    func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            urlInput = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        showToast("Copied to clipboard")
    }

    func openLink(_ s: String) {
        guard let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: History

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = decoded
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func addHistory(kind: HistoryEntry.Kind, title: String, link: String) {
        history.insert(HistoryEntry(kind: kind, title: title, link: link, date: Date()), at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        saveHistory()
    }

    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // MARK: Shorten

    func clearShorten() {
        urlInput = ""
        shortResult = nil
        shortError = nil
    }

    func shorten() {
        let raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        shortError = nil
        shortResult = nil
        let lower = raw.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            shortError = "Enter an absolute http(s):// URL."
            return
        }
        isShortening = true
        Task {
            defer { self.isShortening = false }
            var produced: String?
            for host in shortenerHosts {
                if let s = try? await self.shortenVia(base: host.base, target: raw) {
                    produced = s
                    break
                }
            }
            guard let text = produced else {
                self.shortError = "Shorteners unavailable, or the URL was rejected. Try again."
                return
            }
            self.shortResult = text
            self.copyToClipboard(text)
            self.addHistory(kind: .shorten, title: raw, link: text)
        }
    }

    /// Calls a plain-text shortener API and returns the short URL, or throws.
    private func shortenVia(base: String, target: String) async throws -> String {
        guard var comps = URLComponents(string: base) else { throw SwiftShareError.hostRejected }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "url", value: target))
        comps.queryItems = items
        guard let url = comps.url else { throw SwiftShareError.hostRejected }

        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("http") else {
            throw SwiftShareError.hostRejected   // is.gd/da.gd return non-URL text on error
        }
        return text
    }

    // MARK: Upload — staging (multi-file queue)

    /// Append files/folders to the staging set, skipping ones already added.
    func stageFiles(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        var skipped = 0
        withAnimation(.easeInOut(duration: 0.2)) {
            // Adding inputs invalidates any previous result.
            if case .done = batch { batch = .idle }
            if case .failed = batch { batch = .idle }
            for url in urls {
                let std = url.standardizedFileURL
                guard !existing.contains(std.path) else { skipped += 1; continue }
                let bytes = rawByteSize(of: std)
                var item = StagedItem(url: std,
                                      name: std.lastPathComponent,
                                      sizeText: humanReadableSize(of: std),
                                      byteSize: bytes)
                // A single file over the largest host cap can never upload on its own.
                if let b = bytes, b > largestHostCap {
                    item.state = .failed("File too large (max \(ByteCountFormatter.string(fromByteCount: largestHostCap, countStyle: .file)))")
                }
                items.append(item)
            }
            tab = .upload
        }
        if skipped > 0 { showToast(skipped == 1 ? "Already added" : "\(skipped) already added") }
    }

    func removeItem(_ id: UUID) {
        guard !isUploading else { return }
        withAnimation(.easeInOut(duration: 0.2)) { items.removeAll { $0.id == id } }
    }

    func clearItems() {
        guard !isUploading else { return }
        withAnimation(.easeInOut(duration: 0.2)) { items.removeAll(); batch = .idle }
    }

    // MARK: Upload — execution (bundle everything into one archive → one URL)

    func uploadAll() {
        guard !isUploading else { return }
        let inputs = items.filter { !$0.isFailed }.map { $0.url }
        guard !inputs.isEmpty else { return }

        isUploading = true
        batch = .preparing
        Task {
            defer { self.isUploading = false }
            await self.performBatch(inputs)
        }
    }

    private func performBatch(_ inputs: [URL]) async {
        // Hold security scope for every input for the whole operation.
        let scoped = inputs.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (u, ok) in scoped where ok { u.stopAccessingSecurityScopedResource() } }

        var payload: URL
        var cleanup: URL?

        if inputs.count == 1, !isDirectory(inputs[0]) {
            // Single file → upload directly (keeps its real name in the URL).
            payload = inputs[0]
        } else {
            // A folder, or any multi-selection → bundle into one .zip.
            batch = .preparing
            let archiveName = inputs.count == 1
                ? "\(inputs[0].lastPathComponent).zip"
                : "SwiftShare-\(inputs.count)-items.zip"
            do {
                payload = try await Task.detached {
                    inputs.count == 1
                        ? try zipDirectory(inputs[0])
                        : try zipMultiple(inputs, archiveName: archiveName)
                }.value
                cleanup = payload
            } catch {
                batch = .failed("Could not compress the selection.")
                return
            }
        }
        defer { if let c = cleanup { try? FileManager.default.removeItem(at: c) } }

        let size = rawByteSize(of: payload)
        if let s = size, s > largestHostCap {
            batch = .failed("Bundle too large (max \(ByteCountFormatter.string(fromByteCount: largestHostCap, countStyle: .file))).")
            return
        }

        batch = .uploading(0)
        let progress: @Sendable (Double) -> Void = { p in
            Task { @MainActor in
                if case .uploading(let cur) = self.batch, p < cur { return }
                self.batch = .uploading(p)
            }
        }

        for host in uploadHosts {
            if let max = host.maxBytes, let sz = size, sz > max { continue }
            do {
                let link = try await uploadOnce(payload: payload, host: host, onProgress: progress)
                batch = .done(link: link, retention: host.retention)
                copyToClipboard(link)
                let title = inputs.count == 1
                    ? inputs[0].lastPathComponent
                    : "\(inputs.count) items (.zip)"
                addHistory(kind: .upload, title: title, link: link)
                return
            } catch {
                batch = .uploading(0)
                continue
            }
        }
        batch = .failed(SwiftShareError.noHost.localizedDescription)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func uploadOnce(payload: URL,
                            host: UploadHost,
                            onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let boundary = "SwiftShareBoundary-\(UUID().uuidString)"
        let extraFields = host.extraFields
        let fileField = host.fileFieldName
        let fileName = payload.lastPathComponent

        let bodyFile = try await Task.detached {
            try buildMultipartBody(
                boundary: boundary,
                fields: extraFields,
                fileField: fileField,
                fileURL: payload,
                fileName: fileName
            )
        }.value
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var req = URLRequest(url: host.url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let ua = host.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }

        let delegate = UploadProgressDelegate(onProgress: onProgress)

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: bodyFile, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("http") else {
            throw SwiftShareError.hostRejected
        }
        return text
    }
}

// MARK: - SwiftUI views

/// 70% of the available screen height — the ceiling the popover may grow to.
@MainActor var maxPanelHeight: CGFloat {
    (NSScreen.main?.visibleFrame.height ?? 800) * 0.7
}

/// A vertical scroll area that sizes itself to its content, growing up to
/// `maxHeight`; only past that does it actually scroll.
struct SelfSizingScroll<C: View>: View {
    let maxHeight: CGFloat
    private let content: C
    @State private var measured: CGFloat = 0

    init(maxHeight: CGFloat, @ViewBuilder content: () -> C) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    private struct HeightKey: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        ScrollView {
            content.background(GeometryReader { g in
                Color.clear.preference(key: HeightKey.self, value: g.size.height)
            })
        }
        .frame(height: min(max(measured, 1), maxHeight))
        .scrollDisabled(measured <= maxHeight)
        .onPreferenceChange(HeightKey.self) { measured = $0 }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SwiftShareModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider()
                Picker("View", selection: $model.tab.animation(.easeInOut(duration: 0.15))) {
                    Text("Shorten").tag(SwiftShareModel.Tab.shorten)
                    Text("Upload").tag(SwiftShareModel.Tab.upload)
                    Text("History").tag(SwiftShareModel.Tab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("View")
                .padding(12)

                Group {
                    switch model.tab {
                    case .shorten: ShortenView()
                    case .upload:  UploadView()
                    case .history: HistoryView()
                    }
                }
                .padding([.horizontal, .bottom], 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                footer
            }

            if let toast = model.toast {
                Label(toast.message, systemImage: "checkmark.circle.fill")
                    .font(.caption).bold()
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                    .padding(.bottom, 34)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)   // re-animate even for identical repeated messages
            }
        }
        .frame(width: 360)
        .animation(.spring(duration: 0.3), value: model.toast)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("SwiftShare").font(.headline)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Quit SwiftShare")
            .accessibilityLabel("Quit SwiftShare")
        }
        .padding(12)
    }

    private var footer: some View {
        Text("Links are copied to your clipboard automatically.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

struct ShortenView: View {
    @EnvironmentObject var model: SwiftShareModel
    @FocusState private var fieldFocused: Bool

    private var canShorten: Bool {
        !model.urlInput.trimmingCharacters(in: .whitespaces).isEmpty && !model.isShortening
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shorten a link").font(.subheadline).bold()

            TextField("https://example.com/long/path", text: $model.urlInput)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($fieldFocused)
                .onSubmit { if canShorten { model.shorten() } }

            HStack {
                Button { model.pasteFromClipboard() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                Button { model.clearShorten(); fieldFocused = true } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .disabled(model.urlInput.isEmpty && model.shortResult == nil && model.shortError == nil)
                Spacer()
                Button { model.shorten() } label: {
                    if model.isShortening {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Shorten")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canShorten)
            }

            if let err = model.shortError {
                HStack(spacing: 8) {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityLabel("Error: \(err)")
                    Spacer()
                    Button("Try again") { model.shorten() }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(!canShorten)
                }
            }

            if let result = model.shortResult {
                ResultRow(label: "Shortened URL", value: result,
                          onCopy: { model.copyToClipboard(result) },
                          onOpen: { model.openLink(result) })
            }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusURLField) { _, focus in if focus { fieldFocused = true; model.focusURLField = false } }
    }
}

struct UploadView: View {
    @EnvironmentObject var model: SwiftShareModel
    @State private var isTargeted = false

    /// Budget for the file list before it scrolls (panel chrome ≈ 380pt).
    private var listMaxHeight: CGFloat { max(140, maxPanelHeight - 380) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Upload files or folders").font(.subheadline).bold()
                Spacer()
                if !model.items.isEmpty {
                    Button { model.clearItems() } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(model.isUploading)
                }
            }

            dropZone

            if model.items.count > 1 {
                Label("Multiple items upload as a single .zip with one shared link.",
                      systemImage: "doc.zipper")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !model.items.isEmpty {
                SelfSizingScroll(maxHeight: listMaxHeight) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.items) { item in
                            StagedRow(item: item)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }

            batchStatus

            if !model.items.isEmpty {
                Button { model.uploadAll() } label: {
                    Group {
                        if model.isUploading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(model.batch == .preparing ? "Compressing…" : "Uploading…")
                            }
                        } else {
                            Text(uploadButtonTitle)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isUploading || model.uploadableCount == 0)
            }
        }
    }

    @ViewBuilder private var batchStatus: some View {
        switch model.batch {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compressing selection…").font(.caption).foregroundStyle(.secondary)
            }
        case .uploading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Uploading… \(Int(p * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let link, let retention):
            VStack(alignment: .leading, spacing: 4) {
                ResultRow(label: "Share URL", value: link,
                          onCopy: { model.copyToClipboard(link) },
                          onOpen: { model.openLink(link) })
                Text("Available for \(retention).").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityLabel("Error: \(msg)")
                Spacer()
                Button("Retry") { model.uploadAll() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(model.isUploading || model.uploadableCount == 0)
            }
        case .idle:
            EmptyView()
        }
    }

    private var uploadButtonTitle: String {
        let n = model.uploadableCount
        if n <= 1 { return "Upload" }
        return "Upload \(n) items as .zip"
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(height: 88)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title)
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                    Text("Drag files or folders here")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose Files or Folders…") { chooseFiles() }
                        .buttonStyle(.link).font(.caption)
                        .disabled(model.isUploading)
                }
            }
            .background(isTargeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isUploading else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var resolved: URL?
                if let url = item as? URL {
                    resolved = url
                } else if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                }
                if let url = resolved {
                    Task { @MainActor in model.stageFiles([url]) }
                }
            }
        }
        return true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            model.stageFiles(panel.urls)
        }
    }
}

struct StagedRow: View {
    @EnvironmentObject var model: SwiftShareModel
    let item: StagedItem

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                subtitle
            }
            Spacer(minLength: 4)
            iconButton("xmark.circle.fill", "Remove") { model.removeItem(item.id) }
                .disabled(model.isUploading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: item.byteSize == nil ? "folder" : "doc")
                            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch item.state {
        case .pending:
            if !item.sizeText.isEmpty {
                Text(item.sizeText).font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Text(msg).font(.caption2).foregroundStyle(.red)
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: SwiftShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.subheadline).bold()
                Spacer()
                if !model.history.isEmpty {
                    Button { model.clearHistory() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }

            if model.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No links yet").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                SelfSizingScroll(maxHeight: max(160, maxPanelHeight - 220)) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.history) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: SwiftShareModel
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind == .shorten ? "link" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.link)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(entry.title)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("·").font(.caption2).foregroundStyle(.secondary)
                    Text(entry.date, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
            }
            Spacer(minLength: 4)
            iconButton("safari", "Open link") { model.openLink(entry.link) }
            iconButton("doc.on.doc", "Copy link") { model.copyToClipboard(entry.link) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
    }
}

struct ResultRow: View {
    let label: String
    let value: String
    let onCopy: () -> Void
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if let onOpen {
                    Button(action: onOpen) { Image(systemName: "safari") }
                        .buttonStyle(.borderless)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .help("Open link").accessibilityLabel("Open link")
                }
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
                    .help("Copy to clipboard").accessibilityLabel("Copy to clipboard")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = SwiftShareModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            button.image = NSImage(systemSymbolName: "paperplane.fill",
                                   accessibilityDescription: "SwiftShare")?
                .withSymbolConfiguration(cfg)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.contentSize = NSSize(width: 360, height: 300)
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: ContentView().environmentObject(model))
        // Let the popover grow/shrink to the SwiftUI content's fitting size.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Focus the URL field if the Shorten tab is showing.
            if model.tab == .shorten { model.focusURLField = true }
        }
    }
}

// MARK: - Launch

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
