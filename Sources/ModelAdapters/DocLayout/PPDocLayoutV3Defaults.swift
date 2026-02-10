import Foundation

public enum PPDocLayoutV3Defaults {
    public static let modelID = "PaddlePaddle/PP-DocLayoutV3_safetensors"
    public static let revision = "main"

    /// Conservative set of glob patterns for snapshot download.
    /// Expand only if the chosen snapshot requires additional artifacts.
    public static let downloadGlobs: [String] = [
        "*.safetensors",
        "*.json",
    ]
}
