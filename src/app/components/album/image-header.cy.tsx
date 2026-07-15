import ImageHeader from "./image-header";

describe("ImageHeader", () => {
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
});
