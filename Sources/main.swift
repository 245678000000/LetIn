import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App

@main
struct LetInApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("放行", id: "main") {
            ContentView()
                .environmentObject(Fixer.shared)
                .frame(width: 400, height: 500)
                .background(VisualEffect().ignoresSafeArea())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 支持把 App 拖到 Dock 图标上，或 `open -a 放行 xxx.app`
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Fixer.shared.enqueue(urls) }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Model

struct Item: Identifiable {
    enum Phase: Equatable { case working, success, failed(String) }
    let id = UUID()
    let url: URL
    let name: String
    let icon: NSImage
    var phase: Phase = .working
    var note: String = ""
}

@MainActor
final class Fixer: ObservableObject {
    static let shared = Fixer()
    @Published var items: [Item] = []
    @Published var resign: Bool = UserDefaults.standard.bool(forKey: "resign") {
        didSet { UserDefaults.standard.set(resign, forKey: "resign") }
    }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            let item = Item(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                icon: NSWorkspace.shared.icon(forFile: url.path)
            )
            withAnimation(.spring(duration: 0.35)) { items.insert(item, at: 0) }
            let id = item.id
            let resign = self.resign
            Task.detached(priority: .userInitiated) {
                let result = Fixer.process(url, resign: resign)
                await MainActor.run {
                    guard let i = Fixer.shared.items.firstIndex(where: { $0.id == id }) else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        Fixer.shared.items[i].phase = result.phase
                        Fixer.shared.items[i].note = result.note
                    }
                }
            }
        }
    }

    func clear() { withAnimation { items.removeAll { $0.phase != .working } } }

    // MARK: Work (runs off the main thread)

    nonisolated static func process(_ url: URL, resign: Bool) -> (phase: Item.Phase, note: String) {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return (.failed("文件不存在"), "")
        }
        let hadQuarantine = run("/usr/bin/xattr", ["-p", "com.apple.quarantine", path]).code == 0
        let isBundle = url.pathExtension.lowercased() == "app"

        var commands: [(String, [String])] = [("/usr/bin/xattr", ["-cr", path])]
        if resign && isBundle {
            commands.append(("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", path]))
        }

        var needAdmin = false
        var lastError = ""
        for (tool, args) in commands {
            let r = run(tool, args)
            if r.code != 0 {
                lastError = r.output
                if r.output.contains("Permission denied") || r.output.contains("Operation not permitted") {
                    needAdmin = true
                    break
                }
                let prefix = tool.hasSuffix("codesign") ? "重新签名失败：" : "清除失败："
                return (.failed(prefix + shortError(r.output, path: path)), "")
            }
        }

        if needAdmin {
            let script = commands
                .map { ([$0.0] + $0.1).map(shellQuote).joined(separator: " ") }
                .joined(separator: " && ")
            switch runAsAdmin(script) {
            case .ok: break
            case .cancelled: return (.failed("已取消授权"), "")
            case .error(let msg):
                if msg.contains("Operation not permitted") || lastError.contains("Operation not permitted") {
                    return (.failed("系统拒绝修改：请在「隐私与安全性 › App 管理」中允许“放行”"), "privacy")
                }
                return (.failed(shortError(msg)), "")
            }
        }

        var parts: [String] = [hadQuarantine ? "已移除隔离标记" : "未发现隔离标记，已清理扩展属性"]
        if resign && isBundle { parts.append("已重新签名") }
        return (.success, parts.joined(separator: " · "))
    }

    nonisolated static func run(_ tool: String, _ args: [String]) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    enum AdminResult { case ok, cancelled, error(String) }

    nonisolated static func runAsAdmin(_ shell: String) -> AdminResult {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        var result: AdminResult = .ok
        DispatchQueue.main.sync {
            _ = NSAppleScript(source: source)?.executeAndReturnError(&err)
        }
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = err[NSAppleScript.errorMessage] as? String ?? "未知错误"
            result = code == -128 ? .cancelled : .error(msg)
        }
        return result
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func shortError(_ s: String, path: String = "") -> String {
        var line = s.split(separator: "\n").first.map(String.init) ?? s
        if !path.isEmpty {
            // 去掉输出里冗长的文件路径（含 /private 前缀的形式）
            for p in ["/private" + path, path] { line = line.replacingOccurrences(of: p, with: "") }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        }
        if line.contains("bundle format unrecognized") || line.contains("not signable") {
            return "不是有效的 App 包"
        }
        return line.isEmpty ? "处理失败" : String(line.prefix(120))
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var fixer: Fixer
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            header
            dropZone
            if !fixer.items.isEmpty { list } else { tips }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.mint, .teal], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 1) {
                Text("放行").font(.system(size: 17, weight: .semibold))
                Text("解除 macOS 对未验证 App 的拦截")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var dropZone: some View {
        Button(action: choose) {
            VStack(spacing: 10) {
                Image(systemName: targeted ? "arrow.down.app.fill" : "arrow.down.app")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    .symbolEffect(.bounce, value: targeted)
                Text(targeted ? "松手即可放行" : "把被拦截的 App 拖到这里")
                    .font(.system(size: 14, weight: .medium))
                Text("或点击选择文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        targeted ? Color.accentColor : Color.primary.opacity(0.15),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .contentShape(Rectangle())
            .scaleEffect(targeted ? 1.02 : 1)
            .animation(.spring(duration: 0.3), value: targeted)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            fixer.enqueue(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted = $0 }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近处理").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button("清除", action: fixer.clear)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(fixer.items) { ItemRow(item: $0) }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            tip("exclamationmark.triangle", "“Apple 无法验证…是否包含恶意软件”")
            tip("xmark.bin", "“已损坏，无法打开，你应该将它移到废纸篓”")
            tip("lock", "“无法打开，因为无法验证开发者”")
            Text("仅对你信任来源的软件使用。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("同时重新签名").font(.system(size: 12, weight: .medium))
                Text("提示“已损坏”时打开").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("同时重新签名", isOn: $fixer.resign)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "放行"
        if panel.runModal() == .OK { fixer.enqueue(panel.urls) }
    }
}

struct ItemRow: View {
    let item: Item
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.07 : 0.04))
        )
        .onHover { hover = $0 }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var isFailed: Bool { if case .failed = item.phase { return true } else { return false } }

    private var subtitle: String {
        switch item.phase {
        case .working: return "正在处理…"
        case .success: return item.note
        case .failed(let msg): return msg
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.phase {
        case .working:
            ProgressView().controlSize(.small)
        case .success:
            HStack(spacing: 8) {
                if item.url.pathExtension.lowercased() == "app" {
                    Button("打开") { NSWorkspace.shared.open(item.url) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed:
            HStack(spacing: 8) {
                if item.note == "privacy" {
                    Button("去设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                    .controlSize(.small)
                }
                Button {
                    Fixer.shared.enqueue([item.url])
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("重试")
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }
}
