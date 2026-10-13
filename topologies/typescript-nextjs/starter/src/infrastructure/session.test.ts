import { describe, expect, it } from "vitest";
import { sessionCookieHeader } from "./session";

describe("session cookie", () => {
  it("sets HttpOnly and SameSite=Lax", () => {
    const header = sessionCookieHeader("demo-session", "");
    expect(header).toContain("HttpOnly");
    expect(header).toContain("SameSite=Lax");
    expect(header).not.toContain("Secure");
  });

  it("sets Secure only when COOKIE_SECURE is true", () => {
    expect(sessionCookieHeader("demo-session", "true")).toContain("Secure");
    expect(sessionCookieHeader("demo-session", "false")).not.toContain("Secure");
    expect(sessionCookieHeader("demo-session", "TRUE")).not.toContain("Secure");
    const previous = process.env.COOKIE_SECURE;
    process.env.COOKIE_SECURE = "true";
    expect(sessionCookieHeader("demo-session")).toContain("Secure");
    if (previous === undefined) delete process.env.COOKIE_SECURE;
    else process.env.COOKIE_SECURE = previous;
  });

  it("rejects an unsafe token", () => {
    expect(sessionCookieHeader("", "")).toBeNull();
    expect(sessionCookieHeader("bad token", "")).toBeNull();
    expect(sessionCookieHeader("bad;token", "")).toBeNull();
  });
});
