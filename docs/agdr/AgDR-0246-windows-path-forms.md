# AgDR-0246: Compare Windows paths in one POSIX form

> Issues 1724, 1725, 1737, and 1738 share one fix.
> Drive-letter paths use one string transform.
> The reader checks `lstat` when Python has no `O_NOFOLLOW`.

## Context

Git for Windows prints a drive-letter path such as `C:/dir`. Git Bash `pwd -P` prints `/c/dir` for that same directory. Claude Code sends Edit and Write paths as `C:\dir`.

Three gates treated those strings as POSIX paths.

- `bin/install-git-hooks.sh` compared the git toplevel with a resolved `.githooks` path. The forms never matched, so install exited 2.
- `ticket_path_is_meta_exempt` only treated a leading `/` as absolute. A `C:\...\.claude\...` path was joined onto the working directory. The `.claude/` and `docs/` exemptions did not match.
- `rule-excludes.py` opened files with `os.O_NOFOLLOW` and `os.O_NONBLOCK`. Windows Python does not define those names, so the writer crashed.

Issues 1737 and 1725 are the same containment failure. A space in the path is not required.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Call `cygpath` when it exists | Uses the platform tool | Absent on macOS and Linux. Two code paths. |
| Give each call site its own drive-letter rule | Small local edits | The rules drift. #1018 already has this bug class. |
| One string transform, shared by the comparer and the ticket helper | Same rule everywhere. POSIX paths stay unchanged. No `cygpath`. | Does not resolve the path on disk. Callers that already resolved one side must pass that result in. |

## Decision

Chosen: **one string transform**.

`_windows_path_to_posix` in `_lib-path-resolve.sh` maps `C:/` and `C:\` to `/c/` and turns the remaining backslashes in that path into slashes. It lowercases the drive letter. It leaves a POSIX path unchanged. It leaves a drive-relative path such as `C:foo` unchanged, because that path is not absolute. The same line is drawn in `_portfolio_canonicalize` (me2resh/apexyard#1018).

`path_is_under_root` compares both sides after that transform. The installer uses it for the hooks-directory containment check. An empty resolved path is still outside the repo, so a missing path library still stops before `ghp_classify`.

`ticket_path_is_meta_exempt` runs the transform before it decides that a path is absolute. After that, the existing `.claude/`, `docs/`, and `*.md` rules apply. A path under `.claude/worktrees/` that is not a markdown file stays gated.

`require-active-ticket.sh` runs the same transform before its slash tests. A drive-letter source path stays absolute when the working directory is not the repository. If the Git Bash drive root is not present, that path is not treated as outside governance.

`ghp_classify` maps the repository root and the current hooks path before it tests which path is absolute. An existing directory outside the repository stays third-party. The installer does not replace it without `--force`.

`read_safe` calls `lstat` before `open`. A symlink or a non-regular file raises `ValueError`. `O_NOFOLLOW` and `O_NONBLOCK` are added only when Python defines them. On POSIX, `O_NOFOLLOW` still closes the gap between `lstat` and `open`.

## Consequences

- A Windows clone can set `core.hooksPath` to `.githooks`.
- A Write of `.claude/project-config.json` with a Windows path no longer needs an active ticket. A Write of source still does, including when the working directory is not a git repository.
- `write-rule-excludes.sh` can update `claudeMdExcludes` on Windows.
- POSIX containment and POSIX exemptions keep the same results. The transform does not change a path that starts with `/`.

## Known limits

- On Windows, `O_NOFOLLOW` does not exist. A symlink that appears between `lstat` and `open` can still be followed. POSIX does not have that gap.
- `path_is_under_root` does not reject a `..` segment. The installer resolves the directory with `pwd -P` before that check.
- The transform does not interpret a UNC path.

## Architecture evolution

### Before

The installer, the ticket exemption helper, and the rule-exclude reader each assumed a POSIX path. Git for Windows, Git Bash, and Claude Code on Windows do not share one spelling. The installer refused an in-repo hooks directory. The ticket gate missed `.claude/` and `docs/`. The rule-exclude writer crashed on missing open flags.

### After

Drive-letter paths enter one transform in `_lib-path-resolve.sh` before a containment check, a ticket-gate slash test, a hooks-path classification, or an exemption match. The rule-exclude reader refuses a symlink with `lstat` on every platform, and it uses `O_NOFOLLOW` only where Python provides it. POSIX inputs take the same branches they took before.

## Artifacts

- Issues: https://github.com/me2resh/apexyard/issues/1724 https://github.com/me2resh/apexyard/issues/1725 https://github.com/me2resh/apexyard/issues/1737 https://github.com/me2resh/apexyard/issues/1738
- Related: [AgDR-0219](AgDR-0219-worktree-ticket-gate-exemptions.md), me2resh/apexyard#1018
- Helper: `.claude/hooks/_lib-path-resolve.sh`
- Hooks: `.claude/hooks/_lib-ticket-path-exemptions.sh`, `.claude/hooks/require-active-ticket.sh`, `.claude/hooks/_lib-git-hooks-path.sh`, `.claude/hooks/lib/rule-excludes.py`, `bin/install-git-hooks.sh`

## Addendum — Git Bash mounts Temp at /tmp (me2resh/apexyard#1743)

Git for Windows can print `C:/Users/<user>/AppData/Local/Temp/<repo>`.
The string transform in the decision above prints `/c/Users/<user>/AppData/Local/Temp/<repo>`.
Git Bash mounts that Temp directory at `/tmp`.
`pwd -P` then prints `/tmp/<repo>`.

`path_is_under_root` compared the string form with the `pwd -P` form.
Those two strings differ.
`bin/install-git-hooks.sh` exited 2.
The script refused `.githooks` as a directory outside the repository.
`ghp_classify` used the string form for its inside-repository prefix check.

### Choice

`_windows_path_to_posix` calls `cygpath -u --` when `cygpath` is on PATH and the input is a drive-letter path (`X:/` or `X:\`).
The function keeps that output when the output is not empty and starts with `/`.
When that directory exists, the function resolves it with `pwd -P`.
The function does not call `cygpath` for a path that already starts with `/`.

The function uses the string transform when `cygpath` is absent.
It also uses the string transform when `cygpath` exits non-zero, prints nothing, or prints a path that does not start with `/`.
The string transform does not call `pwd -P`.
Linux and macOS do not provide `cygpath`.
On those hosts the string transform is unchanged.

The installer stores this result as the repository root before it tests the hooks directory.
`path_is_under_root` still rejects an empty side.
A failed `cygpath` call leaves the `/c/Users/.../Temp` form.
That form does not match a `/tmp` path.
The containment check rejects the pair.
`--hooks-dir ../outside-hooks` still exits 2.

`cygpath -u` applies the mount table.
The call does not need the directory to exist.
`pwd -P` needs a directory that exists.
Callers also compare a path that is not on disk.
One helper feeds the containment check, `ghp_classify`, the ticket exemption helper, and `require-active-ticket.sh`.

### Architecture evolution

Before this addendum, the string transform made `C:/` and `/c/` compare as one path.
The transform did not read the Git Bash mount table.
A repository under Temp did not match its `/tmp` form.

After this addendum, a drive-letter path uses `cygpath -u` when that program is present.
The mount form matches `pwd -P`.
A host with no `cygpath` keeps the string transform.
A failed `cygpath` call does not make the containment check succeed.

### Verification

The tests use a stub `cygpath` on macOS.
This addendum does not record a run on Git Bash.
