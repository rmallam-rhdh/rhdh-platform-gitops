# Dev Spaces CheCluster image-override examples

Reference `CheCluster` snippets for pulling platform and workspace images from an
internal registry (Artifactory). **Not** rendered by this Helm chart — copy the
fields you need into `values-deploy.yaml` / a day-2 patch, or apply as a
documented overlay after reviewing tags against your Dev Spaces channel.

| File | Use when |
|------|----------|
| `checluster-container-registry.yaml` | Mirror keeps the same image names; only host/org change |
| `checluster-workspace-init-overrides.yaml` | You must pin full image URLs for project-clone / home init / components |
| `checluster-combined.yaml` | Registry rewrite plus explicit pins for leftover `ImagePullBackOff` inits |

Replace `artifactory.example.com`, `digi20/devspaces`, and `:3.30` with your
mirror path and operator-aligned tags (prefer digests in Non-Prod/Prod).

After changing CheCluster, stop/start workspaces so new init images are used.

```bash
# Confirm init images on a workspace pod
oc -n <user>-devspaces get pod \
  -l controller.devfile.io/devworkspace_name=<workspace> \
  -o jsonpath='{range .items[*].spec.initContainers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
```

UDI / tools images in **devfiles** are separate from these CheCluster fields —
point the tools component at your internal UDI tag.
