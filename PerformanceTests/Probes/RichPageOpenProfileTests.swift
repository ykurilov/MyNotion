import AppKit
import NotesCore
import PageEditor
import XCTest

/// Профиль открытия «богатой» страницы (research R15, п. 2): системный `sample` снимает стеки процесса, пока проба
/// открывает «богатые» страницы по кругу; дерево вызовов — `~/probe-shots/sample-open.txt`. Время по частям открытия —
/// строками «Проба открытия».
@MainActor
final class RichPageOpenProfileTests: XCTestCase {
    func testProfileRichPageOpen() async throws {
        let page = try RichProbePage()
        defer { page.close() }
        let pages = [page.pageId, try BranchCopyDraft.copy(page.pageId, in: page.store)]
        var load: [Double] = [], create: [Double] = [], display: [Double] = []
        var loadCPU: [Double] = [], createCPU: [Double] = [], displayCPU: [Double] = []
        func open(_ index: Int) throws {
            try autoreleasepool {
                var content: PageContent?
                let read = try ProbeEditor.measureCPU { content = try page.store.pageContent(pages[index % 2]) }
                var editor: PageTextView?
                let made = ProbeEditor.measureCPU { editor = PageTextView(document: PageDocument(content: content!), initialFocus: .unchanged) }
                let shown = ProbeEditor.measureCPU {
                    page.show(editor!)
                    page.window.displayIfNeeded()
                }
                load.append(read.wall); create.append(made.wall); display.append(shown.wall)
                loadCPU.append(read.cpu); createCPU.append(made.cpu); displayCPU.append(shown.cpu)
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        for index in 0..<10 { try open(index) }
        load = []; create = []; display = []; loadCPU = []; createCPU = []; displayCPU = []

        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "6", "1", "-mayDie", "-file", folder.appendingPathComponent("sample-open.txt").path]
        sampler.standardOutput = Pipe()
        sampler.standardError = Pipe()
        try sampler.run()
        try await Task.sleep(for: .milliseconds(500))
        let deadline = Date().addingTimeInterval(5)
        var index = 0
        while Date() < deadline {
            try open(index)
            index += 1
        }
        while sampler.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        let summary = """
            Проба открытия: \(index) открытий «богатой» страницы — чтение p95 \(ProbeEditor.format(ProbeEditor.p95(load))) мс, \
            редактор p95 \(ProbeEditor.format(ProbeEditor.p95(create))) мс, показ p95 \(ProbeEditor.format(ProbeEditor.p95(display))) мс; \
            медианы \(ProbeEditor.format(load.sorted()[load.count / 2])) / \(ProbeEditor.format(create.sorted()[create.count / 2])) / \(ProbeEditor.format(display.sorted()[display.count / 2]))
            Проба открытия: время процессора, медианы — чтение \(ProbeEditor.format(ProbeEditor.median(loadCPU))) мс, редактор \(ProbeEditor.format(ProbeEditor.median(createCPU))) мс, \
            показ \(ProbeEditor.format(ProbeEditor.median(displayCPU))) мс, всего \(ProbeEditor.format(ProbeEditor.median(zip(zip(loadCPU, createCPU), displayCPU).map { $0.0 + $0.1 + $1 }))) мс
            """
        print(summary)
        add(XCTAttachment(string: summary))
    }
}
