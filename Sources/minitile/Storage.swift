import Foundation
import Darwin
import MinitileCore

@MainActor
final class ConfigWatcher {
    let file: URL
    var changed: (() -> Void)?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(file: URL) { self.file = file }

    func start() {
        sources.forEach { $0.cancel() }; sources.removeAll()
        var directory = file.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        // The file catches in-place writes; the directory catches atomic replacements.
        for url in [directory, file] {
            let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated { self?.start(); self?.changed?() }
                    }
                    self.pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
                }
            }
            sources.append(source)
            source.resume()
        }
    }

    func stop() {
        pending?.cancel(); sources.forEach { $0.cancel() }; sources.removeAll()
    }
}

final class StateWriter: Sendable {
    private let queue = DispatchQueue(label: "minitile.state")
    let file: URL
    init(file: URL) { self.file = file }

    func read() throws -> SavedState? {
        do { return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func save(_ state: SavedState, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        queue.async { [file] in
            let error: String?
            do {
                let data = try JSONEncoder().encode(state)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: [.atomic])
                error = nil
            } catch let failure { error = "State save: \(failure)" }
            DispatchQueue.main.async { completion(error) }
        }
    }

    func flush() { queue.sync {} }
}
