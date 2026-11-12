import SwiftUI
import UniformTypeIdentifiers

struct ExtensionManagerView: View {
    let filterKind: PluginKind

    @ObservedObject private var store = PluginStore.shared
    @State private var showAddURL = false
    @State private var showFileImporter = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var errorMessage: String?

    private var items: [InstalledPlugin] {
        store.plugins.filter { $0.kind == filterKind }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showAddURL = true
                } label: {
                    Label("Add JSON Extension URL", systemImage: "link.badge.plus")
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Local .json File", systemImage: "doc.badge.plus")
                }
            } header: {
                Text(filterKind == .audio ? "Audio Source Extensions" : "Lyrics Source Extensions")
            } footer: {
                Text("Import external JSON API endpoints or local JSON manifest files to extend \(filterKind == .audio ? "audio playback" : "lyrics search").")
            }

            Section("Installed Extensions (\(items.count))") {
                if items.isEmpty {
                    Text("No custom extensions installed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { plugin in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plugin.name)
                                    .font(.headline)
                                Text(plugin.endpointURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { plugin.isEnabled },
                                set: { _ in store.toggle(plugin) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        store.remove(at: offsets, kind: filterKind)
                    }
                }
            }
        }
        .navigationTitle(filterKind == .audio ? "Audio Extensions" : "Lyrics Extensions")
        .alert("Add JSON Extension URL", isPresented: $showAddURL) {
            TextField("Extension Name (optional)", text: $newName)
            TextField("https://example.com", text: $newURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {
                newName = ""
                newURL = ""
            }
            Button("Add") {
                addFromURL()
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    try store.importFromJSONData(data, fallbackKind: filterKind)
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func addFromURL() {
        let trimmed = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed) else {
            errorMessage = "Please enter a valid URL."
            return
        }
        let title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let plugin = InstalledPlugin(
            name: title.isEmpty ? (parsed.host ?? "Custom \(filterKind.rawValue.capitalized) Plugin") : title,
            kind: filterKind,
            endpointURL: trimmed
        )
        store.add(plugin)
        newName = ""
        newURL = ""
    }
}
