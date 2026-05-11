import { Elysia, t } from "elysia";
import { subsonicProxy } from "./plugins/subsonic-proxy";

const enableProxy = process.env.ENABLE_SUBSONIC_REVERSE_PROXY !== "false";

const app = new Elysia({
  serve: {
    hostname: process.env.SERVER_HOST || "127.0.0.1",
  },
})
  .get("/", () => "Hello World")
  .get(
    "/subsonic",
    () => ({
      url: process.env.SUBSONIC_SERVER_URL || "",
      reverseProxyEnabled: enableProxy,
    }),
    {
      response: {
        200: t.Object({
          url: t.String(),
          reverseProxyEnabled: t.Boolean(),
        }),
      },
    },
  );

if (enableProxy) {
  app.use(subsonicProxy());
}

app.listen(process.env.SERVER_PORT || 3000);

console.log(
  `Aonsoku-reborn Coordination Server is running at ${app.server?.hostname}:${app.server?.port}`,
);