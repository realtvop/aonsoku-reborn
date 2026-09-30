import {
  accountId,
  body,
  canonicalUser,
  type Env,
  errorResponse,
  identity,
  json,
  string,
  uuid,
  verify,
} from "./security";

export { AccountCoordinator } from "./account";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (request.method === "OPTIONS") return json(null);
      const url = new URL(request.url);
      if (url.pathname === "/healthz") return json({ status: "ok" });
      if (url.pathname === "/readyz") {
        if (
          !env.STABLE_KEY ||
          env.STABLE_KEY.length < 32 ||
          !env.ALLOWED_IDENTITY_ORIGINS
        ) {
          return json(
            {
              code: "not_ready",
              reason: "configure STABLE_KEY and ALLOWED_IDENTITY_ORIGINS",
            },
            503,
          );
        }
        return await env.ACCOUNTS.get(
          env.ACCOUNTS.idFromName("readiness"),
        ).fetch(new Request(request.url));
      }
      let account: string;
      let device: string | undefined;
      let input: Record<string, unknown> | undefined;
      if (
        request.method === "POST" &&
        ["/v1/auth/challenge", "/v1/auth/register"].includes(url.pathname)
      ) {
        input = await body(request);
        account = await accountId(
          env.STABLE_KEY,
          identity(input.identityUrl, env),
          canonicalUser(input.username),
        );
      } else if (
        request.method === "POST" &&
        url.pathname === "/v1/auth/token"
      ) {
        input = await body(request);
        try {
          account = uuid(
            (
              await verify(
                env.STABLE_KEY,
                string(input.refreshToken),
                "refresh",
                true,
              )
            ).account_id,
          );
        } catch (error) {
          if (!input.challengeId) throw error;
          account = await accountId(
            env.STABLE_KEY,
            identity(input.identityUrl, env),
            canonicalUser(input.username),
          );
        }
      } else if (url.pathname === "/v1/realtime" && request.method === "GET") {
        const claims = await verify(
          env.STABLE_KEY,
          string(url.searchParams.get("ticket")),
          "ticket",
        );
        account = uuid(claims.account_id);
        device = uuid(claims.device_id);
      } else {
        const token = request.headers
          .get("Authorization")
          ?.replace(/^Bearer /, "");
        const claims = await verify(env.STABLE_KEY, string(token));
        account = uuid(claims.account_id);
        device = uuid(claims.device_id);
      }
      // Replace client-supplied routing headers; only this entry point can assign identity.
      const headers = new Headers(request.headers);
      headers.set("X-Account-Id", account);
      headers.delete("X-Device-Id");
      if (device) headers.set("X-Device-Id", device);
      const forwarded = new Request(request.url, {
        method: request.method,
        headers,
        body: input ? JSON.stringify(input) : request.body,
      });
      return await env.ACCOUNTS.get(env.ACCOUNTS.idFromName(account)).fetch(
        forwarded,
      );
    } catch (error) {
      return errorResponse(error);
    }
  },
} satisfies ExportedHandler<Env>;
