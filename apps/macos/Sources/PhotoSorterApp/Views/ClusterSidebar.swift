import SwiftUI

struct ClusterSidebar: View {
    @Environment(AppState.self) private var appState

    private var clusters: [ManifestResult.Cluster] {
        appState.manifestResult?.clusters ?? []
    }

    private var totalPhotoCount: Int {
        appState.manifestResult?.total ?? clusters.reduce(0) { $0 + $1.photos.count }
    }

    private var checkedPhotoCount: Int {
        clusters.reduce(0) { count, cluster in
            count + cluster.photos.filter(\.isChecked).count
        }
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            Button {
                appState.phase = .parameters
            } label: {
                Label("Re-cluster", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            List(selection: $appState.selectedSidebarSelection) {
                Text("All Photos")
                    .badge(totalPhotoCount)
                    .tag(SidebarSelection.allPhotos)

                Text("Checked Photos")
                    .badge(checkedPhotoCount)
                    .tag(SidebarSelection.checkedPhotos)

                ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                    Text("Cluster \(cluster.clusterId)")
                        .badge(cluster.count)
                        .tag(SidebarSelection.cluster(index))
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Clusters")
    }
}
