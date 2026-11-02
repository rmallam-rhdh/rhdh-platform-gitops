# gateway-cert-lab: one listener and one certificate per hostname (lab-only)

Proves a shared Gateway API gateway can serve many hostnames **without a wildcard certificate**:
each hostname gets its own HTTPS listener, its own cert-manager `Certificate` (one DNS name, its own key)
and its own passthrough Route on the OpenShift Router. Everything is rendered from one list in
`values.yaml` (`hosts`, the "ingress catalogue"), so adding a hostname is a Git change, not a ticket.

```
client --SNI--> OpenShift Router --passthrough Route (SNI)--> shared gateway --listener + cert (SNI), TLS ends here
       --> HTTPRoute --> mesh (HBONE, STRICT mTLS) --> app pod
```

A self-signed CA in the gateway namespace stands in for the enterprise CA (for example a Venafi issuer).
Set `issuer.standIn: false` and point `issuer.name`/`issuer.kind` at a real issuer to use one.

## What it creates

| Object | Where | From |
|---|---|---|
| Namespace `gwcert-ingress` with `istio-discovery: enabled` | | always |
| Self-signed root, CA `Certificate` and `Issuer` `stand-in-ca` | `gwcert-ingress` | `issuer.standIn` |
| One `Certificate` per host (`<name>-gwcert`, Secret `<name>-gwcert-tls`) | `gwcert-ingress` | `hosts` |
| `Gateway` `shared-gw`, one HTTPS listener per host on 443 | `gwcert-ingress` | `hosts` |
| One passthrough `Route` per host to Service `shared-gw-istio` | `gwcert-ingress` | `hosts` |
| App namespace (ambient), `PeerAuthentication` STRICT, Deployment, Service, `HTTPRoute` | `<host.namespace>` | `hosts[].sampleApp` |
| `HTTPRoute` claiming another namespace's host | `gwcert-intruder` | `hijackTest.enabled` (on) |
| Listener whose certificate can never be issued | `gwcert-ingress` | `brokenHost.enabled` (off) |
| Second gateway `scale-gw` with `count` listeners and Certificates | `gwcert-ingress` | `scaleTest.enabled` (off) |

## Prerequisites

- OpenShift Service Mesh 3 in ambient mode (`charts/service-mesh`) and the `istio` GatewayClass.
- cert-manager Operator for Red Hat OpenShift: `argocd/apps-lab/cert-manager-operator.yaml`.
- `clusterBaseDomain` in `values-deploy.yaml` set to the cluster's `*.apps` domain.
- On your laptop for `tests/verify.sh`: `oc`, `curl`, `openssl`.

## Deploy (GitOps)

These are opt-in lab Applications under `argocd/apps-lab/`, so `idp-platform` does not sync them.
Register them once; from then on Argo CD follows `main`.

```bash
oc apply -f argocd/apps-lab/cert-manager-operator.yaml
oc get csv -n cert-manager-operator -w          # wait for cert-manager-operator ... Succeeded
oc apply -f argocd/apps-lab/gateway-cert-lab.yaml
oc get application gateway-cert-lab -n openshift-gitops -w   # wait for Synced / Healthy
```

## Verify

```bash
CONTEXT=<your oc context> charts/gateway-cert-lab/tests/verify.sh            # read-only checks 1-5, 7, 9
CONTEXT=<your oc context> charts/gateway-cert-lab/tests/verify.sh --renew --limit
```

| # | Check | Expected |
|---|---|---|
| 1 | Every listener | `Programmed` (a broken host shows `InvalidCertificateRef`) |
| 2 | Each host through the Router | HTTP 200; the certificate names only that host |
| 3 | Intruder `HTTPRoute` | `Accepted=False`, `NotAllowedByListeners` |
| 4 | No SNI / unknown SNI to the gateway | TLS handshake refused (no default certificate) |
| 5 | Gateway to app pod | ztunnel logs the gateway identity on port 15008 (HBONE) |
| 6 | `--renew` | new serial and new key within seconds; gateway pod not restarted; other host untouched |
| 7 | `brokenHost` on | only that host is down |
| 8 | `--limit` | 65 listeners rejected by the API, 64 accepted (dry run) |
| 9 | `scaleTest` on | all `count` listeners `Programmed`; gateway memory printed |

## Things to try

Each change below is a commit to `main` (or a branch, see the last tip). Argo CD syncs within about three minutes;
`oc annotate application gateway-cert-lab -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite` makes it look now.

1. **Add a hostname.** Append to `hosts` in `values.yaml`:
   ```yaml
     - name: cards
       namespace: gwcert-cards
       sampleApp: true
   ```
   Argo CD creates the namespace, the `Certificate`, the listener, the Route and the app. Then
   `curl --cacert <(oc get secret stand-in-ca -n gwcert-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d) https://cards-gwcert.<domain>/`.
2. **Remove a hostname.** Delete the entry. `prune: true` removes its listener, `Certificate`, Route and app. The TLS Secret stays behind (cert-manager does not own it by default); delete it by hand.
3. **Break one certificate.** Set `brokenHost.enabled: true`. The app shows Degraded, `oc get gateway shared-gw -n gwcert-ingress -o yaml`
   shows `InvalidCertificateRef` on that listener only, and `verify.sh` still passes for every other host.
4. **Try to steal a hostname.** Change `hijackTest.targetHost` to `payments`; the intruder route stays refused.
5. **Renew a certificate.** `verify.sh --renew`. Watch `oc get certificate -n gwcert-ingress -w`.
6. **Delete a Secret.** `oc delete secret orders-gwcert-tls -n gwcert-ingress`; cert-manager issues a fresh one and the gateway serves it.
7. **Drift.** `oc label ns gwcert-ingress istio-discovery-` and watch the gateway status: istiod stops managing it.
   Argo CD's self-heal puts the label back. Edit a listener by hand and Argo CD reverts that too.
8. **Many hostnames.** Set `scaleTest.enabled: true` (50 listeners), then `verify.sh`. Try `count: 65`: the sync fails with
   "must have at most 64 items", which is the Gateway API limit.
9. **A real issuer.** Create an `Issuer` in `gwcert-ingress` (for example a Venafi issuer), set `issuer.standIn: false` and
   `issuer.name` to it.
10. **Work on a branch.** `oc patch application gateway-cert-lab -n openshift-gitops --type merge -p '{"spec":{"source":{"targetRevision":"<branch>"}}}'`,
    then set it back to `main` when done.

## Remove

```bash
oc delete application gateway-cert-lab -n openshift-gitops        # then delete the gwcert-* namespaces if they remain
oc delete namespace gwcert-ingress gwcert-orders gwcert-payments gwcert-intruder --ignore-not-found
oc delete application cert-manager-operator -n openshift-gitops    # leaves the operator installed; remove its Subscription/CSV to uninstall
```
