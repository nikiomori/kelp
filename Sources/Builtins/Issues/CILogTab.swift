import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// "cilog:?worktree=…&job=…&name=…": a job's whole log, read only, in the editor: its lines don't wrap at a panel's
/// width, and Find works. A step opens it at the line where that step begins.
@MainActor
final class CILogTab: KelpKit.TabContent {   // not SwiftUI's
    let uri: String
    let view: NSView
    let title: String
    var icon: NSImage? { .symbol("doc.text") }
    private let box = NSView()
    private var editor: CodeEditor?
    private var text = ""

    /// Tabs on screen, so that a second step moves the one that's open instead of reading the log again.
    private static var shown: [String: () -> CILogTab?] = [:]
    /// The step to show once the log is read.
    private static var waiting: [String: String] = [:]

    static func uri(worktree: String, job: CIRuns.Job) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "worktree", value: worktree), URLQueryItem(name: "job", value: String(job.id)),
            URLQueryItem(name: "name", value: job.name)
        ]
        return "cilog:" + (components.string ?? "")
    }

    /// Opens the job's log, at `step` if one is named.
    static func open(_ app: AppModel, worktree: String, job: CIRuns.Job, step: String? = nil) {
        let uri = uri(worktree: worktree, job: job)
        if let tab = shown[uri]?() {
            if let step { tab.go(to: step) }
        } else if let step {
            waiting[uri] = step
        }
        app.workbench.open(uri)
    }

    private static func query(_ uri: String) -> [URLQueryItem] {
        URLComponents(string: "x:" + TabURI.body(uri))?.queryItems ?? []
    }
    static func title(_ uri: String) -> String {
        String(localized: "Log: \(query(uri).first { $0.name == "name" }?.value ?? "")")
    }

    init(uri: String, app: AppModel) {
        self.uri = uri
        let query = Self.query(uri)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        title = Self.title(uri)
        view = box
        Self.shown[uri] = { [weak self] in self }
        guard let worktree = value("worktree"), let job = value("job").flatMap(Int.init) else { return }
        let slow = whileSlow { [weak self] in self?.show(String(localized: "Loading the log…")) }
        Task { [weak self] in
            let result = await app.tryCall(CIFullLog(worktreeId: worktree, job: job))
            slow.cancel()
            guard let self else { return }
            if let log = result.value { loaded(log) } else { show(result.error ?? "") }
        }
    }

    func focus() { editor?.focus() }
    func close() async -> Bool {
        Self.shown[uri] = nil
        return true
    }

    private func show(_ message: String) {
        let empty = EmptyStateView()
        box.subviews.forEach { $0.removeFromSuperview() }
        empty.show(message)
        box.pin(empty)
    }

    private func loaded(_ log: String) {
        text = log
        let codeEditor = CodeEditor(text: log, url: URL(fileURLWithPath: "/ci.log"), editable: false)
        codeEditor.view.clipsToBounds = true
        editor = codeEditor
        box.subviews.forEach { $0.removeFromSuperview() }
        box.pin(codeEditor.view)
        if let step = Self.waiting.removeValue(forKey: uri) { go(to: step) }
    }

    private func go(to step: String) {
        guard let line = CIRuns.line(ofStep: step, in: text) else { return }
        editor?.goTo(line: line)
        editor?.focus()
    }
}
