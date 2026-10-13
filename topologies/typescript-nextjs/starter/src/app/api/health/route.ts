// public: no auth required
export function GET(): Response {
  return Response.json({ status: "ok" });
}
