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
