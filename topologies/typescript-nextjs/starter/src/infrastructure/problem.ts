export function problem(status: number, code: string, title: string): Response {
  return new Response(JSON.stringify({ type: "about:blank", title, status, code }), {
    status,
    headers: { "content-type": "application/problem+json" },
  });
}

export function isJsonRequest(request: Request): boolean {
  const raw = request.headers.get("content-type") ?? "";
  const media = raw.split(";")[0]?.trim().toLowerCase() ?? "";
  return media === "application/json";
}
