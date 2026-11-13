# Lab-only Argo Applications (opt-in)

These Applications are **not** under `argocd/apps/` so the default `idp-platform` app-of-apps will not auto-sync them.

They prove an **unsupported** Kerberos Negotiate sidecar spike for Hub. Prefer customer Basic proxy auth for supported deployments.

```bash
# After images are built and (optionally) keytab sync Job has run:
oc apply -f argocd/apps-lab/kerberos-lab.yaml
oc apply -f argocd/apps-lab/developer-hub-kerberos.yaml
```

Set `spec.source.targetRevision` to the branch or tag that contains this spike before applying.
See `charts/kerberos-lab/SIDECAR.md`.

## Per-host certificates on a shared gateway

`gateway-cert-lab` proves one HTTPS listener and one cert-manager `Certificate` per hostname on a shared Gateway API gateway,
with no wildcard certificate. It needs the cert-manager Operator, which `cert-manager-operator` installs (lab-only exception to
"no operators in this repo"; move it to the day-1 repo when adopted).

```bash
oc apply -f argocd/apps-lab/cert-manager-operator.yaml
oc apply -f argocd/apps-lab/gateway-cert-lab.yaml
```

See `charts/gateway-cert-lab/README.md`.
