import { describe, expect, it } from "vitest";
import type { RemoteCommand } from "./types";

// Test the remote command → playerAction mapping logic in isolation.
// The full observer component requires a player store context; this test
// validates the core mapping function that would be extracted.

function mapCommandToAction(command: RemoteCommand): string {
	switch (command.type) {
		case "play":
			return "setPlayingState(true)";
		case "pause":
			return "setPlayingState(false)";
		case "toggle_play_pause":
			return "togglePlayPause";
		case "previous":
			return "playPrev";
		case "next":
			return "playNext";
		case "seek":
			return `setProgress(${command.seconds})`;
		case "set_volume":
			return `setVolume(${command.volume * 100})`;
		case "set_shuffle":
			return `toggleShuffle(if ${command.enabled})`;
		case "set_repeat":
			return "toggleLoop";
		case "clear_queue":
			return "clearUserQueue";
		case "play_song":
			return `playSong(${command.songId})`;
		case "play_album":
			return `playAlbum(${command.albumId})`;
		case "play_playlist":
			return `playPlaylist(${command.playlistId})`;
		case "add_to_queue_next":
			return `addToQueueNext(${command.songIds.length})`;
		case "add_to_queue_last":
			return `addToQueueLast(${command.songIds.length})`;
		case "remove_from_queue":
			return `removeFromQueue(${command.songIds.length})`;
		case "reorder_queue":
			return `reorderQueue(${command.from}->${command.to})`;
		case "toggle_like":
			return "toggleLike";
		default:
			return "unknown";
	}
}

describe("remote command mapping", () => {
	it("maps play/pause/toggle", () => {
		expect(mapCommandToAction({ type: "play" })).toBe("setPlayingState(true)");
		expect(mapCommandToAction({ type: "pause" })).toBe("setPlayingState(false)");
		expect(mapCommandToAction({ type: "toggle_play_pause" })).toBe("togglePlayPause");
	});

	it("maps seek with seconds", () => {
		expect(mapCommandToAction({ type: "seek", seconds: 42.5 })).toBe("setProgress(42.5)");
	});

	it("maps volume scaling 0-1 to 0-100", () => {
		expect(mapCommandToAction({ type: "set_volume", volume: 0.5 })).toBe("setVolume(50)");
		expect(mapCommandToAction({ type: "set_volume", volume: 1 })).toBe("setVolume(100)");
		expect(mapCommandToAction({ type: "set_volume", volume: 0 })).toBe("setVolume(0)");
	});

	it("maps shuffle and repeat", () => {
		expect(mapCommandToAction({ type: "set_shuffle", enabled: true })).toBe("toggleShuffle(if true)");
		expect(mapCommandToAction({ type: "set_repeat", mode: "off" })).toBe("toggleLoop");
	});

	it("maps queue operations", () => {
		expect(mapCommandToAction({ type: "clear_queue" })).toBe("clearUserQueue");
		expect(mapCommandToAction({ type: "add_to_queue_next", songIds: ["a", "b"] })).toBe("addToQueueNext(2)");
		expect(mapCommandToAction({ type: "remove_from_queue", songIds: ["x"] })).toBe("removeFromQueue(1)");
		expect(mapCommandToAction({ type: "reorder_queue", from: 0, to: 2 })).toBe("reorderQueue(0->2)");
	});

	it("maps media commands", () => {
		expect(mapCommandToAction({ type: "play_song", songId: "s1" })).toBe("playSong(s1)");
		expect(mapCommandToAction({ type: "play_album", albumId: "al1" })).toBe("playAlbum(al1)");
		expect(mapCommandToAction({ type: "play_playlist", playlistId: "pl1" })).toBe("playPlaylist(pl1)");
	});

	it("maps toggle_like", () => {
		expect(mapCommandToAction({ type: "toggle_like" })).toBe("toggleLike");
	});
});