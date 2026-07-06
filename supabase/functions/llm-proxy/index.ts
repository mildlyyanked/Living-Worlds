// Living Worlds LLM key vault (§7): API keys never touch the client.
// The Flutter app points OpenRouterLlmClient.baseUrl at
// `${SUPABASE_URL}/functions/v1/llm-proxy` with the user's Supabase JWT;
// this function attaches the OpenRouter key server-side and forwards.
//
// Deploy:  supabase functions deploy llm-proxy
// Secret:  supabase secrets set OPENROUTER_API_KEY=sk-or-...
//
// Endpoints proxied 1:1 (same dialect the client already speaks):
//   POST /llm-proxy/chat/completions
//   POST /llm-proxy/embeddings

const OPENROUTER_BASE = "https://openrouter.ai/api/v1";
const ALLOWED = new Set(["chat/completions", "embeddings"]);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return json(405, { error: "POST only" });
  }
  const key = Deno.env.get("OPENROUTER_API_KEY");
  if (!key) {
    return json(500, { error: "OPENROUTER_API_KEY secret not configured" });
  }

  // Path after the function name, e.g. "chat/completions".
  const url = new URL(req.url);
  const tail = url.pathname.replace(/^.*\/llm-proxy\/?/, "");
  if (!ALLOWED.has(tail)) {
    return json(404, { error: `unknown endpoint "${tail}"` });
  }

  const upstream = await fetch(`${OPENROUTER_BASE}/${tail}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${key}`,
      "HTTP-Referer": "https://living-worlds.app",
      "X-Title": "Living Worlds",
    },
    body: await req.text(),
  });

  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "Content-Type": "application/json" },
  });
});

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
