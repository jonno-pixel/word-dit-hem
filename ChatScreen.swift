import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TextAttachment: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

@MainActor
struct ChatScreen: View {
    @EnvironmentObject private var store: ChatStore
    @State private var draft = ""
    @State private var attachments: [TextAttachment] = []
    @State private var importingAttachments = false
    @State private var readingAttachments = false
    @State private var showingHistory = false
    @State private var showingModels = false
    @State private var showingSettings = false
    @State private var expandedEditor = false
    @State private var followOutput = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if store.messages.isEmpty {
                            ContentUnavailableView {
                                Label("JJS", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text("Stel direct je vraag of voeg een PDF, foto of audiobestand toe.")
                            }
                            .padding(.top, 40)
                        }

                        ForEach(store.messages) { message in
                            MessageRow(message: message) {
                                draft = message.content
                                inputFocused = true
                            } retry: {
                                Task { await store.retry(message) }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.messages.last?.content) { _, _ in
                    if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: store.selectedChat) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("JJS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Gesprekken", systemImage: "sidebar.left") { showingHistory = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Nieuw gesprek", systemImage: "square.and.pencil") {
                        Task { await store.newChat() }
                    }
                    Menu {
                        Button("Lokale modellen", systemImage: "cpu") { showingModels = true }
                        Button("Instellingen", systemImage: "gearshape") { showingSettings = true }
                        Toggle("Volg antwoord", isOn: $followOutput)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Meer opties")
                }
            }
            .sheet(isPresented: $showingHistory) { HistoryScreen().environmentObject(store) }
            .sheet(isPresented: $showingModels) { ModelsScreen().environmentObject(store) }
            .sheet(isPresented: $showingSettings) { SettingsScreen().environmentObject(store) }
            .sheet(isPresented: $expandedEditor) {
                NavigationStack {
                    TextEditor(text: $draft)
                        .padding()
                        .navigationTitle("Bericht schrijven")
                        .toolbar { Button("Gereed") { expandedEditor = false } }
                }
            }
            .fileImporter(
                isPresented: $importingAttachments,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    readingAttachments = true
                    Task {
                        defer { readingAttachments = false }
                        for url in urls {
                            do {
                                let text = try await store.readAttachment(url)
                                attachments.append(TextAttachment(name: url.lastPathComponent, text: text))
                            } catch {
                                store.problem = "\(url.lastPathComponent): \(error.localizedDescription)"
                            }
                        }
                    }
                case .failure(let error):
                    store.problem = error.localizedDescription
                }
            }
            .alert("JJS", isPresented: Binding(
                get: { store.problem != nil },
                set: { if !$0 { store.problem = nil } }
            )) {
                Button("OK", role: .cancel) { store.problem = nil }
            } message: {
                Text(store.problem ?? "")
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", systemImage: "stop.circle") { store.stop() }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Stoppen")
                }
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 8) {
                                Label(attachment.name, systemImage: "doc.text")
                                Button("Verwijder", systemImage: "xmark.circle.fill") {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                                .labelStyle(.iconOnly)
                            }
                            .font(.caption)
                            .padding(8)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Bestand toevoegen", systemImage: "paperclip") { importingAttachments = true }
                    Button("Groter schrijfveld", systemImage: "arrow.up.left.and.arrow.down.right") {
                        expandedEditor = true
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(readingAttachments)

                TextField("Stel je vraag", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .focused($inputFocused)

                if readingAttachments {
                    ProgressView().frame(minWidth: 44, minHeight: 44)
                } else {
                    Button("Verstuur", systemImage: "arrow.up") {
                        let draftAtSubmit = draft
                        let attachmentsAtSubmit = attachments
                        let attachmentIDsAtSubmit = attachmentsAtSubmit.map(\.id)
                        let submitted = draftAtSubmit + attachmentsAtSubmit.map {
                            "\n\n--- \($0.name) ---\n\($0.text)\n--- Einde bestand ---"
                        }.joined()
                        Task {
                            let sent = await store.send(submitted)
                            if sent && draft == draftAtSubmit && attachments.map(\.id) == attachmentIDsAtSubmit {
                                draft = ""
                                attachments.removeAll()
                            }
                            inputFocused = false
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!store.isReady || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}

@MainActor
private struct MessageRow: View {
    let message: ChatMessage
    let reuse: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.role == .user ? "Jij" : "JJS",
                  systemImage: message.role == .user ? "person.crop.circle" : "sparkle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if message.content.isEmpty && message.state == .running {
                Text("Bezig…").foregroundStyle(.secondary)
            } else if message.role == .assistant {
                Text((try? AttributedString(markdown: message.content)) ?? AttributedString(message.content))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(message.content)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if message.state == .stopped || message.state == .failed {
                Label(message.note, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                if !message.content.isEmpty {
                    Button("Kopieer", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = message.content
                    }
                    ShareLink(item: message.content) {
                        Label("Deel", systemImage: "square.and.arrow.up")
                    }
                }
                if message.role == .user {
                    Button("Bewerk", systemImage: "pencil", action: reuse)
                } else if message.state == .stopped || message.state == .failed {
                    Button("Opnieuw", systemImage: "arrow.clockwise", action: retry)
                }
            }
            .font(.callout)
            .labelStyle(.iconOnly)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(message.role == .user ? 16 : 0)
        .background(
            message.role == .user ? Color(uiColor: .secondarySystemBackground) : .clear,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }
}
