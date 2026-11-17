# Enterprise TLS for CloudNativePG & Red Hat Developer Hub (RHDH)

This guide documents the **leaf-certificate-only + public CA bundle** TLS architecture for **CloudNativePG (CNPG)** and **Red Hat Developer Hub (RHDH)** when using an enterprise PKI issuer (such as **Venafi** via `cert-manager` `ClusterIssuer`) where:

1. Application namespaces **cannot** hold a Subordinate/Issuing CA private key (`isCA: false` leaf certificates only).
2. **CloudNativePG** uses leaf certificates issued by `cert-manager` (`serverTLSSecret` + `replicationTLSSecret`) and a public-only CA chain (`serverCASecret` + `clientCASecret`).
3. **RHDH (`node-postgres` / `pg`)** receives **only** the public CA bundle (`ca.crt`) via `NODE_EXTRA_CA_CERTS` and authenticates with SCRAM-SHA-256 username/password over strict TLS (`ssl.rejectUnauthorized: true`) — **no client certificate, no server certificate, and no private keys** are mounted into RHDH.

---

## 1. Architecture Summary

```text
+-------------------------------------------------------------------------+
| cert-manager Namespace (Platform / PKI Admin Owned)                     |
|   ClusterIssuer (e.g. Venafi / Enterprise Issuing CA)                   |
|   * Holds CA/Venafi credentials — NEVER exposed to app namespaces       |
+------------------------------------+------------------------------------+
                                     | Issues leaf certs (isCA: false)
                                     v
+-------------------------------------------------------------------------+
| Application Namespace (e.g. rhdh / rhdh-cnpg-tls-test)                  |
|                                                                         |
|  1) Secret: cnpg-server-tls        (tls.crt, tls.key, ca.crt)           |
|     - Leaf cert (server auth) + 12 Service DNS SANs                     |
|     - Mounted ONLY by CloudNativePG pods                                |
|                                                                         |
|  2) Secret: cnpg-replication-tls   (tls.crt, tls.key, ca.crt)           |
|     - Leaf cert (client auth, CN=streaming_replica)                     |
|     - Mounted ONLY by CloudNativePG pods for primary <-> standby WAL    |
|                                                                         |
|  3) Secret: enterprise-ca-chain    (ca.crt ONLY — Root + Intermediate)  |
|     - Public certificates ONLY (zero private keys)                      |
|     - Referenced by CNPG (serverCASecret + clientCASecret)              |
|     - Mounted read-only into RHDH via NODE_EXTRA_CA_CERTS               |
|                                                                         |
|  4) Secret: <cluster>-app          (CNPG-generated DB credentials)      |
|     - host, port, username, password, dbname                            |
|     - Used by RHDH for SCRAM-SHA-256 password auth over TLS 1.3         |
+-------------------------------------------------------------------------+
```

---

## 2. Certificate & SAN Requirements (`cert-manager`)

### 2.1 PostgreSQL Server Leaf Certificate (`cnpg-server-cert`)

When RHDH (or any strict TLS client with `rejectUnauthorized: true`) connects to a CloudNativePG service, Node.js (`tls.checkServerIdentity`) validates the hostname in the connection string against the server certificate's **Subject Alternative Names (`dnsNames`)** — **not** `commonName` alone.

For a CNPG `Cluster` named `<cluster>` (for example `backstage-psql`) in namespace `<namespace>` (for example `rhdh-cnpg-tls-test`), CNPG creates three Kubernetes Services:
- `<cluster>-rw` (read-write primary — used by RHDH)
- `<cluster>-ro` (read-only replicas)
- `<cluster>-r` (any ready instance)

Include all **4 Kubernetes DNS forms** across all **3 services** (**12 SANs total**), plus label `cnpg.io/reload: "true"` on the generated Secret so CNPG reloads rotated certificates automatically without pod restarts:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cnpg-server-cert
  namespace: rhdh-cnpg-tls-test
spec:
  secretName: cnpg-server-tls
  secretTemplate:
    labels:
      cnpg.io/reload: "true"
  isCA: false
  duration: 2160h    # 90d
  renewBefore: 360h  # 15d
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - key encipherment
    - server auth
  commonName: backstage-psql-rw
  dnsNames:
    # Primary read-write service (-rw)
    - backstage-psql-rw
    - backstage-psql-rw.rhdh-cnpg-tls-test
    - backstage-psql-rw.rhdh-cnpg-tls-test.svc
    - backstage-psql-rw.rhdh-cnpg-tls-test.svc.cluster.local
    # Read-only replica service (-ro)
    - backstage-psql-ro
    - backstage-psql-ro.rhdh-cnpg-tls-test
    - backstage-psql-ro.rhdh-cnpg-tls-test.svc
    - backstage-psql-ro.rhdh-cnpg-tls-test.svc.cluster.local
    # Any-instance read service (-r)
    - backstage-psql-r
    - backstage-psql-r.rhdh-cnpg-tls-test
    - backstage-psql-r.rhdh-cnpg-tls-test.svc
    - backstage-psql-r.rhdh-cnpg-tls-test.svc.cluster.local
  issuerRef:
    name: simulated-venafi-issuer   # Replace with enterprise Venafi ClusterIssuer
    kind: ClusterIssuer
    group: cert-manager.io
```

> **Note:** Connecting by raw Pod IP or Service `ClusterIP` will fail with `ERR_TLS_CERT_ALTNAME_INVALID` unless `ipAddresses` are explicitly added (which is discouraged because `ClusterIP`s are dynamic). Always connect via the `-rw` / `-ro` / `-r` DNS names above (CNPG's `<cluster>-app` Secret sets `host` to `<cluster>-rw` and `fqdn-uri` to `<cluster>-rw.<namespace>.svc.cluster.local`).

---

### 2.2 PostgreSQL Streaming Replication Leaf Certificate (`cnpg-replication-cert`)

CloudNativePG requires a `client auth` certificate for streaming replication between standby pods and the primary pod (`streaming_replica` user). It is **never** mounted into RHDH.

- **Standard CN:** If your PKI policy allows bare service usernames in `commonName`, set `commonName: streaming_replica`.
- **Enterprise Domain Policy CN:** If your Venafi policy requires a corporate domain suffix on `commonName` (e.g. `streaming-replica.corp.example.com`), map that CN to PostgreSQL user `streaming_replica` using CNPG's built-in `cnpg_streaming_replica` map in `spec.postgresql.pg_ident` (shown in Section 3).

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cnpg-replication-cert
  namespace: rhdh-cnpg-tls-test
spec:
  secretName: cnpg-replication-tls
  secretTemplate:
    labels:
      cnpg.io/reload: "true"
  isCA: false
  duration: 2160h
  renewBefore: 360h
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - key encipherment
    - client auth
  # Use "streaming_replica", OR a policy-compliant FQDN mapped via pg_ident:
  commonName: streaming_replica
  issuerRef:
    name: simulated-venafi-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

---

### 2.3 Public CA Bundle (`enterprise-ca-chain`)

Create a `Secret` (or `ConfigMap` synced via [`trust-manager`](https://cert-manager.io/docs/trust/trust-manager/) / GitOps job) containing **only** key `ca.crt` with the **full public CA chain (`Intermediate Issuing CA + Root CA`)** — no `tls.crt`, no `tls.key`, no `ca.key`:

```yaml
# Structure only — populate ca.crt via trust-manager Bundle, ExternalSecret, or sync Job
apiVersion: v1
kind: Secret
metadata:
  name: enterprise-ca-chain
  namespace: rhdh-cnpg-tls-test
  labels:
    cnpg.io/reload: "true"
type: Opaque
data:
  ca.crt: <base64-encoded PEM containing Intermediate CA + Root CA public certs>
```

> **Why include both Intermediate + Root in `ca.crt`?**
> In a 2-tier enterprise PKI, `cert-manager` writes `[Leaf, Intermediate]` into a leaf secret's `tls.crt` and only `[Root]` into `ca.crt`. Including **both** `[Intermediate, Root]` in `enterprise-ca-chain`'s `ca.crt` guarantees that both PostgreSQL (`ssl_ca_file`) and Node.js (`NODE_EXTRA_CA_CERTS`) can verify the chain even if a peer sends only its leaf certificate.

---

## 3. PostgreSQL Side: CloudNativePG `Cluster` Configuration

Configure `spec.certificates` on the CNPG `Cluster` to reference the two leaf secrets and the public `enterprise-ca-chain` secret, and grant `createdb: true` to `app` when RHDH uses `pluginDivisionMode: database` (where RHDH creates `backstage_plugin_*` databases on startup):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: backstage-psql
  namespace: rhdh-cnpg-tls-test
spec:
  instances: 2
  storage:
    size: 5Gi

  # Leaf certs + public CA chain ONLY (no CA private key anywhere in namespace)
  certificates:
    serverTLSSecret: cnpg-server-tls
    replicationTLSSecret: cnpg-replication-tls
    serverCASecret: enterprise-ca-chain
    clientCASecret: enterprise-ca-chain

  # Required so RHDH (`app` user) can create `backstage_plugin_*` databases
  managed:
    roles:
      - name: app
        ensure: present
        login: true
        inherit: true
        createdb: true
        connectionLimit: -1

  postgresql:
    parameters:
      max_connections: "200"
    # Optional: only needed if Venafi enforces a domain-qualified CN on cnpg-replication-cert
    pg_ident:
      - "cnpg_streaming_replica streaming-replica.corp.example.com streaming_replica"
```

### How CNPG Configures `pg_hba.conf` Under the Hood
With the spec above, CNPG automatically generates the following `pg_hba.conf` rules:
- `hostssl replication streaming_replica all cert map=cnpg_streaming_replica` (mTLS leaf client cert required **only** for replication)
- `host all all all scram-sha-256` (application users like `app` authenticate via `scram-sha-256` password over TLS — **no client certificate required from RHDH**).

> **Istio Ambient Mesh Note:** Ensure the namespace running CNPG carries label `istio.io/dataplane-mode: none` so `ztunnel` does not intercept kubelet HTTP health probes to CNPG port `8000`.

---

## 4. RHDH Side: Sample `Backstage` CR & `app-config.yaml`

RHDH only needs:
1. **`NODE_EXTRA_CA_CERTS=/etc/pki/ca-trust/ca.crt`** pointing to the mounted `ca.crt` key from `enterprise-ca-chain`.
2. **`NODE_TLS_REJECT_UNAUTHORIZED` omitted** (do **not** set `NODE_TLS_REJECT_UNAUTHORIZED="0"`, or Node.js will bypass TLS verification globally).
3. **Database credentials** (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) from CNPG's auto-generated `backstage-psql-app` Secret.
4. **`ssl.rejectUnauthorized: true`** in `app-config.yaml` (no `ssl.ca`, `ssl.cert`, or `ssl.key` needed in `app-config.yaml` because `node-postgres` uses Node's `NODE_EXTRA_CA_CERTS` trust store automatically).

### 4.1 Sample `app-config.yaml` (`ConfigMap/app-config-rhdh`)

```yaml
backend:
  database:
    client: pg
    pluginDivisionMode: database
    connection:
      host: ${POSTGRES_HOST}          # resolves to "backstage-psql-rw"
      port: ${POSTGRES_PORT}          # resolves to "5432"
      user: ${POSTGRES_USER}          # resolves to "app"
      password: ${POSTGRES_PASSWORD}  # SCRAM-SHA-256 password from backstage-psql-app
      database: ${POSTGRES_DB}        # resolves to "app"
      ssl:
        rejectUnauthorized: true
```

### 4.2 Sample `Backstage` Custom Resource (`rhdh.redhat.com/v1alpha5`)

```yaml
apiVersion: rhdh.redhat.com/v1alpha5
kind: Backstage
metadata:
  name: developer-hub-tls
  namespace: rhdh-cnpg-tls-test
spec:
  database:
    enableLocalDb: false
  application:
    appConfig:
      mountPath: /opt/app-root/src
      configMaps:
        - name: app-config-rhdh
    extraEnvs:
      envs:
        - name: NODE_EXTRA_CA_CERTS
          value: /etc/pki/ca-trust/ca.crt
      secrets:
        - name: rhdh-cnpg-tls-secrets
    route:
      enabled: true
  deployment:
    patch:
      spec:
        replicas: 1
        template:
          spec:
            containers:
              - name: backstage-backend
                env:
                  - name: POSTGRES_HOST
                    valueFrom:
                      secretKeyRef:
                        name: backstage-psql-app
                        key: host
                  - name: POSTGRES_PORT
                    valueFrom:
                      secretKeyRef:
                        name: backstage-psql-app
                        key: port
                  - name: POSTGRES_USER
                    valueFrom:
                      secretKeyRef:
                        name: backstage-psql-app
                        key: username
                  - name: POSTGRES_PASSWORD
                    valueFrom:
                      secretKeyRef:
                        name: backstage-psql-app
                        key: password
                  - name: POSTGRES_DB
                    valueFrom:
                      secretKeyRef:
                        name: backstage-psql-app
                        key: dbname
                volumeMounts:
                  - name: enterprise-ca-chain
                    mountPath: /etc/pki/ca-trust/ca.crt
                    subPath: ca.crt
                    readOnly: true
            volumes:
              - name: enterprise-ca-chain
                secret:
                  secretName: enterprise-ca-chain
                  defaultMode: 0444
                  items:
                    - key: ca.crt
                      path: ca.crt
```

---

## 5. Helm Overlay Files in This Repository

| Component | Chart & Overlay Values | Argo CD Application |
| :--- | :--- | :--- |
| Simulated 2-Tier Venafi PKI Lab | [`charts/venafi-pki-lab/`](../venafi-pki-lab) | [`argocd/apps-lab/venafi-pki-lab.yaml`](../../argocd/apps-lab/venafi-pki-lab.yaml) |
| CNPG Leaf-Cert + Public CA Cluster | `charts/cnpg` + [`values-venafi-tls-lab.yaml`](values-venafi-tls-lab.yaml) | [`argocd/apps-lab/cnpg-venafi-tls.yaml`](../../argocd/apps-lab/cnpg-venafi-tls.yaml) |
| RHDH Strict TLS (`NODE_EXTRA_CA_CERTS`) | `charts/developer-hub` + [`values-cnpg-tls-lab.yaml`](../developer-hub/values-cnpg-tls-lab.yaml) | [`argocd/apps-lab/developer-hub-cnpg-tls.yaml`](../../argocd/apps-lab/developer-hub-cnpg-tls.yaml) |
| Runtime Secret Template (Never in Git) | [`examples/rhdh-cnpg-tls-secrets.example.yaml`](../../examples/rhdh-cnpg-tls-secrets.example.yaml) | Pre-created out-of-band / via ESO |

---

## 6. Verification Commands

```bash
# 1. Verify leaf certificates are Ready and CA:FALSE
oc get certificate -n rhdh-cnpg-tls-test
oc get secret cnpg-server-tls -n rhdh-cnpg-tls-test -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -ext basicConstraints,extendedKeyUsage,subjectAltName

# 2. Verify enterprise-ca-chain has ONLY ca.crt (no private keys)
oc get secret enterprise-ca-chain -n rhdh-cnpg-tls-test -o jsonpath='{.data}' | jq 'keys'

# 3. Verify RHDH created backstage_plugin_* databases and connects over TLSv1.3 without a client cert
PRIMARY=$(oc get cluster.postgresql.cnpg.io backstage-psql -n rhdh-cnpg-tls-test -o jsonpath='{.status.currentPrimary}')
oc exec -n rhdh-cnpg-tls-test "$PRIMARY" -c postgres -- psql -U postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE 'backstage_plugin_%' ORDER BY datname;"

oc exec -n rhdh-cnpg-tls-test "$PRIMARY" -c postgres -- psql -U postgres -c \
  "SELECT a.usename, a.datname, s.ssl, s.version, s.cipher, COALESCE(s.client_dn, '<NONE - password auth only>') AS client_cert
   FROM pg_stat_activity a JOIN pg_stat_ssl s ON a.pid = s.pid
   WHERE a.usename IN ('app', 'streaming_replica') ORDER BY a.usename, a.datname LIMIT 15;"
```
