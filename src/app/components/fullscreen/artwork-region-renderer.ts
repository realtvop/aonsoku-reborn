/** The supported artwork layers share one frame before any outer feathering. */
interface Layer {
  element: Element;
  parents: Element[];
  image?: HTMLImageElement;
}

export function drawCover(
  context: CanvasRenderingContext2D,
  source: CanvasImageSource,
  sourceWidth: number,
  sourceHeight: number,
  x: number,
  y: number,
  width: number,
  height: number,
) {
  const factor = Math.max(width / sourceWidth, height / sourceHeight);
  const cropWidth = width / factor;
  const cropHeight = height / factor;
  context.drawImage(
    source,
    (sourceWidth - cropWidth) / 2,
    (sourceHeight - cropHeight) / 2,
    cropWidth,
    cropHeight,
    x,
    y,
    width,
    height,
  );
}

export function drawRegionMirrors(
  canvas: HTMLCanvasElement,
  region: HTMLCanvasElement,
  inset: number,
) {
  const context = canvas.getContext("2d");
  if (!context) return;
  context.clearRect(0, 0, canvas.width, canvas.height);
  // Clipping the nine equal-size tiles preserves the exact pixel scale at seams.
  for (let row = -1; row <= 1; row++) {
    for (let column = -1; column <= 1; column++) {
      context.save();
      context.translate(
        inset + column * region.width,
        inset + row * region.height,
      );
      if (column !== 0) {
        context.translate(region.width, 0);
        context.scale(-1, 1);
      }
      if (row !== 0) {
        context.translate(0, region.height);
        context.scale(1, -1);
      }
      context.drawImage(region, 0, 0);
      context.restore();
    }
  }
}

/**
 * Paint the current CachedImage/video subtree, then mirror that same frame.
 * Supports its solid backgrounds, centered cover media, default SVG and opacity
 * transitions. This is deliberately not a general-purpose DOM screenshotter.
 * A new kind of artwork decoration must join this composition explicitly.
 */
export function renderArtworkRegion(
  canvas: HTMLCanvasElement,
  source: HTMLDivElement,
  mirrorRatio: number,
  onReady?: () => void,
) {
  const region = document.createElement("canvas");
  const context = region.getContext("2d");
  if (!context || !canvas.getContext("2d")) return () => {};
  let disposed = false;
  let ready = false;
  let raf: number | undefined;
  let dirty = true;
  let layers: Layer[] = [];
  const callbacks = new Map<HTMLVideoElement, number>();
  const images = new Map<Element, HTMLImageElement>();
  const events = [
    "load",
    "error",
    "loadeddata",
    "playing",
    "pause",
    "seeked",
    "transitionrun",
    "transitionend",
    "transitioncancel",
  ];

  function invalidate() {
    dirty = true;
    schedule();
  }

  function schedule() {
    if (!disposed && raf === undefined) raf = requestAnimationFrame(paint);
  }

  function rebuild() {
    layers = [];
    const visit = (element: Element, parents: Element[]) => {
      const layer: Layer = { element, parents };
      if (element instanceof SVGSVGElement) {
        let image = images.get(element);
        if (!image) {
          image = new Image();
          const clone = element.cloneNode(true) as SVGSVGElement;
          const style = getComputedStyle(element);
          clone.setAttribute("xmlns", "http://www.w3.org/2000/svg");
          clone.setAttribute("color", style.color);
          clone.setAttribute("width", "24");
          clone.setAttribute("height", "24");
          image.onload = schedule;
          image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(clone))}`;
          images.set(element, image);
        }
        layer.image = image;
      }
      layers.push(layer);
      if (element instanceof SVGSVGElement) return;
      for (const child of element.children) visit(child, [...parents, element]);
    };
    for (const child of source.children) visit(child, []);
    for (const [element, image] of images) {
      if (!source.contains(element)) {
        image.onload = null;
        images.delete(element);
      }
    }
    for (const [video, handle] of callbacks) {
      if (!source.contains(video)) {
        video.cancelVideoFrameCallback(handle);
        callbacks.delete(video);
      }
    }
    dirty = false;
  }

  function watchVideo(video: HTMLVideoElement) {
    if (video.paused || video.ended || callbacks.has(video)) return;
    if (typeof video.requestVideoFrameCallback === "function") {
      callbacks.set(
        video,
        video.requestVideoFrameCallback(() => {
          callbacks.delete(video);
          schedule();
        }),
      );
    } else {
      schedule();
    }
  }

  function paint() {
    raf = undefined;
    if (disposed || !context) return;
    if (dirty) rebuild();
    const bounds = source.getBoundingClientRect();
    if (!bounds.width || !bounds.height) return;
    // This bounds only the display buffer, never the native video's resolution.
    const size = Math.min(
      1440,
      Math.max(
        1,
        Math.round(canvas.getBoundingClientRect().width * devicePixelRatio),
      ),
    );
    const inset = Math.round(size * mirrorRatio);
    const centerSize = Math.max(1, size - inset * 2);
    if (canvas.width !== size || canvas.height !== size) {
      canvas.width = canvas.height = size;
    }
    if (region.width !== centerSize || region.height !== centerSize) {
      region.width = region.height = centerSize;
    }
    context.clearRect(0, 0, centerSize, centerSize);
    const styles = new Map<Element, CSSStyleDeclaration>();
    const styleFor = (element: Element) => {
      let style = styles.get(element);
      if (!style) {
        style = getComputedStyle(element);
        styles.set(element, style);
      }
      return style;
    };
    for (const layer of layers) {
      const { element, parents } = layer;
      const style = styleFor(element);
      let opacity = 1;
      for (const ancestor of [...parents, element]) {
        const ancestorStyle = styleFor(ancestor);
        if (
          ancestorStyle.display === "none" ||
          ancestorStyle.visibility === "hidden"
        ) {
          opacity = 0;
          break;
        }
        opacity *= Number(ancestorStyle.opacity);
      }
      // Keep a playing candidate observable even while its fade starts at zero.
      if (element instanceof HTMLVideoElement) watchVideo(element);
      if (opacity === 0) continue;
      const rect = element.getBoundingClientRect();
      const x = ((rect.left - bounds.left) / bounds.width) * centerSize;
      const y = ((rect.top - bounds.top) / bounds.height) * centerSize;
      const width = (rect.width / bounds.width) * centerSize;
      const height = (rect.height / bounds.height) * centerSize;
      if (!width || !height) continue;
      context.globalAlpha = opacity;
      context.fillStyle = style.backgroundColor;
      context.fillRect(x, y, width, height);
      if (
        element instanceof HTMLImageElement &&
        element.complete &&
        element.naturalWidth
      ) {
        drawCover(
          context,
          element,
          element.naturalWidth,
          element.naturalHeight,
          x,
          y,
          width,
          height,
        );
      } else if (
        element instanceof HTMLVideoElement &&
        element.readyState >= 2 &&
        element.videoWidth
      ) {
        drawCover(
          context,
          element,
          element.videoWidth,
          element.videoHeight,
          x,
          y,
          width,
          height,
        );
      } else if (layer.image?.complete && layer.image.naturalWidth) {
        context.drawImage(layer.image, x, y, width, height);
      }
    }
    context.globalAlpha = 1;
    drawRegionMirrors(canvas, region, inset);
    if (!ready) {
      ready = true;
      onReady?.();
    }
    // Frame callbacks drive motion; rAF is needed only while a CSS fade runs.
    if (
      source
        .getAnimations({ subtree: true })
        .some((animation) => animation.playState === "running")
    ) {
      schedule();
    }
  }

  const mutations = new MutationObserver(invalidate);
  mutations.observe(source, {
    childList: true,
    subtree: true,
    attributes: true,
  });
  const resize = new ResizeObserver(schedule);
  resize.observe(source);
  for (const event of events) source.addEventListener(event, invalidate, true);
  // Theme changes can alter the placeholder and SVG colors without DOM changes.
  const theme = new MutationObserver(() => {
    for (const image of images.values()) image.onload = null;
    images.clear();
    invalidate();
  });
  theme.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["class", "style"],
  });
  schedule();
  return () => {
    disposed = true;
    if (raf !== undefined) cancelAnimationFrame(raf);
    for (const [video, handle] of callbacks)
      video.cancelVideoFrameCallback(handle);
    for (const image of images.values()) image.onload = null;
    mutations.disconnect();
    resize.disconnect();
    theme.disconnect();
    for (const event of events)
      source.removeEventListener(event, invalidate, true);
  };
}
