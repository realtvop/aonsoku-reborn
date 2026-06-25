import { afterEach, describe, expect, it, vi } from "vitest";
import {
  executeBackButtonHandlers,
  type BackButtonHandler,
  registerBackButtonHandler,
  unregisterBackButtonHandler,
} from "./back-button-registry";

const registeredHandlers: BackButtonHandler[] = [];

function register(
  handler: BackButtonHandler,
  options?: Parameters<typeof registerBackButtonHandler>[1],
) {
  registeredHandlers.push(handler);
  registerBackButtonHandler(handler, options);
}

afterEach(() => {
  for (const handler of registeredHandlers) {
    unregisterBackButtonHandler(handler);
  }
  registeredHandlers.length = 0;
});

describe("back-button-registry", () => {
  it("runs handlers in LIFO order when priorities match", () => {
    const first = vi.fn(() => true);
    const second = vi.fn(() => true);

    register(first);
    register(second);

    expect(executeBackButtonHandlers()).toBe(true);
    expect(second).toHaveBeenCalledOnce();
    expect(first).not.toHaveBeenCalled();
  });

  it("runs higher-priority handlers before newer lower-priority handlers", () => {
    const panelHandler = vi.fn(() => true);
    const fullscreenHandler = vi.fn(() => true);

    register(panelHandler, { priority: 10 });
    register(fullscreenHandler);

    expect(executeBackButtonHandlers()).toBe(true);
    expect(panelHandler).toHaveBeenCalledOnce();
    expect(fullscreenHandler).not.toHaveBeenCalled();
  });

  it("falls through to the next handler when the first does not handle", () => {
    const ignored = vi.fn(() => false);
    const handled = vi.fn(() => true);

    register(handled);
    register(ignored, { priority: 10 });

    expect(executeBackButtonHandlers()).toBe(true);
    expect(ignored).toHaveBeenCalledOnce();
    expect(handled).toHaveBeenCalledOnce();
  });
});
