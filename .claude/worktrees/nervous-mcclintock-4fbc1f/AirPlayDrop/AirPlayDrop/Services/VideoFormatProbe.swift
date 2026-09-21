import AVFoundation
import CoreMedia

enum VideoFormatFlag {
    case dolbyVision
    case hdr10
    case hlg
}

struct VideoFormatProbe {

    /// Returns any HDR / Dolby Vision markers present on the asset's first video track.
    /// AirPlay streaming typically rejects these formats and falls back to audio-only.
    static func inspect(_ asset: AVAsset) async -> Set<VideoFormatFlag> {
        var flags: Set<VideoFormatFlag> = []
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let descriptions = try? await track.load(.formatDescriptions) else {
            return flags
        }

        for desc in descriptions {
            if CMFormatDescriptionGetExtension(
                desc, extensionKey: "DolbyVisionConfiguration" as CFString) != nil {
                flags.insert(.dolbyVision)
            }
            if let transfer = CMFormatDescriptionGetExtension(
                desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String {
                if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    flags.insert(.hdr10)
                }
                if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                    flags.insert(.hlg)
                }
            }
        }
        return flags
    }
}
