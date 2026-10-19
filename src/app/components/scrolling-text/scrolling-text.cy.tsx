import { type ReactNode, useState } from "react";
import { ScrollingText, type ScrollingTextProps } from "./scrolling-text";

const LONG_TEXT =
  "A very long fullscreen title that should keep scrolling without creating extra horizontal whitespace when the right panel is open ".repeat(
    4,
  );
const LONG_SUBTITLE =
  "Artist Alpha, Artist Beta, Artist Gamma, Artist Delta, Artist Epsilon";
const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)";

function getRoot() {
  return cy.getByTestId("scrolling-text");
}

function getTrack() {
  return getRoot().find(".scrolling-text-track");
}

function assertNoAnimations() {
  getTrack().should(($track) => {
    expect($track[0].getAnimations()).to.have.length(0);
  });
}

function assertNoHorizontalOverflow(testId: string) {
  cy.getByTestId(testId).should(($el) => {
    const element = $el[0];
    expect(element.scrollWidth).to.equal(element.clientWidth);
  });
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

function Constrained(props: ScrollingTextProps) {
  return (
    <div className="w-[240px] overflow-x-auto" data-testid="container">
      <ScrollingText {...props} />
    </div>
  );
}

function ResizableTitle({ children }: { children: ReactNode }) {
  const [wide, setWide] = useState(false);

  return (
    <div data-testid="resizable-title">
      <button
        data-testid="toggle-width"
        type="button"
        onClick={() => setWide((value) => !value)}
      >
        Toggle
      </button>
      <div
        className={wide ? "w-[800px]" : "w-[120px]"}
        style={{ transition: "width 0.3s" }}
      >
        <ScrollingText delay={0}>{children}</ScrollingText>
      </div>
    </div>
  );
}

function RerenderingTitle() {
  const [renders, setRenders] = useState(0);
  const [text, setText] = useState(LONG_SUBTITLE);

  return (
    <div>
      <button
        data-testid="rerender"
        type="button"
        onClick={() => setRenders((value) => value + 1)}
      >
        Re-render {renders}
      </button>
      <button
        data-testid="change-text"
        type="button"
        onClick={() => setText(`${LONG_SUBTITLE}, Artist Zeta`)}
      >
        Change text
      </button>
      <div className="w-[240px]">
        <ScrollingText delay={0.1}>
          <p className="text-sm">{text}</p>
        </ScrollingText>
      </div>
    </div>
  );
}

describe("ScrollingText", () => {
  beforeEach(() => {
    cy.viewport("macbook-11");
  });

  it("clips long text without creating horizontal overflow", () => {
    cy.mount(
      <Constrained>
        <h2 className="text-2xl font-bold tracking-tight">{LONG_TEXT}</h2>
      </Constrained>,
    );

    getRoot().should("have.attr", "data-overflowing");
    getRoot()
      .find(".scrolling-text-clone")
      .should("have.css", "display", "flex")
      .and("have.attr", "aria-hidden", "true")
      .and(($clone) => {
        expect(($clone[0] as HTMLElement).inert).to.equal(true);
      });
    assertNoHorizontalOverflow("container");
  });

  it("leaves text that fits static", () => {
    cy.mount(
      <Constrained delay={0}>
        <p className="text-sm text-foreground/70">Short title</p>
      </Constrained>,
    );

    getRoot().should("not.have.attr", "data-overflowing");
    getRoot()
      .find(".scrolling-text-clone")
      .should("have.css", "display", "none");
    cy.wait(200);
    getRoot().should("have.attr", "data-phase", "idle");
    assertNoAnimations();
    assertNoHorizontalOverflow("container");
  });

  it("does not widen a simulated half-width fullscreen info column", () => {
    cy.mount(
      <div className="w-[960px] overflow-x-auto" data-testid="fullscreen-shell">
        <div className="flex h-[240px] w-full overflow-hidden rounded-md border">
          <div className="flex h-full w-1/2 min-w-0 flex-col px-8 pt-6 pb-4">
            <div className="flex min-w-0 flex-1 flex-col items-center justify-center">
              <div className="flex w-full min-w-0 max-w-[clamp(280px,85vw,480px)] flex-col">
                <div className="w-full min-w-0 pb-3 text-center">
                  <ScrollingText>
                    <p className="text-sm text-foreground/70">{LONG_TEXT}</p>
                  </ScrollingText>
                </div>

                <div className="flex min-w-0 items-start justify-between gap-2 pt-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex w-full min-w-0 flex-col gap-1">
                      <ScrollingText>
                        <h2 className="text-2xl font-bold tracking-tight">
                          {LONG_TEXT}
                        </h2>
                      </ScrollingText>
                      <ScrollingText>
                        <p className="text-sm text-foreground/70">
                          {LONG_SUBTITLE}
                        </p>
                      </ScrollingText>
                    </div>
                  </div>
                  <button className="shrink-0 rounded border px-2 py-1">
                    Like
                  </button>
                </div>
              </div>
            </div>
          </div>

          <div className="h-full w-1/2 shrink-0 border-l p-4">Right panel</div>
        </div>
      </div>,
    );

    assertNoHorizontalOverflow("fullscreen-shell");
  });

  it("scrolls one period per cycle and ends where it started", () => {
    cy.mount(
      <Constrained delay={0.1} loop={1}>
        <p className="text-sm">{LONG_SUBTITLE}</p>
      </Constrained>,
    );

    getRoot().should("have.attr", "data-phase", "scrolling");
    getRoot().then(($root) => {
      const root = $root[0];
      const [original, clone] = Array.from(
        root.querySelectorAll<HTMLElement>(".scrolling-text-item"),
      );
      const content = original.querySelector(".scrolling-text-content");
      const period =
        clone.getBoundingClientRect().left -
        original.getBoundingClientRect().left;
      const gap = period - (content?.getBoundingClientRect().width ?? 0);
      const track = root.querySelector(".scrolling-text-track");
      const [motion] = track?.getAnimations() ?? [];
      const keyframes = (motion.effect as KeyframeEffect).getKeyframes();
      const end = new DOMMatrixReadOnly(
        String(keyframes[keyframes.length - 1].transform),
      );

      // The repeat lands exactly on the original, 2.5em after the text.
      expect(end.m41).to.be.closeTo(-period, 0.05);
      expect(gap).to.be.within(35, 36);
      // The leading fade follows the motion in and out.
      expect(root.getAnimations()).to.have.length(2);

      motion.finish();
    });

    getRoot().should("have.attr", "data-phase", "idle");
    getTrack().should("have.css", "transform", "none");
    getRoot().should(($root) => {
      const view = $root[0].ownerDocument.defaultView as Window;
      expect(
        view
          .getComputedStyle($root[0])
          .getPropertyValue("--scrolling-text-fade-start")
          .trim(),
      ).to.equal("0px");
    });
    cy.wait(300);
    getRoot().should("have.attr", "data-phase", "idle");
    assertNoAnimations();
  });

  it("keeps scrolling across re-renders and restarts for new text", () => {
    cy.mount(<RerenderingTitle />);

    getRoot().should("have.attr", "data-phase", "scrolling");
    getTrack().then(($track) => {
      const [motion] = $track[0].getAnimations();

      cy.getByTestId("rerender").click();
      cy.getByTestId("rerender").click();
      getTrack().should(($current) => {
        expect($current[0].getAnimations()[0]).to.equal(motion);
      });

      cy.getByTestId("change-text").click();
      getTrack().should(($current) => {
        const [next] = $current[0].getAnimations();
        expect(motion.playState).to.equal("idle");
        expect(next).to.exist;
        expect(next).not.to.equal(motion);
      });
    });
  });

  it("returns to rest and holds while hovered when pauseOnHover is set", () => {
    cy.mount(
      <div className="p-8">
        <Constrained delay={0.1} pauseOnHover>
          <p className="text-sm">{LONG_SUBTITLE}</p>
        </Constrained>
      </div>,
    );

    getRoot().should("have.attr", "data-phase", "scrolling");
    cy.wait(800);
    getRoot().realHover();
    getRoot().should("have.attr", "data-phase", "idle");
    getTrack().should("have.css", "transform", "none");
    assertNoAnimations();
    cy.wait(400);
    getRoot().should("have.attr", "data-phase", "idle");

    cy.get("body").realHover({ position: "bottomRight" });
    getRoot().should("have.attr", "data-phase", "scrolling");
  });

  it("stays still when the user prefers reduced motion", () => {
    cy.window().then((win) => {
      const nativeMatchMedia = win.matchMedia.bind(win);

      cy.stub(win, "matchMedia").callsFake((query: string) =>
        query === REDUCED_MOTION_QUERY
          ? createMatchMediaList(query, true)
          : nativeMatchMedia(query),
      );
    });

    cy.mount(
      <Constrained delay={0}>
        <p className="text-sm">{LONG_SUBTITLE}</p>
      </Constrained>,
    );

    getRoot().should("have.attr", "data-overflowing");
    cy.wait(300);
    getRoot().should("have.attr", "data-phase", "idle");
    assertNoAnimations();
  });

  it("stops and resets when the container grows to fit the text", () => {
    cy.mount(
      <ResizableTitle>
        <p className="text-sm text-foreground/70">
          A moderately long title text for resize testing
        </p>
      </ResizableTitle>,
    );

    getRoot().should("have.attr", "data-phase", "scrolling");
    cy.getByTestId("toggle-width").click();

    getRoot().should("not.have.attr", "data-overflowing");
    getRoot().should("have.attr", "data-phase", "idle");
    getTrack().should("have.css", "transform", "none");
    assertNoAnimations();
    assertNoHorizontalOverflow("resizable-title");
  });

  it("leaves clicks next to the text to the elements below", () => {
    const onClick = cy.stub().as("below");

    cy.mount(
      <div className="flex w-[240px] flex-col">
        <ScrollingText>
          <p className="text-sm">{LONG_SUBTITLE}</p>
        </ScrollingText>
        <button type="button" className="h-6 text-left" onClick={onClick}>
          Below
        </button>
      </div>,
    );

    getRoot().should("have.attr", "data-overflowing");
    cy.contains("button", "Below").click(120, 1);
    cy.get("@below").should("have.been.calledOnce");
  });

  it("follows the parent's alignment while the text fits", () => {
    cy.mount(
      <div className="w-[400px] text-center">
        <ScrollingText>
          <p className="text-sm">Short title</p>
        </ScrollingText>
      </div>,
    );

    getRoot().should("have.attr", "data-align", "center");
    getRoot()
      .find(".scrolling-text-item")
      .first()
      .should(($item) => {
        const item = $item[0].getBoundingClientRect();
        const root = $item[0]
          .closest(".scrolling-text")
          ?.getBoundingClientRect();

        expect(root).to.exist;
        expect(item.left - (root?.left ?? 0)).to.be.closeTo(
          (root?.right ?? 0) - item.right,
          1,
        );
      });
  });
});
