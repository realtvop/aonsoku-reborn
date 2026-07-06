import { Keyboard } from "@capacitor/keyboard";
import { Capacitor } from "@capacitor/core";
import { useEffect } from "react";
import { useAppStore } from "@/store/app.store";

const scrollDismissKeyboardSelector = "[data-scroll-dismiss-keyboard='true']";

function shouldDismissKeyboardOnScroll(activeEl: Element | null) {
  if (!(activeEl instanceof HTMLElement)) {
    return false;
  }

  return activeEl.closest(scrollDismissKeyboardSelector) !== null;
}

export function KeyboardObserver() {
  const commandOpen = useAppStore((state) => state.command.open);

  useEffect(() => {
    if (!Capacitor.isNativePlatform()) {
      return;
    }

    if (Capacitor.getPlatform() === "ios") {
      Keyboard.setAccessoryBarVisible({ isVisible: false }).catch((err) => {
        console.debug("[KeyboardObserver] setAccessoryBarVisible failed:", err);
      });
    }

    const isAndroid = Capacitor.getPlatform() === "android";

    if (commandOpen) {
      return;
    }

    let keyboardVisible = false;

    const onShow = () => {
      keyboardVisible = true;
    };

    const onHide = () => {
      keyboardVisible = false;
    };

    const onScrollOrTouch = () => {
      if (keyboardVisible) {
        const activeEl = document.activeElement;
        if (isAndroid && !shouldDismissKeyboardOnScroll(activeEl)) {
          return;
        }

        if (
          activeEl instanceof HTMLInputElement ||
          activeEl instanceof HTMLTextAreaElement
        ) {
          activeEl.blur();
        }
        Keyboard.hide();
      }
    };

    Keyboard.addListener("keyboardWillShow", onShow);
    Keyboard.addListener("keyboardDidShow", onShow);
    Keyboard.addListener("keyboardWillHide", onHide);
    Keyboard.addListener("keyboardDidHide", onHide);
    document.addEventListener("scroll", onScrollOrTouch, { capture: true });
    document.addEventListener("touchmove", onScrollOrTouch, { capture: true });

    return () => {
      document.removeEventListener("scroll", onScrollOrTouch, {
        capture: true,
      });
      document.removeEventListener("touchmove", onScrollOrTouch, {
        capture: true,
      });
      Keyboard.removeAllListeners();
    };
  }, [commandOpen]);

  return null;
}
