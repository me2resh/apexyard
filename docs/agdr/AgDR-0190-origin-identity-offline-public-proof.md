# Origin identity exemptions need offline public proof

> In the context of the staged and runtime leak hooks, facing an origin remote that is private and not itself proven public, I decided to exempt origin identity only when offline proof shows origin is public. Skills record that proof once via an online check. Hooks never trust the `upstream` remote as proof.

## Context

PR #1476 fixed URL-form private slugs in the public-repo hook and the runtime hook. Code review found two remaining gaps.

The staged and runtime hooks always exempted the `origin` slug, bare name, and owner login. A private non-fork origin that matched a registered project could reach a public tracker.

The staged repo matcher treated `/` as a word character. A private slug inside a GitHub URL, issue URL, path, or markdown link could pass at commit time. The runtime hook already blocked those forms.

PR #1482 first treated a configured-public `upstream` as proof that origin was a public fork. That fails the #1477 criterion. GitHub does not allow a private fork of a public repo. Every private ops repo is a non-fork and usually has `upstream` set to the public framework. Trusting that remote would exempt almost every private origin.

The hooks must not call the network. Proof has to come from local config or the registry. An online check may run once during `/setup` or `/update`.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Exempt origin whenever an `upstream` remote exists | Simple. Matches many ops forks. | A private upstream would still exempt a private origin. Fails open. |
| Exempt origin when `upstream` is in `public_framework_repos` | Offline. Matches the common remote layout. | Private ops repos almost always set that upstream. Fails the #1477 private-origin case. |
| Query GitHub on every hook run | Ground truth. | Needs network. Fails offline. Adds auth and rate-limit risk. |
| Exempt origin only when origin is in `public_framework_repos`, a registry `public: true` entry names origin, or a recorded verified-public slug matches origin (chosen) | Offline in the hooks. Uses existing config and registry. Records proof once online in skills. Fails closed when proof is missing. Keeps staged and runtime in parity. | A public fork gets the exemption only after `/setup` or `/update` records it (or the adopter lists origin in `public_framework_repos`). |

## Decision

Chosen: **exempt origin identity only with offline proof that names origin itself**.

Proof is any one of these:

1. Origin slug is in `leak_protection.public_framework_repos` (or the shipped default).
2. A registry entry with `public: true` lists the origin slug as its repo.
3. `leak_protection.origin_verified_public` holds the exact current origin `owner/repo` slug.

The key name is `leak_protection.origin_verified_public`. It stores one `owner/repo` string. Hooks compare it to the current origin slug with exact equality. A stale value that no longer matches origin grants no exemption.

`/setup` and `/update` record the key through `bin/record-origin-verified-public.sh`. That helper reads the origin slug, runs `gh repo view <slug> --json visibility,isFork`, and writes the key only when visibility is `PUBLIC`. If the repo is private, or the check fails, it writes nothing and tells the operator the origin exemption is off and why.

The known-public list does not auto-append the upstream remote for origin proof. Upstream citation exemptions for tracker *targets* still apply. They do not prove origin is public.

When proof is missing, origin slug, bare name, and owner login are scrubbed like any other private token.

The staged repo matcher uses the same boundary class as the runtime and public-repo hooks. A slash may sit before or after a slug.

## Consequences

- A private non-fork origin no longer leaks through either hook, even when `upstream` points at a configured public framework.
- An adopter with a public fork gets the origin identity exemption after `/setup` or `/update` records `leak_protection.origin_verified_public` for that origin slug.
- A misconfigured or private `upstream` never proves origin public by itself.
- Hooks stay offline and fail closed when the recorded slug is missing or does not match origin.
- Staged commits block private slugs in URL, issue URL, path, and markdown link forms.
- Adopters who list origin in `public_framework_repos`, or mark it `public: true` in the registry, keep the exemption without the recorded key.

## Artifacts

- Issue #1477
- Refs #1407, #1435, #1476, PR #1482
- `.claude/hooks/check-private-refs-staged.sh`
- `.claude/hooks/check-private-refs-runtime.sh`
- `bin/record-origin-verified-public.sh`
- `.claude/hooks/tests/test_private_refs_origin_and_url_slug.sh`
- `.claude/hooks/tests/test_record_origin_verified_public.sh`
