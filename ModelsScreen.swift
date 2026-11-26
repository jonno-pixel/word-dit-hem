import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ModelsScreen: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var deleting: ModelEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Modelbestand importeren", systemImage: "square.and.arrow.down") {
                        importing = true
                    }
                }

                Section("Op dit toestel") {
                    if store.models.isEmpty {
                        Label("Standaard iOS Native Engine actief", systemImage: "iphone")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.models) { model in
                        Button {
                            store.selectedModel = model.path
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.name).foregroundStyle(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.selectedModel == model.path {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .swipeActions {
                            Button("Verwijder", role: .destructive) { deleting = model }
                        }
                    }
                }
            }
            .navigationTitle("Modellen")
            .toolbar { Button("Gereed") { dismiss() } }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task { await store.loadModels(urls) }
                }
            }
            .confirmationDialog(
                "Verwijderen?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Verwijder", role: .destructive) {
                    if let deleting { Task { await store.deleteModel(deleting) } }
                    deleting = nil
                }
                Button("Annuleer", role: .cancel) { deleting = nil }
            }
        }
    }
}
