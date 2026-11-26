import Foundation

actor ModelRepository {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func list() throws -> [ModelEntry] {
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [ModelEntry] = []
        for case let file as URL in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let relative = String(file.path.dropFirst(directory.path.count + 1))
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(ModelEntry(
                path: relative,
                name: file.deletingPathExtension().lastPathComponent,
                bytes: size
            ))
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importFiles(_ sources: [URL]) throws -> [ModelEntry] {
        let access = sources.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (index, source) in sources.enumerated() where access[index] {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let group = UUID().uuidString
        let destination = directory.appendingPathComponent(group, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for source in sources {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
        }
        return try list().filter { $0.path.hasPrefix(group + "/") }
    }

    func url(for path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    func remove(_ entry: ModelEntry) throws {
        try FileManager.default.removeItem(at: url(for: entry.path))
    }
}
