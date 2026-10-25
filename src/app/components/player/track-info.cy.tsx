import { type ReactNode } from "react";
import { useLocation } from "react-router-dom";

import { ISong } from "@/types/responses/song";

import { TrackInfo } from "./track-info";

function LocationDisplay() {
  const location = useLocation();

  return <div data-testid="location-display">{location.pathname}</div>;
}

function Wrapper({ children }: { children: ReactNode }) {
  return (
    <div className="w-full">
      <div className="flex items-center gap-2 w-full">{children}</div>
      <LocationDisplay />
    </div>
  );
}

function mountTrackInfo(song: ISong | undefined) {
  cy.mount(
    <Wrapper>
      <TrackInfo song={song} />
    </Wrapper>,
  );
}

function createMatchMediaList(query: string, matches: boolean): MediaQueryList {
  return {
    addEventListener: () => {},
    addListener: () => {},
    dispatchEvent: () => false,
    matches,
    media: query,
    onchange: null,
    removeEventListener: () => {},
    removeListener: () => {},
  } as MediaQueryList;
}

function stubMatchMedia(matchesByQuery: Record<string, boolean>) {
  cy.window().then((win) => {
    const nativeMatchMedia = win.matchMedia.bind(win);

    cy.stub(win, "matchMedia").callsFake((query: string) => {
      if (query in matchesByQuery) {
        return createMatchMediaList(query, matchesByQuery[query]);
      }

      return nativeMatchMedia(query);
    });
  });
}

// ScrollingText renders an inert, aria-hidden repeat after the original.
function getVisibleTrackTitle() {
  return cy.getByTestId("track-title").first();
}

function getVisibleAlbumLink(albumId: string) {
  return cy.get(`a[href="/library/albums/${albumId}"]`).first();
}

describe("TrackInfo Component", () => {
  beforeEach(() => {
    cy.mockCoverArt();
    cy.viewport("macbook-11");
  });

  it("displays track info without artist navigation when artist id is missing", () => {
    cy.fixture("songs/song").then((song: ISong) => {
      mountTrackInfo(song);

      cy.getByTestId("track-image").should("be.visible");

      getVisibleTrackTitle().should("be.visible").and("have.text", song.title);

      cy.getByTestId("track-artist-url")
        .should("be.visible")
        .and("have.text", song.artist)
        .and("not.have.attr", "href");
    });
  });

  it("navigates to the album on mouse click", () => {
    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountTrackInfo(song);

      getVisibleAlbumLink(song.albumId).click();

      cy.getByTestId("location-display").should(
        "have.text",
        `/library/albums/${song.albumId}`,
      );
    });
  });

  it("navigates to the artist on mouse click", () => {
    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountTrackInfo(song);

      cy.getByTestId("track-artist-url").click();

      cy.getByTestId("location-display").should(
        "have.text",
        `/library/artists/${song.artistId}`,
      );
    });
  });

  it("prevents album navigation when the click is touch-activated", () => {
    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountTrackInfo(song);

      getVisibleAlbumLink(song.albumId)
        .trigger("pointerdown", {
          button: 0,
          eventConstructor: "PointerEvent",
          isPrimary: true,
          pointerType: "touch",
        })
        .trigger("click", { force: true });

      cy.getByTestId("location-display").should("have.text", "/");
    });
  });

  it("prevents artist navigation when the click is touch-activated", () => {
    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountTrackInfo(song);

      cy.getByTestId("track-artist-url")
        .trigger("pointerdown", {
          button: 0,
          eventConstructor: "PointerEvent",
          isPrimary: true,
          pointerType: "touch",
        })
        .trigger("click", { force: true });

      cy.getByTestId("location-display").should("have.text", "/");
    });
  });

  it("disables song text navigation on mobile screens", () => {
    cy.viewport("iphone-x");

    cy.fixture("songs/random").then((songs: ISong[]) => {
      const song = songs[1];

      mountTrackInfo(song);

      getVisibleTrackTitle().should("be.visible").and("have.text", song.title);

      cy.getByTestId("track-artist-url")
        .should("be.visible")
        .and("have.text", song.artist)
        .and("not.have.attr", "href");

      cy.get(`a[href="/library/albums/${song.albumId}"]`).should("not.exist");
      cy.get(`a[href="/library/artists/${song.artistId}"]`).should(
        "not.exist",
      );
    });
  });

  describe("English", () => {
    beforeEach(() => {
      cy.changeLang("en-US");
    });

    it("displays a message if no audio is playing", () => {
      mountTrackInfo(undefined);

      cy.getByTestId("song-no-playing-icon")
        .should("be.visible")
        .and("have.class", "lucide-audio-lines");

      cy.getByTestId("song-no-playing-label")
        .should("be.visible")
        .and("have.text", "No song playing");
    });

    it("creates the fullscreen button", () => {
      cy.fixture("songs/song").then((song: ISong) => {
        mountTrackInfo(song);

        cy.getByTestId("track-fullscreen-button")
          .should("exist");
      });
    });
  });

  describe("Portuguese", () => {
    beforeEach(() => {
      cy.changeLang("pt-BR");
    });

    it("displays a message if no audio is playing", () => {
      mountTrackInfo(undefined);

      cy.getByTestId("song-no-playing-icon")
        .should("be.visible")
        .and("have.class", "lucide-audio-lines");

      cy.getByTestId("song-no-playing-label")
        .should("be.visible")
        .and("have.text", "Nenhuma música tocando");
    });

    it("creates the fullscreen button", () => {
      cy.fixture("songs/song").then((song: ISong) => {
        mountTrackInfo(song);

        cy.getByTestId("track-fullscreen-button")
          .should("exist");
      });
    });
  });
});
