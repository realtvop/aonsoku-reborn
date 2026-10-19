const { defineConfig } = require("cypress");

module.exports = defineConfig({
  component: {
    specPattern: "src/**/*.cy.{ts,tsx}",
    viewportWidth: 1920,
    viewportHeight: 1080,
    // Cypress runs in its bundled Electron, whose user agent contains
    // "Electron/". The app reads that token to detect the Aonsoku desktop
    // runtime (src/utils/desktop.ts) and then builds aonsoku-media:// URLs
    // instead of the /rest/* requests the specs intercept. Run the
    // components as the web app they are tested as.
    userAgent:
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    devServer: {
      framework: "react",
      bundler: "vite",
    },
  },
});
