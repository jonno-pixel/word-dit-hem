import Foundation
import SwiftUI
import UIKit

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [ChatSummary] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var models: [ModelEntry] = []
    @Published var selectedChat: String?
    @Published var selectedModel: String {
        didSet { defaults.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var contextText: String {
        didSet { defaults.set(contextText, forKey: "contextSize") }
    }
    @Published var temperatureText: String {
        didSet { defaults.set(temperatureText, forKey: "temperature") }
    }
    @Published var useMetal: Bool {
        didSet { defaults.set(useMetal, forKey: "useMetal") }
    }
    @Published var template: String {
        didSet { defaults.set(template, forKey: "chatTemplate") }
    }
    @Published private(set) var isReady = false
    @Published private(set) var activeMessage: String?
    @Published private(set) var status = "Starten…"
    @Published var problem: String?
    @Published var exportURL: URL?

    private let defaults = UserDefaults.standard
    private let engine = LocalInferenceEngine()
    private let reader = AttachmentReader()
    private var database: ChatDatabase?
    private var repository: ModelRepository?
    private var worker: Task<Void, Never>?
    private var activeGeneration: Task<GenerationResult, Error>?
    private var activeChat: String?
    private var pendingDeletes: Set<String> = []

    init() {
        selectedModel = defaults.string(forKey: "selectedModel") ?? ""
        contextText = defaults.string(forKey: "contextSize") ?? "0"
        temperatureText = defaults.string(forKey: "temperature") ?? "0.7"
        useMetal = defaults.object(forKey: "useMetal") as? Bool ?? true
        template = defaults.string(forKey: "chatTemplate") ?? ""

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JJS", isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            database = try ChatDatabase(file: support.appendingPathComponent("conversations.sqlite"))
            repository = try ModelRepository(directory: documents.appendingPathComponent("Models", isDirectory: true))
            Task { await bootstrap() }
        } catch {
            problem = error.localizedDescription
            status = "Opslag openen mislukt"
        }
    }

    var isGenerating: Bool { activeMessage != nil }

    private func bootstrap() async {
        guard let database, let repository else { return }
        do {
            chats = try await database.chats()
            if chats.isEmpty {
                selectedChat = try await database.createChat()
                chats = try await database.chats()
            } else {
                selectedChat = chats.first?.id
            }
            models = try await repository.list()
            if !models.contains(where: { $0.path == selectedModel }) {
                selectedModel = models.first?.path ?? ""
            }
            await refreshMessages()
            isReady = true
            status = "Klaar (Native iOS)"
            startQueue()
        } catch {
            problem = error.localizedDescription
            status = "Initialiseren mislukt"
        }
    }

    func refreshMessages() async {
        guard let database, let selectedChat else { return }
        do { messages = try await database.messages(chat: selectedChat) }
        catch { problem = error.localizedDescription }
    }

    private func refreshChats() async {
        guard let database else { return }
        do { chats = try await database.chats() }
        catch { problem = error.localizedDescription }
    }

    func searchChats(_ query: String) async -> [ChatSummary] {
        guard let database else { return [] }
        do { return try await database.chats(search: query) }
        catch {
            problem = error.localizedDescription
            return []
        }
    }

    func newChat() async {
        guard let database else { return }
        do {
            selectedChat = try await database.createChat()
            await refreshChats()
            await refreshMessages()
        } catch { problem = error.localizedDescription }
    }

    func selectChat(_ id: String) async {
        selectedChat = id
        await refreshMessages()
    }

    func renameChat(_ id: String, title: String) async {
        guard let database else { return }
        do {
            try await database.renameChat(id, title: title)
            await refreshChats()
        } catch { problem = error.localizedDescription }
    }

    func deleteChat(_ id: String) async {
        guard let database else { return }
        if activeChat == id {
            pendingDeletes.insert(id)
            activeGeneration?.cancel()
            return
        }
        do {
            try await database.deleteChat(id)
            if selectedChat == id {
                let remaining = try await database.chats()
                if let first = remaining.first { selectedChat = first.id }
                else { selectedChat = try await database.createChat() }
            }
            await refreshChats()
            await refreshMessages()
        } catch { problem = error.localizedDescription }
    }

    func send(_ input: String) async -> Bool {
        let content = input
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let database else { return false }
        do {
            let chatID: String
            if let selectedChat {
                chatID = selectedChat
            } else {
                chatID = try await database.createChat()
                selectedChat = chatID
            }
            let options = generationOptions()
            _ = try await database.enqueue(chat: chatID, input: content, options: options)
            await refreshMessages()
            await refreshChats()
            startQueue()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func retry(_ message: ChatMessage) async {
        guard let database else { return }
        do {
            let options = generationOptions()
            try await database.retry(message.id, options: options)
            await refreshMessages()
            startQueue()
        } catch { problem = error.localizedDescription }
    }

    func stop() {
        activeGeneration?.cancel()
    }

    func loadModels(_ urls: [URL]) async {
        guard let repository else { return }
        status = "Bestanden importeren…"
        do {
            let imported = try await repository.importFiles(urls)
            models = try await repository.list()
            if let first = imported.first { selectedModel = first.path }
            status = "Import voltooid"
        } catch {
            problem = error.localizedDescription
            status = "Import mislukt"
        }
    }

    func deleteModel(_ model: ModelEntry) async {
        guard let repository, activeMessage == nil else { return }
        do {
            try await repository.remove(model)
            models = try await repository.list()
            if selectedModel == model.path { selectedModel = models.first?.path ?? "" }
        } catch { problem = error.localizedDescription }
    }

    func readAttachment(_ url: URL) async throws -> String {
        try await reader.read(url)
    }

    func exportChats() async {
        guard let database else { return }
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("JJS-\(UUID().uuidString).json")
            try await database.exportArchive().write(to: destination, options: .atomic)
            exportURL = destination
        } catch { problem = error.localizedDescription }
    }

    func importChats(from url: URL) async {
        guard let database else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try await database.importArchive(Data(contentsOf: url))
            await refreshChats()
            if selectedChat == nil { selectedChat = chats.first?.id }
            await refreshMessages()
        } catch { problem = error.localizedDescription }
    }

    func sceneChanged(_ phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active && isGenerating
    }

    private func generationOptions() -> GenerationOptions {
        let context = UInt32(contextText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let temperature = Float(temperatureText.replacingOccurrences(of: ",", with: ".")) ?? 0.7
        return GenerationOptions(
            modelPath: selectedModel,
            contextSize: context,
            temperature: max(0, temperature),
            useMetal: useMetal,
            template: template.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func startQueue() {
        guard worker == nil, let database, let repository else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, let job = try await database.nextJob() {
                    activeMessage = job.id
                    activeChat = job.chat
                    status = "Bezig…"
                    try await database.setState(job.id, .running)
                    await refreshMessages()

                    do {
                        let modelURL: URL? = job.options.modelPath.isEmpty ? nil : await repository.url(for: job.options.modelPath)
                        let history = try await database.history(chat: job.chat, before: job.id)
                        let generation = Task {
                            try await engine.generate(
                                modelURL: modelURL,
                                options: job.options,
                                history: history
                            ) { [weak self] update in
                                guard let self else { return }
                                try await self.accept(update, messageID: job.id, chatID: job.chat)
                            }
                        }
                        activeGeneration = generation
                        let result = try await generation.value
                        activeGeneration = nil
                        try await database.complete(
                            job.id,
                            note: "Voltooid · \(result.tokenCount.formatted()) tokens"
                        )
                        status = "Klaar"
                    } catch is CancellationError {
                        activeGeneration = nil
                        try await database.setState(job.id, .stopped, note: "Gestopt.")
                        status = "Gestopt"
                    } catch {
                        activeGeneration = nil
                        try await database.setState(job.id, .failed, note: error.localizedDescription)
                        problem = error.localizedDescription
                        status = "Onderbroken"
                    }

                    activeMessage = nil
                    activeChat = nil
                    if pendingDeletes.remove(job.chat) != nil {
                        try await database.deleteChat(job.chat)
                        if selectedChat == job.chat {
                            let remaining = try await database.chats()
                            if let first = remaining.first { selectedChat = first.id }
                            else { selectedChat = try await database.createChat() }
                        }
                    }
                    await refreshMessages()
                    await refreshChats()
                }
            } catch {
                problem = error.localizedDescription
            }
            activeGeneration = nil
            activeMessage = nil
            activeChat = nil
            worker = nil
            await refreshMessages()
            if (try? await database.nextJob()) != nil { startQueue() }
        }
    }

    private func accept(_ update: EngineUpdate, messageID: String, chatID: String) async throws {
        guard let database else { throw JJSFailure(message: "Gespreksopslag is niet beschikbaar.") }
        switch update {
        case .status(let value):
            status = value
        case .text(let text):
            try await database.append(messageID, text: text)
            if selectedChat == chatID,
               let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].content.append(text)
            } else if selectedChat == chatID {
                await refreshMessages()
            }
        }
    }
}
