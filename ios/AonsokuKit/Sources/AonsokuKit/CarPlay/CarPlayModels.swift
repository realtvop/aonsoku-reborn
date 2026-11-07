import Foundation

public enum CarPlayLibraryRoute: Hashable, Sendable {
    case recent, favorites, albums, artists, playlists, downloaded
    case album(String)
    case artist(String)
    case playlist(String)
}

public struct CarPlayLibraryItem: Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let coverArtId: String?
    public let destination: CarPlayLibraryRoute?
    public let songIndex: Int?
}

public struct CarPlayLibraryPage: Sendable {
    public let items: [CarPlayLibraryItem]
    public let nextOffset: Int?
}

public struct CarPlayQueueEntry: Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let isCurrent: Bool
    let index: Int
    let isUserQueue: Bool
    let revision: Int
}

public struct CarPlayPlaybackSnapshot: Sendable {
    public let title: String?
    public let isPlaying: Bool
    public let currentTime: Double
    public let isRemote: Bool
    public let shuffle: Bool
    public let repeatMode: String
    public let queueOffset: Int
    public let queueTotal: Int
    public let queue: [CarPlayQueueEntry]
}

public enum CarPlayPlaybackCommand: Sendable {
    case play, pause, next, previous
    case shuffle(Bool)
    case repeatMode(String)
    case queueEntry(CarPlayQueueEntry)
}

public enum CarPlayError: LocalizedError {
    case notLoggedIn, empty, unavailable, staleSelection, remotePlayback, selectionTimedOut

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return CarPlayText.text("login")
        case .empty: return CarPlayText.text("empty")
        case .unavailable: return CarPlayText.text("unavailable")
        case .staleSelection: return CarPlayText.text("changed")
        case .remotePlayback: return CarPlayText.text("remote")
        case .selectionTimedOut: return CarPlayText.text("selectionTimedOut")
        }
    }
}

/// Reads the same persisted language as the phone, including before React loads.
public enum CarPlayText {
    public static func describe(_ error: Error) -> String {
        if let error = error as? CarPlayError { return error.localizedDescription }
        if let error = error as? SubsonicHTTPError {
            switch error {
            case .authFailed: return text("login")
            case .networkUnreachable: return text("network")
            default: return text("unavailable")
            }
        }
        return text("unavailable")
    }

    public static func text(_ key: String) -> String {
        let store = PreferencesManager.shared.getJSON("lang_store") as? [String: Any]
        let state = store?["state"] as? [String: Any]
        let code = state?["langCode"] as? String
        let chinese = (code.flatMap { $0.isEmpty ? nil : $0 } ?? Locale.preferredLanguages.first ?? "en").hasPrefix(
            "zh")
        let values: [String: (String, String)] = [
            "home": ("首页", "Home"), "library": ("音乐库", "Library"),
            "downloaded": ("已下载", "Downloaded"), "recent": ("最近播放", "Recently Played"),
            "favorites": ("收藏歌曲", "Favorite Songs"), "albums": ("专辑", "Albums"),
            "artists": ("艺术家", "Artists"), "playlists": ("歌单", "Playlists"),
            "continue": ("继续播放", "Continue Playing"), "playing": ("正在播放", "Now Playing"),
            "queue": ("待播列表", "Up Next"), "more": ("下一页", "Next Page"),
            "previousPage": ("上一页", "Previous Page"),
            "loading": ("正在加载…", "Loading…"), "retry": ("重试", "Retry"),
            "close": ("关闭", "Close"), "error": ("无法完成操作", "Unable to Complete"),
            "network": ("连接服务器失败，请检查网络后重试。", "Unable to connect. Check your network and try again."),
            "login": ("请先在 iPhone 上登录服务器。", "Sign in to your server on iPhone first."),
            "empty": ("暂无内容，请在 iPhone 上同步音乐库或下载歌曲。", "No content. Sync your library or download songs on iPhone."),
            "unavailable": (
                "内容不可用，请检查网络或在 iPhone 上重新下载。", "Content unavailable. Check your connection or download again on iPhone."
            ),
            "selectionTimedOut": (
                "选歌超时，请重试。", "Song selection timed out. Please try again."
            ),
            "changed": ("列表已更新，请重新选择。", "The list has changed. Please select again."),
            "remote": ("正在控制其他设备，请在 iPhone 上切回本机播放。", "Controlling another device. Switch to this iPhone in the app."),
            "shuffle": ("随机播放", "Shuffle"), "repeat": ("循环播放", "Repeat"),
        ]
        guard let value = values[key] else { return key }
        return chinese ? value.0 : value.1
    }
}
