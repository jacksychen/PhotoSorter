import SwiftUI

struct ClusterSidebar: View {
    @Environment(AppState.self) private var appState

    private var clusters: [ManifestResult.Cluster] {
        appState.manifestResult?.clusters ?? []
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.selectedClusterIndex) {
            ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                Text("Cluster \(cluster.clusterId)")
                    .badge(cluster.count)
                    .tag(index)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Clusters")
    }
}
