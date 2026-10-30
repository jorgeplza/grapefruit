import SwiftUI

/// Not built yet: hidden from the wheel until `isReady` is true.
struct MetadataTool: View {
    static let isReady = false
    @ObservedObject var session: ToolSession

    var body: some View {
        ToolChrome(title: session.tool.name, onClose: session.close) {
            EmptyView()
        } footer: {
            EmptyView()
        }
    }
}
