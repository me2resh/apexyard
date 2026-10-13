const tokenPattern = /^[A-Za-z0-9_-]{1,128}$/;

export function sessionCookieHeader(token: string, secure: string | undefined = process.env.COOKIE_SECURE): string | null {
  if (!tokenPattern.test(token)) {
    return null;
  }
  const parts = [`session=${token}`, "Path=/", "HttpOnly", "SameSite=Lax"];
  if (secure === "true") {
    parts.push("Secure");
  }
  return parts.join("; ");
}
