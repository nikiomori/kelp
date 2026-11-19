import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// "cilog:?worktree=…&job=…&name=…": a job's whole log, read-only, in the editor, where its lines don't wrap at a
/// panel's width and Find works. A step opens it at the line where that step begins.
@MainActor
final class CILogTab: KelpKit.TabContent {   // not SwiftUI's
    let uri: String
    let view: NSView
    let title: String
    var icon: NSImage? { .symbol("doc.text") }
    private let box = NSView()
    private var editor: CodeEditor?
    private var text = ""
    /// The wait and the error stand where the log will, as in every panel.
    private let loading = LoadingView(), empty = EmptyStateView()
    private lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in
        self?.readAgain()
    }
    /// Reads the log of this tab's job again.
    private var readAgain: @MainActor () -> Void = {}

    /// The tabs on screen, so that a second step moves the tab that's open instead of reading the log again.
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
        loading.place(in: box)
        empty.place(in: box)
        guard let worktree = value("worktree"), let job = value("job").flatMap(Int.init) else { return }
        readAgain = { [weak self] in self?.read(app, worktree: worktree, job: job) }
        readAgain()
    }

    /// Reads the log: a wait once it takes a second, then the log, or what went wrong with Try Again.
    private func read(_ app: AppModel, worktree: String, job: Int) {
        empty.show(nil)
        loading.wait(String(localized: "Loading the log…"))
        Task { [weak self] in
            let result = await app.tryCall(CIFullLog(worktreeId: worktree, job: job))
            guard let self else { return }
            await loading.settled()
            loading.show(nil)
            if let log = result.value {
                loaded(log)
            } else {
                empty.showError(String(localized: "Couldn’t Read the Log"), text: result.error, buttons: [tryAgain])
            }
        }
    }

    func focus() { editor?.focus() }
    func close() async -> Bool {
        Self.shown[uri] = nil
        return true
    }

    private func loaded(_ log: String) {
        text = log
        let codeEditor = CodeEditor(text: log, url: URL(fileURLWithPath: "/ci.log"), editable: false)
        codeEditor.view.clipsToBounds = true
        editor?.view.removeFromSuperview()
        editor = codeEditor
        box.pin(codeEditor.view)
        if let step = Self.waiting.removeValue(forKey: uri) { go(to: step) }
    }

    private func go(to step: String) {
        guard let line = CIRuns.line(ofStep: step, in: text) else { return }
        editor?.goTo(line: line)
        editor?.focus()
    }
}
