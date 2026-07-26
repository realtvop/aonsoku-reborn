import { useEffect, useState } from "react";

const MOBILE_BREAKPOINT = 768;

function getIsPortraitViewport() {
  if (typeof window === "undefined") {
    return false;
  }

  return window.innerHeight > window.innerWidth;
}

function useMediaQuery(query: string) {
  const [matches, setMatches] = useState(() => {
    if (typeof window !== "undefined") {
      return window.matchMedia(query).matches;
    }
    return false;
  });

  useEffect(() => {
    const mql = window.matchMedia(query);
    const onChange = (event: MediaQueryListEvent) => setMatches(event.matches);

    mql.addEventListener("change", onChange);
    setMatches(mql.matches);

    return () => mql.removeEventListener("change", onChange);
  }, [query]);

  return matches;
}

export function useIsMobile() {
  return useMediaQuery(`(max-width: ${MOBILE_BREAKPOINT - 1}px)`);
}

export function useIsPortraitViewport() {
  const [isPortraitViewport, setIsPortraitViewport] = useState(
    getIsPortraitViewport,
  );

  useEffect(() => {
    const handleResize = () => {
      setIsPortraitViewport(getIsPortraitViewport());
    };

    handleResize();
    window.addEventListener("resize", handleResize);

    return () => window.removeEventListener("resize", handleResize);
  }, []);

  return isPortraitViewport;
}
