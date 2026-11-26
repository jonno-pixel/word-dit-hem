import SwiftUI

@MainActor
struct HistoryScreen: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [ChatSummary] = []
    @State private var renameID: String?
    @State private var renameText = ""
    @State private var deleteID: String?

    private var displayedChats: [ChatSummary] {
        search.isEmpty ? store.chats : results
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(displayedChats) { chat in
                    Button {
                        Task {
                            await store.selectChat(chat.id)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(chat.title).lineLimit(2).foregroundStyle(.primary)
                                Text(chat.updated, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.selectedChat == chat.id { Image(systemName: "checkmark") }
                        }
                    }
                    .contextMenu {
                        Button("Naam wijzigen", systemImage: "pencil") {
                            renameID = chat.id
                            renameText = chat.title
                        }
                        Button("Verwijder", systemImage: "trash", role: .destructive) {
                            deleteID = chat.id
                        }
                    }
                    .swipeActions {
                        Button("Verwijder", role: .destructive) { deleteID = chat.id }
                    }
                }
            }
            .overlay {
                if displayedChats.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Zoek in gesprekken")
            .task(id: search) {
                results = await store.searchChats(search)
            }
            .navigationTitle("Gesprekken")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Gereed") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Nieuw gesprek", systemImage: "square.and.pencil") {
                        Task {
                            await store.newChat()
                            dismiss()
                        }
                    }
                }
            }
            .alert("Naam wijzigen", isPresented: Binding(
                get: { renameID != nil },
                set: { if !$0 { renameID = nil } }
            )) {
                TextField("Naam", text: $renameText)
                Button("Bewaar") {
                    if let renameID { Task { await store.renameChat(renameID, title: renameText) } }
                    renameID = nil
                }
                Button("Annuleer", role: .cancel) { renameID = nil }
            }
            .confirmationDialog(
                "Gesprek verwijderen?",
                isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }),
                titleVisibility: .visible
            ) {
                Button("Verwijder gesprek", role: .destructive) {
                    if let deleteID { Task { await store.deleteChat(deleteID) } }
                    deleteID = nil
                }
                Button("Annuleer", role: .cancel) { deleteID = nil }
            }
        }
    }
}
