import { randomUUID } from "node:crypto";
import type {
  NativeFullState,
  NativeQueueSong,
  NativeQueueSourceId,
} from "@aonsoku/audio-contract";
import { buildPlaybackSnapshotFromNativeFullState } from "../../../../src/coordination/native-full-state-snapshot";
import type {
  Envelope,
  PlaybackSnapshot,
  RemoteCommand,
} from "../../../../src/coordination/types";
import type { NativeAudioService } from "../audio/service";
import { AsyncLimiter } from "../concurrency";

export interface DesktopCoordinationPlaybackState {
  sessionId: string;
  generation: number;
  revision: number;
}

interface Options {
  audio: NativeAudioService;
  send: (message: Record<string, unknown>) => void;
  request: (options: {
    path: string;
    query?: Record<string, string | number>;
  }) => Promise<{ data: Record<string, unknown> }>;
  cachedSongs: () => Record<string, unknown>[];
  loadState: () => DesktopCoordinationPlaybackState | undefined;
  saveState: (state: DesktopCoordinationPlaybackState) => void;
}

/** Playback protocol runs in the main process beside the audio owner. */
export class DesktopCoordinationPlayback {
  private state: DesktopCoordinationPlaybackState;
  private connected = false;
  private epoch = 0;
  private controlling = false;
  private superseded = false;
  private pending: { transactionId: string; before: NativeFullState } | null =
    null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private publishTimer: ReturnType<typeof setTimeout> | null = null;
  private tail: Promise<unknown> = Promise.resolve();
  private readonly unsubscribe: () => void;
  private readonly metadataLimiter = new AsyncLimiter(6);
  private readonly commands = new Map<string, Record<string, unknown>>();

  constructor(private readonly options: Options) {
    this.state = options.loadState() ?? {
      sessionId: randomUUID(),
      generation: 1,
      revision: 0,
    };
    this.unsubscribe = options.audio.onEvent(({ eventName, event }) => {
      if (
        eventName === "playbackStateChanged" &&
        "state" in event &&
        event.state === "playing"
      )
        this.superseded = false;
      if (
        [
          "playbackStateChanged",
          "queueStateChanged",
          "queueContentsChanged",
          "systemVolumeChanged",
        ].includes(eventName)
      ) {
        this.schedulePublish();
      }
    });
  }

  start(): void {
    this.connected = true;
    if (!this.heartbeat)
      this.heartbeat = setInterval(() => this.schedulePublish(), 10_000);
    this.schedulePublish();
  }

  stop(): void {
    this.connected = false;
    this.epoch++;
    if (this.heartbeat) clearInterval(this.heartbeat);
    if (this.publishTimer) clearTimeout(this.publishTimer);
    this.heartbeat = null;
    this.publishTimer = null;
    this.enqueue(async () => {
      if (this.pending) {
        const { before } = this.pending;
        this.pending = null;
        if (before.currentSongId)
          await this.options.audio.restoreQueueState(before, before.isPlaying);
        else await this.options.audio.clear();
      }
    }).catch(() => {});
  }

  destroy(): void {
    this.stop();
    this.unsubscribe();
  }

  setControlling(controlling: boolean): void {
    this.controlling = controlling;
    if (!controlling) this.schedulePublish();
  }

  handle(envelope: Envelope): Promise<void> {
    const epoch = this.epoch;
    return this.enqueue(async () => {
      if (epoch !== this.epoch) return;
      const audio = this.options.audio;
      switch (envelope.type) {
        case "command": {
          let result = this.commands.get(envelope.messageId);
          if (!result) {
            try {
              if (this.controlling)
                throw new Error("device is controlling another player");
              await this.execute(envelope.command);
              result = { status: "ok" };
            } catch (error) {
              result = {
                status: "error",
                code: "internal",
                reason:
                  error instanceof Error
                    ? error.message
                    : "playback command failed",
              };
            }
            this.commands.set(envelope.messageId, result);
            if (this.commands.size > 200)
              this.commands.delete(this.commands.keys().next().value as string);
          }
          this.send(
            {
              type: "command_ack",
              messageId: envelope.messageId,
              result,
            },
            epoch,
          );
          await this.publish();
          break;
        }
        case "handoff_candidate": {
          if (this.pending) throw new Error("handoff already preparing");
          const before = await audio.getFullState();
          this.pending = { transactionId: envelope.transactionId, before };
          try {
            await this.prepare(envelope.snapshot, false);
            if (
              Date.now() / 1000 >= envelope.deadline ||
              !this.connected ||
              epoch !== this.epoch
            )
              throw new Error("handoff preparation expired");
            this.send(
              {
                type: "target_ready",
                transactionId: envelope.transactionId,
                generation: envelope.generation,
                snapshotRevision: envelope.snapshotRevision,
                sourceDeviceId: envelope.sourceDeviceId,
                sessionId: envelope.sessionId ?? envelope.snapshot.sessionId,
              },
              epoch,
            );
          } catch (error) {
            this.pending = null;
            await this.rollback(before);
            throw error;
          }
          break;
        }
        case "prepare_relinquish": {
          if (envelope.sessionId && envelope.sessionId !== this.state.sessionId)
            throw new Error("source session changed");
          const final = await this.snapshot(await audio.pauseAndGetFullState());
          if (!final) throw new Error("source has no playback");
          this.send(
            {
              type: "relinquish_ack",
              transactionId: envelope.transactionId,
              snapshot: final,
            },
            epoch,
          );
          break;
        }
        case "handoff_committed": {
          if (
            this.pending &&
            this.pending.transactionId !== envelope.transactionId
          )
            return;
          await this.prepare(envelope.snapshot, true);
          this.state = {
            sessionId: envelope.snapshot.sessionId,
            generation: envelope.newGeneration,
            revision: 0,
          };
          this.options.saveState(this.state);
          this.controlling = false;
          this.superseded = false;
          this.pending = null;
          await this.publish();
          break;
        }
        case "handoff_failed": {
          if (this.pending?.transactionId === envelope.transactionId) {
            const { before } = this.pending;
            this.pending = null;
            await this.rollback(before);
          }
          break;
        }
        case "session_superseded": {
          if (envelope.sessionId && envelope.sessionId !== this.state.sessionId)
            return;
          this.superseded = true;
          await audio.pause();
          this.state = { sessionId: randomUUID(), generation: 1, revision: 0 };
          this.options.saveState(this.state);
          break;
        }
      }
    });
  }

  private send(message: Record<string, unknown>, epoch = this.epoch): void {
    if (this.connected && epoch === this.epoch)
      this.options.send({ version: 1, messageId: randomUUID(), ...message });
  }

  private async rollback(before: NativeFullState): Promise<void> {
    if (before.currentSongId)
      await this.options.audio.restoreQueueState(before, before.isPlaying);
    else await this.options.audio.clear();
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation, operation);
    this.tail = result.catch(() => {});
    return result;
  }

  private schedulePublish(): void {
    if (!this.connected || this.publishTimer) return;
    this.publishTimer = setTimeout(() => {
      this.publishTimer = null;
      this.enqueue(() => this.publish()).catch(() => {});
    }, 100);
  }

  private async snapshot(
    state: NativeFullState,
  ): Promise<PlaybackSnapshot | null> {
    const { volume } = await this.options.audio.getSystemVolume();
    return buildPlaybackSnapshotFromNativeFullState(
      this.state.sessionId,
      state,
      { volume: volume * 100 },
    );
  }

  private async publish(): Promise<void> {
    const epoch = this.epoch;
    if (!this.connected || this.controlling || this.pending || this.superseded)
      return;
    await this.options.audio.ready();
    const snapshot = await this.snapshot(
      await this.options.audio.getFullState(),
    );
    if (
      !snapshot ||
      epoch !== this.epoch ||
      !this.connected ||
      this.controlling ||
      this.pending ||
      this.superseded
    )
      return;
    this.state.revision++;
    this.options.saveState({ ...this.state });
    this.send({
      type: "snapshot",
      sessionId: this.state.sessionId,
      generation: this.state.generation,
      snapshotRevision: this.state.revision,
      snapshot,
    });
  }

  private async songs(ids: string[]): Promise<NativeQueueSong[]> {
    const cache = new Map(
      this.options.cachedSongs().map((song) => [String(song.id), song]),
    );
    const resolved = new Map<string, NativeQueueSong>();
    await Promise.all(
      [...new Set(ids)].map((id) =>
        this.metadataLimiter.run(async () => {
          const song =
            cache.get(id) ??
            ((
              await this.options.request({
                path: "/getSong.view",
                query: { id },
              })
            ).data.song as Record<string, unknown> | undefined);
          if (!song || song.id !== id) throw new Error(`missing song: ${id}`);
          resolved.set(id, {
            id,
            title: String(song.title ?? id),
            artist: String(song.artist ?? ""),
            album: String(song.album ?? ""),
            artistId:
              typeof song.artistId === "string" ? song.artistId : undefined,
            albumId:
              typeof song.albumId === "string" ? song.albumId : undefined,
            coverArtId:
              typeof song.coverArt === "string" ? song.coverArt : undefined,
            duration: Number(song.duration ?? 0),
            streamUrl: `aonsoku-media://stream?id=${encodeURIComponent(id)}`,
            song,
          });
        }),
      ),
    );
    return ids.map((id) => resolved.get(id) as NativeQueueSong);
  }

  private async prepare(
    snapshot: PlaybackSnapshot,
    autoplay: boolean,
  ): Promise<void> {
    if (snapshot.mediaKind !== "song" || !snapshot.songId)
      throw new Error("unsupported handoff media");
    const ids = [
      ...snapshot.contextQueue,
      ...snapshot.userQueue,
      ...snapshot.restorePrevious,
      snapshot.songId,
    ];
    const songs = await this.songs(ids);
    const byId = new Map(songs.map((song) => [song.id, song]));
    const context = snapshot.contextQueue.length
      ? snapshot.contextQueue.map((id) => byId.get(id) as NativeQueueSong)
      : [byId.get(snapshot.songId) as NativeQueueSong];
    const user = snapshot.userQueue.map(
      (id) => byId.get(id) as NativeQueueSong,
    );
    const sourceId = decodeSourceId(snapshot.sourceId);
    let originals = context;
    if (sourceId?.type === "album" || sourceId?.type === "playlist") {
      try {
        const isAlbum = sourceId.type === "album";
        const data = (
          await this.options.request({
            path: isAlbum ? "/getAlbum.view" : "/getPlaylist.view",
            query: { id: sourceId.id },
          })
        ).data;
        const source = data[isAlbum ? "album" : "playlist"] as
          | Record<string, unknown>
          | undefined;
        const entries = source?.[isAlbum ? "song" : "entry"] as
          | Array<{ id: string }>
          | undefined;
        if (entries?.length)
          originals = await this.songs(entries.map((song) => song.id));
      } catch {
        // The transferred queue remains playable after the source is deleted
        // or unavailable; original order is optional shuffle metadata.
      }
    }
    const state: NativeFullState = {
      contextQueue: {
        songs: context,
        currentIndex: snapshot.contextIndex ?? 0,
        sourceId,
        sourceName: snapshot.sourceName,
      },
      userQueue: user,
      originalContextSongs: originals,
      originalUserSongs: [...user],
      shuffleHistory: [],
      shuffleStartHistory: [],
      playedUserQueueHistory: snapshot.restorePrevious.map(
        (id) => byId.get(id) as NativeQueueSong,
      ),
      isInUserQueue: snapshot.inUserQueue,
      isShuffleActive: snapshot.shuffle,
      loopState: snapshot.repeat,
      isPlaying: autoplay,
      currentTime: snapshot.progressSeconds,
      duration: snapshot.durationSeconds,
      currentSongId: snapshot.songId,
      isRestored: true,
    };
    await this.options.audio.clearRemotePlaybackState();
    await this.options.audio.restoreQueueState(state, autoplay);
    if (autoplay && snapshot.volume !== null)
      await this.options.audio.setSystemVolume({ value: snapshot.volume });
  }

  private async execute(command: RemoteCommand): Promise<void> {
    const audio = this.options.audio;
    switch (command.type) {
      case "play":
        return audio.play();
      case "pause":
        return audio.pause();
      case "toggle_play_pause":
        return (await audio.getFullState()).isPlaying
          ? audio.pause()
          : audio.play();
      case "next":
        return audio.skipToNext();
      case "previous":
        return audio.skipToPrevious();
      case "seek":
        return audio.seek({ position: command.seconds });
      case "set_volume":
        await audio.setSystemVolume({ value: command.volume });
        return;
      case "set_shuffle":
        return audio.setShuffle({ enabled: command.enabled });
      case "set_repeat": {
        if (!["off", "one", "all"].includes(command.mode))
          throw new Error("invalid repeat mode");
        return audio.setRepeatMode({
          mode: command.mode as "off" | "one" | "all",
        });
      }
      case "clear_queue":
        return audio.clearUserQueue();
      case "play_song":
        return audio.setContextQueue({
          songs: await this.songs([command.song_id]),
          currentIndex: 0,
          autoplay: true,
        });
      case "play_at_index":
        return audio.setContextQueue({
          songs: await this.songs(command.song_ids),
          currentIndex: command.index,
          autoplay: true,
        });
      case "play_album":
      case "play_playlist": {
        const album = command.type === "play_album";
        const id = album ? command.album_id : command.playlist_id;
        const data = (
          await this.options.request({
            path: album ? "/getAlbum.view" : "/getPlaylist.view",
            query: { id },
          })
        ).data;
        const source = data[album ? "album" : "playlist"] as Record<
          string,
          unknown
        >;
        const entries = source[album ? "song" : "entry"] as Array<{
          id: string;
        }>;
        const songs = await this.songs(entries.map((song) => song.id));
        await audio.setContextQueue({
          songs,
          currentIndex: command.index ?? 0,
          sourceId: { type: album ? "album" : "playlist", id },
          sourceName: String(source.name ?? ""),
          autoplay: true,
        });
        if (command.shuffle) await audio.setShuffle({ enabled: true });
        return;
      }
      case "add_to_queue_next":
      case "add_to_queue_last":
        return audio.addToUserQueue({
          songs: await this.songs(command.song_ids),
          position: command.type === "add_to_queue_next" ? "next" : "last",
        });
      case "remove_from_queue": {
        const state = await audio.getFullState();
        return audio.removeFromUserQueue({
          indices: state.userQueue.flatMap((song, index) =>
            command.song_ids.includes(song.id) ? [index] : [],
          ),
        });
      }
      case "reorder_queue": {
        const state = await audio.getFullState();
        const offset = state.contextQueue.currentIndex + 1;
        const start = command.from - offset;
        const end = command.to - offset;
        if (
          start >= 0 &&
          end >= 0 &&
          start < state.userQueue.length &&
          end < state.userQueue.length
        ) {
          const [song] = state.userQueue.splice(start, 1);
          state.userQueue.splice(end, 0, song);
          await audio.clearUserQueue();
          await audio.addToUserQueue({
            songs: state.userQueue,
            position: "last",
          });
        } else if (
          start >= state.userQueue.length &&
          end >= state.userQueue.length
        ) {
          await audio.reorderContextQueue({
            fromIndex: command.from - state.userQueue.length,
            toIndex: command.to - state.userQueue.length,
          });
        } else throw new Error("cannot reorder across queue sections");
        return;
      }
      case "toggle_like": {
        const id = (await audio.getFullState()).currentSongId;
        if (!id) throw new Error("no current song");
        const song = (
          await this.options.request({ path: "/getSong.view", query: { id } })
        ).data.song as Record<string, unknown>;
        await this.options.request({
          path: song.starred ? "/unstar.view" : "/star.view",
          query: { id },
        });
        return audio.setLikeActive({ active: !song.starred });
      }
    }
  }
}

function decodeSourceId(value: string | null): NativeQueueSourceId | null {
  const [type, ...rest] = (value ?? "").split(":");
  const id = rest.join(":");
  if (!id || !["album", "playlist", "artist", "genre", "radio"].includes(type))
    return null;
  return { type: type as NativeQueueSourceId["type"], id };
}
