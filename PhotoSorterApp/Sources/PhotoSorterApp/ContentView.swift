import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.phase {
            case .folderSelect:
                FolderSelectView()
            case .parameters:
                ParameterView()
            case .progress:
                PipelineProgressView()
            case .results:
                ResultView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
