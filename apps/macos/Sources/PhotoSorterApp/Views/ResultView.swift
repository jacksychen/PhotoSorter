import SwiftUI

struct ResultView: View {
    var body: some View {
        NavigationSplitView {
            ClusterSidebar()
        } detail: {
            PhotoGridView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
    }
}
