import SwiftUI

/// Every tool window, keyed by tool. Only the ones marked ready show on the wheel.
@MainActor
enum ToolCatalog {
    static var windows: [ToolID: (ToolSession) -> AnyView] {
        var table: [ToolID: (ToolSession) -> AnyView] = [:]
        func add<V: View>(_ id: ToolID, _ ready: Bool, _ make: @escaping (ToolSession) -> V) {
            if ready { table[id] = { AnyView(make($0)) } }
        }
        add(.compress, CompressTool.isReady) { CompressTool(session: $0) }
        add(.removeMetadata, MetadataTool.isReady) { MetadataTool(session: $0) }
        add(.editImage, EditPhotoTool.isReady) { EditPhotoTool(session: $0) }
        add(.annotateImage, AnnotateTool.isReady) { AnnotateTool(session: $0) }
        add(.frameImage, AddBackgroundTool.isReady) { AddBackgroundTool(session: $0) }
        add(.cropImage, CropImageTool.isReady) { CropImageTool(session: $0) }
        add(.normalizeAudio, NormalizeAudioTool.isReady) { NormalizeAudioTool(session: $0) }
        add(.trimVideo, TrimVideoTool.isReady) { TrimVideoTool(session: $0) }
        add(.organizePDF, OrganizePDFTool.isReady) { OrganizePDFTool(session: $0) }
        add(.mergePDF, MergePDFTool.isReady) { MergePDFTool(session: $0) }
        add(.cropVideo, CropVideoTool.isReady) { CropVideoTool(session: $0) }
        add(.changeVideoSpeed, VideoSpeedTool.isReady) { VideoSpeedTool(session: $0) }
        add(.joinVideos, JoinVideosTool.isReady) { JoinVideosTool(session: $0) }
        add(.videoSnapshots, VideoSnapshotsTool.isReady) { VideoSnapshotsTool(session: $0) }
        add(.splitVideo, SplitVideoTool.isReady) { SplitVideoTool(session: $0) }
        add(.audioToVideo, AudioVisualizerTool.isReady) { AudioVisualizerTool(session: $0) }
        add(.trimAudio, TrimAudioTool.isReady) { TrimAudioTool(session: $0) }
        add(.audioChannels, AudioChannelsTool.isReady) { AudioChannelsTool(session: $0) }
        add(.createCollage, CollageTool.isReady) { CollageTool(session: $0) }
        add(.redactImage, RedactPhotoTool.isReady) { RedactPhotoTool(session: $0) }
        add(.redactVideo, RedactVideoTool.isReady) { RedactVideoTool(session: $0) }
        add(.redactAudio, BleepAudioTool.isReady) { BleepAudioTool(session: $0) }
        return table
    }
}
