# Origin identity exemptions need offline public proof

> In the context of the staged and runtime leak hooks, facing an origin remote that is private and not a fork of a public repository, I decided to exempt origin identity only when offline proof shows origin is public or a fork of a public repository. I also aligned the staged slug boundary with the runtime hook. A slash is a boundary.

## Context

PR #1476 fixed URL-form private slugs in the public-repo hook and the runtime hook. Code review found two remaining gaps.

The staged and runtime hooks always exempted the `origin` slug, bare name, and owner login. A private non-fork origin that matched a registered project could reach a public tracker.

The staged repo matcher treated `/` as a word character. A private slug inside a GitHub URL, issue URL, path, or markdown link could pass at commit time. The runtime hook already blocked those forms.

The hooks must not call the network. Proof has to come from local config or the registry.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Exempt origin whenever an `upstream` remote exists | Simple. Matches many ops forks. | A private upstream would still exempt a private origin. Fails open. |
| Query GitHub for public or fork status | Ground truth. | Needs network. Fails offline. Adds auth and rate-limit risk. |
| Exempt origin only when origin or upstream is in `public_framework_repos`, or when a registry `public: true` entry names origin (chosen) | Offline. Uses existing config and registry. Fails closed when proof is missing. Keeps staged and runtime in parity. | A fork whose public parent is not configured stays unexempted until the adopter lists it. |
| Exempt origin when it equals a registered `public: true` repo only | Uses the registry alone. | Misses the common ops-fork case where origin is private and upstream is the public framework. |

## Decision

Chosen: **exempt origin identity only with offline proof**.

Proof is any one of these:

1. Origin slug is in `leak_protection.public_framework_repos` (or the shipped default).
2. Upstream slug is in that same list. Origin is then treated as a fork of a known public repository.
3. A registry entry with `public: true` lists the origin slug as its repo.

The known-public list does not auto-append the upstream remote. Auto-append is only for deciding whether a tracker *target* is public. Using it for origin proof would treat every upstream as public.

When proof is missing, origin slug, bare name, and owner login are scrubbed like any other private token.

The staged repo matcher now uses the same boundary class as the runtime and public-repo hooks. A slash may sit before or after a slug.

## Consequences

- A private non-fork origin no longer leaks through either hook.
- A normal ops fork with `upstream` set to a configured public framework repo keeps the origin identity exemption.
- A misconfigured private `upstream` no longer proves origin public by itself.
- Staged commits block private slugs in URL, issue URL, path, and markdown link forms.
- Adopters who fork a public framework that is not in `public_framework_repos` must add that slug to the list before origin identity is exempt.

## Artifacts

- Issue #1477
- Refs #1407, #1435, #1476
- `.claude/hooks/check-private-refs-staged.sh`
- `.claude/hooks/check-private-refs-runtime.sh`
- `.claude/hooks/tests/test_private_refs_origin_and_url_slug.sh`
