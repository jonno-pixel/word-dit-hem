import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsScreen: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Toggle("Apple Metal hardwareversnelling", isOn: $store.useMetal)
                    TextField("Contexttokens (0 = onbeperkt)", text: $store.contextText)
                        .keyboardType(.numberPad)
                    TextField("Temperatuur", text: $store.temperatureText)
                        .keyboardType(.decimalPad)
                }

                Section("Gesprekken") {
                    Button("Exporteer alle gesprekken", systemImage: "square.and.arrow.up") {
                        Task { await store.exportChats() }
                    }
                    if let exportURL = store.exportURL {
                        ShareLink("Deel JSON-export", item: exportURL)
                    }
                    Button("Importeer gesprekken", systemImage: "square.and.arrow.down") {
                        importing = true
                    }
                }
            }
            .navigationTitle("Instellingen")
            .toolbar { Button("Gereed") { dismiss() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    Task { await store.importChats(from: url) }
                }
            }
        }
    }
}
