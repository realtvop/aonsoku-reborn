/**
 * Platform detection utilities
 */

/**
 * Detect if the current device is running iOS (iPhone, iPad, iPod Touch)
 */
export function isIOS(): boolean {
  // Check userAgent for iOS devices
  const userAgent = window.navigator.userAgent.toLowerCase();
  const platform = window.navigator.platform.toLowerCase();

  // Check for iOS devices
  const isIOSDevice =
    /iphone|ipad|ipod/.test(platform) ||
    (/mac/.test(platform) && "ontouchend" in document); // iPad on iOS 13+ reports as Mac

  // Also check userAgent as fallback
  const isIOSUA = /iphone|ipad|ipod/.test(userAgent);

  return isIOSDevice || isIOSUA;
}

/**
 * Detect if the current device is an iPad
 */
export function isIPad(): boolean {
  const userAgent = window.navigator.userAgent.toLowerCase();
  const platform = window.navigator.platform.toLowerCase();

  // iPad on iOS 13+ reports as Mac with touch support
  const isIPadNew = /mac/.test(platform) && "ontouchend" in document;

  // Older iPads
  const isIPadOld = /ipad/.test(platform) || /ipad/.test(userAgent);

  return isIPadNew || isIPadOld;
}

/**
 * Detect if the current browser is Safari
 */
export function isSafari(): boolean {
  const userAgent = window.navigator.userAgent.toLowerCase();
  return /safari/.test(userAgent) && !/chrome/.test(userAgent);
}
