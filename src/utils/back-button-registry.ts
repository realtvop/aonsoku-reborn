export type BackButtonHandler = () => boolean;

interface BackButtonHandlerEntry {
  handler: BackButtonHandler;
  priority: number;
  order: number;
}

interface BackButtonHandlerOptions {
  priority?: number;
}

let nextOrder = 0;
const handlers: BackButtonHandlerEntry[] = [];

/**
 * Register a back button handler. Handlers are executed by priority, then LIFO
 * (Last-In, First-Out) order within the same priority.
 * The handler should return `true` if it handled the back press (e.g. closed a modal),
 * or `false` if it did not.
 */
export function registerBackButtonHandler(
  handler: BackButtonHandler,
  options: BackButtonHandlerOptions = {},
) {
  handlers.push({
    handler,
    priority: options.priority ?? 0,
    order: nextOrder,
  });
  nextOrder += 1;
}

/**
 * Unregister a back button handler.
 */
export function unregisterBackButtonHandler(handler: BackButtonHandler) {
  const index = handlers.findIndex((entry) => entry.handler === handler);
  if (index !== -1) {
    handlers.splice(index, 1);
  }
}

/**
 * Execute the registered back button handlers.
 * Returns `true` if any handler intercepted/handled the back event, `false` otherwise.
 */
export function executeBackButtonHandlers(): boolean {
  const orderedHandlers = [...handlers].sort((a, b) => {
    const priorityDelta = b.priority - a.priority;
    return priorityDelta === 0 ? b.order - a.order : priorityDelta;
  });

  for (const entry of orderedHandlers) {
    const handled = entry.handler();
    if (handled) {
      return true;
    }
  }
  return false;
}

let activeHeaderBackHandler: (() => void) | null = null;

export function registerHeaderBackHandler(handler: () => void) {
  activeHeaderBackHandler = handler;
}

export function unregisterHeaderBackHandler(handler: () => void) {
  if (activeHeaderBackHandler === handler) {
    activeHeaderBackHandler = null;
  }
}

export function getActiveHeaderBackHandler(): (() => void) | null {
  return activeHeaderBackHandler;
}
