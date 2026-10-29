# create-apexyard

Run `npx create-apexyard` with the options for `apexyard init`.
If the CLI is absent, this command installs it before it creates the repository.
Set `APEXYARD_VERSION` to a release tag until the package contains a stamped installer.
Set `APEXYARD_PREFIX` to select the CLI install directory.

Homebrew installs jq and gh as dependencies.
For other paths, `apexyard doctor` offers missing-tool installs after an explicit yes.
Non-interactive runs install nothing and print the required commands.
