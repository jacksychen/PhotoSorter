import SwiftUI

struct ResultView: View {
    @Environment(AppState.self) private var appState

    private var totalPhotoCount: Int {
        appState.manifestResult?.total
            ?? appState.manifestResult?.clusters.reduce(0) { $0 + $1.count }
            ?? 0
    }

    var body: some View {
        NavigationSplitView {
            ClusterSidebar()
        } detail: {
            PhotoGridView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.phase = .parameters
                } label: {
                    Label("Re-cluster", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            ToolbarItem(placement: .status) {
                Text("\(totalPhotoCount) photos")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
