# Dev Spaces connector: REH download and Artifactory mirror

Use this when a developer connects to a Dev Space from local VS Code (or Kiro) with the **Dev Spaces Remote Connector**, and the workspace cannot pull the Remote Extension Host (REH) / `vscode-server` binary from the public network.

This is **client IDE configuration**, not a CheCluster or chart value. Nothing in this GitOps chart sets the download URL.

## What gets downloaded

On first connect (and when the IDE commit changes), the connector installs a Linux REH server **inside the workspace pod**. That is the `code-server` / `vscode-server` tarball for the local IDE’s commit — not the connector VSIX and not the workspace source.

Default URL shape (VS Code stable):

```text
https://update.code.visualstudio.com/commit:<commit>/server-<os>-<arch>/stable
```

Example:

```text
https://update.code.visualstudio.com/commit:7e7950df89d055b5a378379db9ee14290772148a/server-linux-x64/stable
```

## Download order

1. The install script in the pod tries `wget` / `curl` of that URL.
2. If the pod fails (air-gap, egress deny, TLS inspection), the connector asks the **laptop** to download the same URL and stream the tarball into the pod.
3. If both fail, connect fails. Baking the matching server into the UDI (see below) skips both downloads.

If the binary is already present at:

```text
$HOME/.vscode-server/bin/<commit>/bin/code-server
```

(or `.kiro-server` for Kiro), the script logs that the server is already installed and does not download.

## Setting the URL in the IDE

| Setting | `devspaces.rehDownloadUrl` |
|---|---|
| Scope | User or workspace settings in VS Code / Kiro |
| Empty | Uses the IDE `product.json` template (or `updateUrl` fallback) |

JSON example with placeholders (filled automatically for commit, OS, arch):

```json
{
  "devspaces.rehDownloadUrl": "https://artifactory.example.com/artifactory/vscode-reh-remote/commit:${commit}/server-${os}-${arch}/stable"
}
```

Supported placeholders: `${commit}`, `${os}`, `${arch}`. The resolved URL is what **both** the pod and the laptop fallback use.

## Artifactory as a mirror

Use a **Generic remote** repository that proxies Microsoft’s update host. Do **not** use Artifactory’s “AI Editor Extension” repository type for this — that is for marketplace VSIX plugins, not the REH tarball.

### Remote repository

| Field | Value |
|---|---|
| Package type | Generic |
| Repository key | e.g. `vscode-reh-remote` |
| Remote URL | `https://update.code.visualstudio.com` |
| Store artifacts locally | Yes (cache on first pull) |

Upstream path the connector expects:

```text
/commit:<commit>/server-<os>-<arch>/<quality>
```

Through Artifactory:

```text
https://artifactory.example.com/artifactory/vscode-reh-remote/commit:<commit>/server-linux-x64/stable
```

### Redirects / CDN

`update.code.visualstudio.com` often returns **302** to a CDN such as `vscode.download.prss.microsoft.com` (host names change over time). Either:

- configure the Artifactory remote to **follow redirects** when fetching, or
- allow the CDN hosts on Artifactory egress (and on any cluster egress the pod uses if it still dials the CDN directly).

If redirects are blocked, the pod download fails and every connect falls back to the laptop transfer path.

### Air-gapped local repo

1. From a machine that can reach Microsoft, download the tarball for the required commit(s).
2. Upload into a **local** generic repo using the same path layout (`commit:<commit>/server-linux-x64/stable` as the artifact path).
3. Point `devspaces.rehDownloadUrl` at that local repo (no remote upstream required).

Re-upload when developers upgrade VS Code (new `product.json` commit).

### Auth to Artifactory

If the repo requires credentials, the pod `wget`/`curl` and the laptop Node download must both be able to authenticate (anonymous read is simplest for this use case). The connector setting is only a URL template; it does not add Artifactory tokens by itself. Prefer anonymous read on an internal network, or a URL that already embeds a read-only identity if your platform allows that pattern.

## Optional: bake into the UDI

To avoid downloads entirely, unpack the REH for the **exact** IDE commit into the image at:

```text
/home/user/.vscode-server/bin/<commit>/
```

(layout after `tar --strip-components 1`, so `bin/code-server` exists under that commit directory). A VS Code update changes the commit and the baked copy is ignored until you refresh the image.

## Windows note (temp cleanup)

When the laptop fallback runs on Windows, the connector downloads into `%LOCALAPPDATA%\Temp\devspaces-*`, uploads into the pod, then deletes the temp directory. On some Windows hosts that cleanup can throw `ENOTEMPTY` / `EPERM` (antivirus or file handles) and the connector may treat the transfer as failed even if the upload succeeded. Workaround: delete `%LOCALAPPDATA%\Temp\devspaces-*` and retry. Prefer making the **pod** succeed via Artifactory so the Windows client path is not used.

## Checklist for the customer

1. Can workspace pods reach Artifactory on HTTPS?
2. Is the Generic remote pointed at `https://update.code.visualstudio.com` with redirect/CDN handling?
3. Have developers set `devspaces.rehDownloadUrl` to the Artifactory template?
4. Smoke-test: from a workspace terminal, `curl -I` the resolved URL for their VS Code commit.
5. Confirm the connector log shows download from the Artifactory host, not only from `update.code.visualstudio.com`.

## Related

- Connector setting reference: Dev Spaces Remote Connector README (`devspaces.rehDownloadUrl`)
- This chart’s CheCluster / ingress: [README](../../README.md#dev-spaces-ingress)
