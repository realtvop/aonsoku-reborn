import { Elysia } from "elysia";

const app = new Elysia({
  serve: {
    hostname: process.env.SERVER_HOST || "127.0.0.1",
  }
}).get("/", () => "Hello World");

app.listen(process.env.SERVER_PORT || 3000);

console.log(
  `Aonsoku-reborn Coordination Server is running at ${app.server?.hostname}:${app.server?.port}`
);
