import Foundation

public struct PPDocLayoutV3PreprocessorConfig: Sendable, Codable, Equatable {
    public struct Size: Sendable, Codable, Equatable {
        public var height: Int?
        public var width: Int?
        public var shortestEdge: Int?
        public var longestEdge: Int?

        public init(height: Int? = nil, width: Int? = nil, shortestEdge: Int? = nil, longestEdge: Int? = nil) {
            self.height = height
            self.width = width
            self.shortestEdge = shortestEdge
            self.longestEdge = longestEdge
        }

        private enum CodingKeys: String, CodingKey {
            case height
            case width
            case shortestEdge = "shortest_edge"
            case longestEdge = "longest_edge"
        }
    }

    public var doResize: Bool?
    public var size: Size?

    public var doRescale: Bool?
    public var rescaleFactor: Double?

    public var doNormalize: Bool?
    public var imageMean: [Double]?
    public var imageStd: [Double]?

    public var resample: Int?

    public init(
        doResize: Bool? = nil,
        size: Size? = nil,
        doRescale: Bool? = nil,
        rescaleFactor: Double? = nil,
        doNormalize: Bool? = nil,
        imageMean: [Double]? = nil,
        imageStd: [Double]? = nil,
        resample: Int? = nil
    ) {
        self.doResize = doResize
        self.size = size
        self.doRescale = doRescale
        self.rescaleFactor = rescaleFactor
        self.doNormalize = doNormalize
        self.imageMean = imageMean
        self.imageStd = imageStd
        self.resample = resample
    }

    private enum CodingKeys: String, CodingKey {
        case doResize = "do_resize"
        case size
        case doRescale = "do_rescale"
        case rescaleFactor = "rescale_factor"
        case doNormalize = "do_normalize"
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case resample
    }

    public static func load(from modelFolder: URL) throws -> PPDocLayoutV3PreprocessorConfig? {
        let url = modelFolder.appendingPathComponent("preprocessor_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PPDocLayoutV3PreprocessorConfig.self, from: data)
    }

    public var fixedSize: (height: Int, width: Int)? {
        guard let size, let height = size.height, let width = size.width else { return nil }
        guard height > 0, width > 0 else { return nil }
        return (height, width)
    }

    public func meanStd(
        fallbackMean: (Float, Float, Float) = (0.5, 0.5, 0.5),
        fallbackStd: (Float, Float, Float) = (0.5, 0.5, 0.5)
    ) -> (mean: (Float, Float, Float), std: (Float, Float, Float)) {
        if let mean = imageMean, let std = imageStd, mean.count == 3, std.count == 3 {
            return ((Float(mean[0]), Float(mean[1]), Float(mean[2])), (Float(std[0]), Float(std[1]), Float(std[2])))
        }
        return (fallbackMean, fallbackStd)
    }

    public func targetSize(originalWidth: Int, originalHeight: Int) -> (width: Int, height: Int)? {
        if doResize == false { return nil }

        if let fixed = fixedSize {
            return (width: fixed.width, height: fixed.height)
        }

        guard let size, let shortest = size.shortestEdge, shortest > 0 else { return nil }

        let w = max(originalWidth, 1)
        let h = max(originalHeight, 1)
        let minSide = min(w, h)
        var scale = Double(shortest) / Double(minSide)

        var targetW = Int((Double(w) * scale).rounded())
        var targetH = Int((Double(h) * scale).rounded())

        if let longest = size.longestEdge, longest > 0, max(targetW, targetH) > longest {
            scale = Double(longest) / Double(max(targetW, targetH))
            targetW = Int((Double(targetW) * scale).rounded())
            targetH = Int((Double(targetH) * scale).rounded())
        }

        targetW = max(targetW, 1)
        targetH = max(targetH, 1)
        return (targetW, targetH)
    }
}
