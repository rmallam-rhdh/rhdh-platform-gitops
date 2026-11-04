# mesh-netpol-lab

Lab-only chart that tests WNZL's istio-system NetworkPolicy and the per-namespace policy proposed for LLD section 3.4, in ambient mode, before they go to WNZL.

WNZL's service-mesh chart (`monorepo-gitops`, `apps/service-mesh/templates/network-policy.yaml`) installs `np-ingress-allow-sidecars` in istio-system. It admits ports 15010, 15012 and 443, but only from namespaces labelled `istio-discovery: enabled`. This chart renders that policy unchanged, plus the proposed fixes as values, so each case can be switched on in Git and checked.

## What it deploys

| Namespace | Labels | Contents |
| --- | --- | --- |
| `netpol-client` | `istio.io/dataplane-mode: ambient`, `istio-discovery: enabled` | curl client, pinned to `clientNode` |
| `netpol-server` | same (the discovery label can be switched off) | go-httpbin on 8080 behind Service port 8000, with a readiness probe; optional waypoint; optional NetworkPolicies |
| `netpol-outside` | none (not in the mesh) | curl pod used to probe istio-system ports |
| `istio-system` | (existing) | `np-ingress-allow-sidecars`, when enabled |

## Values

| Value | Meaning |
| --- | --- |
| `istioSystemPolicy.enabled` | Render WNZL's istio-system policy |
| `istioSystemPolicy.ztunnelSource` | `none` (WNZL's template unchanged), `sameNamespace` (`podSelector: {}`, for ztunnel in istio-system), `ztunnelNamespace` (ztunnel in its own namespace) |
| `istioSystemPolicy.allowWebhook` | Add a rule for istiod's webhook container port 15017 |
| `server.netpol` | `none`, `appOnly` (only port 8080), `appPlusHbone` (8080 plus `allow-mesh-hbone`: 15008 and 169.254.7.127) |
| `namespaces.serverDiscoveryLabel` | Put `istio-discovery: enabled` on `netpol-server` |
| `waypoint.enabled` | Waypoint in `netpol-server` |
| `ztunnelNamespace` | Where ztunnel runs (lab: `ztunnel`) |

The run settings live in `values-deploy.yaml`. Each test step is one commit to it on the test branch.

## Registering

```
oc apply -f argocd/apps-lab/mesh-netpol-lab.yaml
```

## Cleaning up

Delete the Application (`prune` removes the namespaces and the istio-system policy):

```
oc delete application mesh-netpol-lab -n openshift-gitops
```
