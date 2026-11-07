# Dev Spaces CheCluster hardening

Day-2 defaults in this chart. Applied via Argo CD `devspaces` app.

| Practice | Setting | Why |
|----------|---------|-----|
| No workspace image builds | `disableContainerBuildCapabilities: true` | Digi policy: builds belong in CI, not UDI. Also unlocks restricted `security.containerSecurityContext`. |
| No nested runtimes | `disableContainerRunCapabilities: true` | No Podman/Docker-in-workspace. |
| Drop privileges | `security.containerSecurityContext` (`drop: ALL`, no privilege escalation) | Only honoured when **both** disable*Capabilities are true. |
| etcd / CA mount | `trustedCerts.disableWorkspaceCaBundleMount: true` | Stops copying the large `ca-certs-merged` bundle into every user namespace under `/etc/pki/...`. |
| Corp Git TLS (optional) | `gitTrustedCertsConfigMapName` + `examples/che-git-custom-cert.yaml` | After disabling the full CA mount, provide only needed CAs; mount stays at `/public-certs`. |
| Resource defaults + caps | `defaultContainerResources` / `containerResourceCaps` | Defaults when Devfile omits size; ceiling when Devfile asks for more (capped, not rejected). Mirrored on **global** DWOC for enforcement. |
| Concurrency | max workspaces / running per user + per cluster | Protects shared Non-Prod nodes. |
| Fail fast | `ignoredUnrecoverableEvents: []` | Do not ignore `FailedScheduling` (avoids 5m silent waits). |
| Pull policy | `imagePullPolicy: IfNotPresent` | Prefer node cache / internal mirror. |
| Embedded OpenVSX | `pluginRegistry.openVSXURL: ""` | No public open-vsx.org; use image-embedded or later a private registry URL. |
| Image puller off | `imagePuller.enable: false` | Community puller only if ops explicitly pre-warms nodes. |
| NetworkPolicy | `networking.networkPolicy: true` | CheCluster-managed isolation for user namespaces. |
| Idle + cleanup | idle 30m + global DWOC `cleanupCronJob` | Stop idle workspaces; prune abandoned CRs/PVCs. |

## Certs and etcd

Default Dev Spaces behaviour mounts a merged CA ConfigMap into **every** `<user>-devspaces` namespace. At scale that inflates etcd.

This chart sets `disableWorkspaceCaBundleMount: true`. If Bitbucket / Artifactory use private PKI:

1. Fill and apply `examples/che-git-custom-cert.yaml`.
2. Set `cheCluster.trustedCerts.gitTrustedCertsConfigMapName: che-git-custom-cert` in `values-deploy.yaml`.
3. Restart workspaces after CA rotation.

## Builds

`containerBuildConfiguration` is **not** rendered while builds are disabled. Re-enable only by flipping both:

```yaml
cheCluster:
  disableContainerBuildCapabilities: false
  containerBuildScc: container-build
```

That widens the workspace SecurityContext (SETUID/SETGID) — treat as an explicit exception.
