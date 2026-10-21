import Foundation

/// ReplayGain tags of one song, in decibels and linear peaks.
public struct AudioReplayGain: Codable, Equatable, Hashable, Sendable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(
        trackGain: Double? = nil,
        trackPeak: Double? = nil,
        albumGain: Double? = nil,
        albumPeak: Double? = nil
    ) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }

    init?(from dict: [String: Any]) {
        func number(_ key: String) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }
        self.init(
            trackGain: number("trackGain"),
            trackPeak: number("trackPeak"),
            albumGain: number("albumGain"),
            albumPeak: number("albumPeak")
        )
        if trackGain == nil, trackPeak == nil, albumGain == nil, albumPeak == nil {
            return nil
        }
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let trackGain { dict["trackGain"] = trackGain }
        if let trackPeak { dict["trackPeak"] = trackPeak }
        if let albumGain { dict["albumGain"] = albumGain }
        if let albumPeak { dict["albumPeak"] = albumPeak }
        return dict
    }
}

/// How the player applies ReplayGain (web `src/utils/replayGain.ts`).
public struct AudioReplayGainConfig: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case track
        case album
    }

    public var mode: Mode
    /// Decibels added to every gain.
    public var preAmp: Double
    /// Decibels used when a song has no tag for the mode.
    public var defaultGain: Double

    public init(mode: Mode = .track, preAmp: Double = 0, defaultGain: Double = -6) {
        self.mode = mode
        self.preAmp = preAmp
        self.defaultGain = defaultGain
    }

    /// Linear volume factor for a song: `10^((gain + preAmp) / 20)`, capped
    /// at `1 / peak` so the peak does not clip. A missing gain falls back to
    /// the other mode's tag, then to `defaultGain`.
    public func volumeScale(for tags: AudioReplayGain?) -> Double {
        let gain: Double
        let peak: Double?
        switch mode {
        case .track:
            if let trackGain = tags?.trackGain {
                gain = trackGain
                peak = tags?.trackPeak
            } else if let albumGain = tags?.albumGain {
                gain = albumGain
                peak = tags?.albumPeak
            } else {
                gain = defaultGain
                peak = tags?.trackPeak ?? tags?.albumPeak
            }
        case .album:
            if let albumGain = tags?.albumGain {
                gain = albumGain
                peak = tags?.albumPeak
            } else if let trackGain = tags?.trackGain {
                gain = trackGain
                peak = tags?.trackPeak
            } else {
                gain = defaultGain
                peak = tags?.albumPeak ?? tags?.trackPeak
            }
        }
        let base = pow(10, (gain + preAmp) / 20)
        guard let peak, peak > 0 else { return base }
        return min(base, 1 / peak)
    }
}
