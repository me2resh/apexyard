# create-apexyard

Run `npx create-apexyard` to create an ApexYard ops repository.
The command installs the apexyard CLI, then runs `apexyard init`.

In a terminal, `apexyard init` asks each question.
With no terminal, pass `--org` and `--name`, or pass `--yes` to accept the defaults.
Run `npx create-apexyard --help` to see every option.

## What this package installs

- The package contains the CLI release archive for one framework release.
- The package version is the framework version.
- The launcher checks the archive against the SHA-256 in `package.json` before it extracts a file.
- The Homebrew formula for the same release uses the same archive and the same SHA-256.
- The launcher downloads no code and runs no install script.
- `apexyard init` clones the framework at the release tag of this package. Pass `--ref` to choose a different ref.

The CLI goes to `~/.local/share/apexyard/<tag>`.
The launcher links `~/.local/bin/apexyard` to it.
Set `APEXYARD_PREFIX` to use a different directory.

## Requirements

- macOS or Linux, with `bash` and `tar`
- Node.js 22 or later
- `git`, `jq` and `gh`

For other paths than Homebrew, `apexyard doctor` offers missing-tool installs after an explicit yes.
Non-interactive runs install nothing and print the required commands.
