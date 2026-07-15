import ImageHeader from "./image-header";

describe("ImageHeader", () => {
  beforeEach(() => {
    cy.mockCoverArt();
  });

  it("reveals playlist information when cover art is unavailable", () => {
    cy.mount(
      <ImageHeader
        type="Playlist"
        title="No cover playlist"
        coverArtType="album"
        coverArtAlt="No cover playlist"
        badges={[{ content: "3 songs", type: "text" }]}
        isPlaylist
      />,
    );

    cy.getByTestId("default-cover-art").should("be.visible");
    cy.getByTestId("image-header-fallback").should("not.exist");
    cy.get("#detail-page-title")
      .should("be.visible")
      .and("have.text", "No cover playlist");
  });

  it("reveals information from the loading image without a global image id", () => {
    cy.mount(
      <ImageHeader
        type="Playlist"
        title="Covered playlist"
        coverArtId="playlist-cover"
        coverArtType="album"
        coverArtAlt="Covered playlist"
        badges={[{ content: "3 songs", type: "text" }]}
        isPlaylist
      />,
    );

    cy.get('img[alt="Covered playlist"]')
      .should("be.visible")
      .and("not.have.attr", "id");
    cy.getByTestId("image-header-fallback").should("not.exist");
  });
});
