```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: IstioCSR
spec:
  istioCSRConfig:
    certManager:
      issuerRef:
        name: venafi-mesh          # that is all
        kind: ClusterIssuer
        group: cert-manager.io     # CRD requires this
```


```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: venafi-mesh
  annotations:
    venafi.cert-manager.io/custom-fields: |-
      [
        {"name": "Environment", "value": "NonProd"},
        {"name": "Application", "value": "ServiceMesh"}
      ]
spec:
  venafi:
    zone: \VED\Policy\OpenShift\Mesh
    tpp:
      url: https://tpp.example.com
      credentialsRef:
        name: venafi-tpp-creds
````
