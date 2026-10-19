import { LoopState } from "@/types/playerContext";
import { ISong } from "@/types/responses/song";
import { MiniPlayerContext, MiniPlayerContextValue } from "./context";
import { MiniPlayerSongTitle } from "./song-title";

const noop = () => {};

function createContextValue(song: ISong): MiniPlayerContextValue {
  return {
    state: {
      isPlaying: false,
      isTransitioning: false,
      isBuffering: false,
      shuffleActive: false,
      loopState: LoopState.Off,
      hasPrev: false,
      hasNext: false,
      isSongStarred: false,
      currentSong: {
        id: song.id,
        title: song.title,
        artist: song.artist,
        artists: song.artists?.map(({ id, name }) => ({ id, name })),
        coverArt: song.coverArt,
        albumId: song.albumId,
      },
      progress: 0,
      duration: song.duration,
      volume: 100,
      mediaType: "song",
      currentSongColor: null,
      currentLine: null,
    },
    actions: {
      togglePlayPause: noop,
      playNextSong: noop,
      playPrevSong: noop,
      toggleShuffle: noop,
      toggleLoop: noop,
      seek: noop,
      setVolume: noop,
      starCurrentSong: noop,
    },
  };
}

// The title renders inside the mini player context, which the app supplies
// from the player store (Web PiP) or the Electron window's sync channel.
function mountSongTitle(song: ISong) {
  cy.mount(
    <MiniPlayerContext.Provider value={createContextValue(song)}>
      <div className="w-80">
        <MiniPlayerSongTitle />
      </div>
    </MiniPlayerContext.Provider>,
  );
}

describe("MiniPlayerSongTitle", () => {
  it("displays the song title on mobile screens", () => {
    cy.viewport("iphone-x");

    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountSongTitle(song);

      // ScrollingText renders an inert, aria-hidden repeat after the original.
      cy.getByTestId("track-title")
        .first()
        .should("be.visible")
        .and("have.text", song.title);
    });
  });

  it("displays the song title on desktop", () => {
    cy.viewport("macbook-11");

    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountSongTitle(song);

      cy.getByTestId("track-title")
        .first()
        .should("be.visible")
        .and("have.text", song.title);
    });
  });

  it("displays the artist name", () => {
    cy.viewport("macbook-11");

    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountSongTitle(song);

      cy.contains("span", song.artist).should("be.visible");
    });
  });
});
