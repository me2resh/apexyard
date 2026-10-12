# Use a GitHub App for agent reviews

Rex, Hakim, and Tariq post reviews with `tracker_review_submit`.
The default posts with your `gh` login.
GitHub can treat that approval as your approval.
A GitHub App posts as its own account.
An App review must never satisfy a required human review.

This mode is off until you set it.
The setting is `review_identity` in `.claude/project-config.json`.
See [AgDR-0235](../agdr/AgDR-0235-reviewer-github-app.md).

## Glossary

| Term | Meaning |
| --- | --- |
| Operator login | The `gh` credentials of the person who runs the agent. |
| GitHub App | A registered app that acts as its own GitHub account. |
| App ID | The numeric id of that app. GitHub shows it on the app settings page. |
| Installation | One install of the app on a user or an organization. |
| Installation id | The numeric id of that install. It is in the installation URL. |
| Private key | The PEM file that signs the app credential. Store the file outside git. |
| Installation token | A short-lived token for one installation. The library requests it per review. |
| Fail closed | The review is not posted. The command returns an error. |

## Create the app

Create the app with the GitHub manifest flow.
Do not create a webhook.
Request only these repository permissions:

- Pull requests: write
- Contents: read
- Metadata: read

Save this HTML outside every git work tree.
Do not save it under `.claude/`.
Replace `YOUR_OPS_FORK_URL` with the URL of your ops fork.
Replace the app name with a unique name.

```html
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Create the review app</title></head>
<body>
<form action="https://github.com/settings/apps/new" method="post">
  <input type="hidden" name="manifest" id="manifest">
  <button type="submit">Create the GitHub App</button>
</form>
<script>
document.getElementById("manifest").value = JSON.stringify({
  "name": "ApexYard Reviewer",
  "url": "YOUR_OPS_FORK_URL",
  "public": false,
  "redirect_url": "http://127.0.0.1/github-app/callback",
  "default_permissions": {
    "contents": "read",
    "metadata": "read",
    "pull_requests": "write"
  }
});
</script>
</body>
</html>
```

For an organization, change the form action.
Use `https://github.com/organizations/ORG/settings/apps/new`.
Do not add `hook_attributes`.
Do not add `default_events`.

Open the HTML file in a browser.
Submit the form.
GitHub asks you to confirm the app.
The browser then opens `http://127.0.0.1/github-app/callback?code=...`.
The page does not load.
Copy the `code` value from the address bar.
Treat the code as a secret.
Exchange the code at once.

Run these commands from a directory that is not a git work tree.
Replace `THE_CODE` with the code you copied.

```bash
umask 077
mkdir -p "$HOME/.config/apexyard"
curl -sS -X POST \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app-manifests/THE_CODE/conversions" \
  -o "$HOME/.config/apexyard/manifest-response.json"
jq -r '.id' "$HOME/.config/apexyard/manifest-response.json"
jq -r '.pem' "$HOME/.config/apexyard/manifest-response.json" \
  > "$HOME/.config/apexyard/reviewer.pem"
rm -f "$HOME/.config/apexyard/manifest-response.json"
chmod 600 "$HOME/.config/apexyard/reviewer.pem"
```

The first `jq` command prints the App ID.
The second `jq` command writes the private key to the file.
The response file also holds a client secret and a webhook secret.
The `rm` command deletes that file.
Do not print the private key.
Do not commit the private key.
Do not paste the private key into config or chat.

Confirm the webhook is inactive.
Open the app settings page.
Leave the webhook URL empty.
Leave webhook delivery off.

## Install the app

Open the app settings page.
Install the app on the repositories that agents review.
Select only those repositories.
One installation id covers one user or one organization.
Every reviewed repository must belong to that installation.

Open the installation settings page.
Copy the numeric id from the URL.
A user install looks like `https://github.com/settings/installations/789012`.
An organization install has the same number at the end of its URL.
`789012` is the installation id in that example.

## Store the private key

Keep the PEM file outside every git work tree.
Keep it outside `.claude/`.
`$HOME/.config/apexyard/reviewer.pem` is a valid location.
A path inside this repository is refused.
A path inside another repository is refused.
A symlink into a repository is refused.
A path under a `.claude` directory is refused.

Confirm the location before you set the config.

```bash
git -C "$(dirname "$HOME/.config/apexyard/reviewer.pem")" \
  rev-parse --is-inside-work-tree
```

The command must not print `true`.
Restrict the file to your user with `chmod 600`.

## Set the config

Add `review_identity` to `.claude/project-config.json`.
Do not put the key in that file.
Put the absolute path of the PEM file.

```json
{
  "review_identity": {
    "kind": "github_app",
    "app_id": "123456",
    "installation_id": "789012",
    "private_key_path": "/Users/you/.config/apexyard/reviewer.pem",
    "fallback": ""
  }
}
```

`kind` must be `github_app`.
`app_id` and `installation_id` are decimal numbers.
`fallback` empty means fail closed.
Set `fallback` to `comment` only when a failed app review should post as a comment.

```json
"fallback": "comment"
```

A comment uses the operator login.
A comment does not approve the pull request.
Any other `fallback` value fails closed.
The library does not post the review.

On each `gh` review, the library does four checks.

1. It refuses a private key path inside a git work tree or under `.claude/`.
2. It signs a JWT with the private key. `iat` is 60 seconds in the past. `exp` is 9 minutes ahead.
3. It sends that JWT in `POST /app/installations/<id>/access_tokens`.
4. It sets `GH_TOKEN` to the installation token for that one `gh pr review` command.

The token request uses `https://api.github.com`.
GitHub Enterprise Server is not covered.
The library does not export the token.
The library does not write the token to disk.
The library does not print the token or the private key.
The JWT lives for at most 9 minutes.
GitHub expires the installation token after one hour.
The library requests a new token for each review.

`tracker_pr_merge` does not use the app token.
`/approve-merge` does not use the app token.
Those commands keep the operator login.

GitLab reviews and custom tracker reviews are unchanged.
They ignore `review_identity`.

## Limits

Merging requires `contents: write`.
The app has only `contents: read`.
This library never uses the app token for a merge.
Keep the private key private so nothing else can mint a token.

Keep agents on the `comment` verdict.
Require a CODEOWNERS or team review that excludes the App.
Configure that requirement so a bot `APPROVED` review cannot satisfy the branch rule.
An App review must never satisfy a required human review.
The local `/approve-merge` gate still applies.

`fallback` `comment` does not satisfy a required approving review.
Fail closed posts nothing.
The agent then sees a non-zero exit from `tracker_review_submit`.
