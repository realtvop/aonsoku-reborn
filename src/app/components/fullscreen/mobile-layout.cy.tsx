import { usePlayerStore } from "@/store/player.store";
import type { ISong } from "@/types/responses/song";
import { MobileLayout } from "./mobile-layout";

function mountMobileLayout() {
  cy.mount(
    <div className="h-screen w-screen">
      <MobileLayout />
    </div>,
  );
}

describe("MobileLayout", () => {
  beforeEach(() => {
    cy.changeLang("en-US");
    cy.viewport("iphone-x");
    cy.mockCoverArt();
  });

  it("renders a single settings trigger in the mobile header", () => {
    cy.fixture("songs/random").then((songs: ISong[]) => {
      const { actions } = usePlayerStore.getState();

      actions.setSongList(songs, 0);
      actions.openFullscreenPlayer("playing");

      mountMobileLayout();

      cy.get('button[aria-label="Settings"]')
        .should("have.length", 1)
        .and("be.visible");
    });
  });

  it("honors the requested queue tab when fullscreen opens on mobile", () => {
    cy.fixture("songs/random").then((songs: ISong[]) => {
      const { actions } = usePlayerStore.getState();

      actions.setSongList(songs, 0);
      actions.openFullscreenPlayer("queue");

      mountMobileLayout();

      cy.getByTestId("fullscreen-mobile-layout").should("exist");
    });
  });

  it("keeps the unified playing layout on compact mobile heights", () => {
    cy.viewport(375, 667);

    cy.fixture("songs/random").then((songs: ISong[]) => {
      const { actions } = usePlayerStore.getState();

      actions.setSongList(songs, 0);
      actions.openFullscreenPlayer("playing");

      mountMobileLayout();

      cy.getByTestId("fullscreen-playing-view").should("be.visible");
      cy.get('[data-testid="fullscreen-volume-bar"]').should("be.visible");
      cy.get('[role="tablist"]').should("be.visible");
    });
  });

  it("keeps the unified playing layout on wide mobile screens", () => {
    cy.viewport(768, 1024);

    cy.fixture("songs/random").then((songs: ISong[]) => {
      const { actions } = usePlayerStore.getState();

      actions.setSongList(songs, 0);
      actions.openFullscreenPlayer("playing");

      mountMobileLayout();

      cy.getByTestId("fullscreen-playing-view").should("be.visible");
      cy.get('[data-testid="fullscreen-volume-bar"]').should("be.visible");
      cy.get('[role="tablist"]').should("be.visible");
    });
  });
});
