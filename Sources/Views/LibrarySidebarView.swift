import SwiftUI

/// A plain list under small theme headings. No counts, no rings, no progress bars.
struct LibrarySidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewPassage: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.summaries.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            newPassageButton
        }
        .frame(minWidth: 180)
    }

    private var list: some View {
        List(selection: Binding(
            get: { model.selectedFolder },
            set: { newValue in
                guard let newValue else { return }
                Task { await model.select(folderName: newValue) }
            }
        )) {
            // Search only once the library is past a handful, so a small library shows no
            // furniture at all.
            if model.summaries.count > 6 {
                TextField("Search", text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .listRowSeparator(.hidden)
            }

            ForEach(model.groupedSummaries, id: \.theme) { group in
                Section {
                    ForEach(group.items) { summary in
                        row(summary).tag(summary.folderName)
                    }
                } header: {
                    if let theme = group.theme {
                        Text(theme).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Styling.canvas)
    }

    private func row(_ summary: PassageSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if summary.isBroken {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Text(summary.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Text(summary.isBroken
                 ? "Could not be read"
                 : Styling.dateFormatter.string(from: summary.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(folderName: summary.folderName) }
            if summary.isBroken {
                // Detection without an action was the gap: a broken row has no decodable
                // passage, so it needs a path that works from the folder name alone.
                Button("Move to Trash") { Task { await model.deleteBroken(summary) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No passages yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var newPassageButton: some View {
        Button {
            showingNewPassage = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11))
                Text("New passage").font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut("n", modifiers: .command)
    }
}
