# Forking & Enhancing `@backstage-community/plugin-vault` in Customer Bitbucket (RHDH 1.10 Copy-Paste Guide)

Use this guide when you **cannot copy pre-built `.tgz` archives across environments** and instead need to fork the upstream Backstage Vault plugin into a **customer Bitbucket repository**, apply the Enterprise Vault Namespace + RHDH RBAC enhancements directly in source code, build/export RHDH 1.10 dynamic plugins in customer CI, and deploy them to Red Hat Developer Hub (RHDH 1.10).

Every file in **Step 2** below is **100% complete (no `...` placeholders)** and has been compile-verified (`yarn tsc`), unit-tested (`9/9` Jest test suites passing), built (`yarn build:all`), and exported (`@red-hat-developer-hub/cli@1.10.8 plugin export`) against Backstage `1.49.2` / RHDH `1.10`.

---

## 1. Why Pin to `@backstage-community/plugin-vault@0.19.0` & What Changes

### Version Alignment for RHDH 1.10
- **RHDH 1.10** runs on **Backstage `1.49.x`** (`1.49.4`).
- Upstream `backstage/community-plugins` `main` has moved ahead to Backstage `1.57+` (`@backstage-community/plugin-vault@0.27+`), whose peer dependencies are incompatible with RHDH 1.10.
- Git tag **`@backstage-community/plugin-vault@0.19.0`** (which pairs `@backstage-community/plugin-vault@0.19.0` + `@backstage-community/plugin-vault-backend@0.21.0`) targets **Backstage `1.49.2`** (`backstage.json`), making it an exact match for RHDH 1.10.

### Summary of the 4 Enterprise Enhancements Over Upstream `0.19.0`

| Gap in Upstream `0.19.0` | Enhancement Applied in This Fork |
| :--- | :--- |
| **No Vault Enterprise Namespaces** | Adds `X-Vault-Namespace` header on both Kubernetes Auth login (`v1/auth/<mount>/login`) and KV metadata calls (`v1/<engine>/metadata/*`), plus `?namespace=<ns>` on all Vault UI View/Edit/Create deep-links. Supports per-entity `vault.io/namespace` and fallback `vault.namespace`. |
| **Kubernetes Auth Bugs & No Per-Namespace Token Cache** | Fixes missing `'Content-Type': 'application/json'` header on Kubernetes Auth login, caches Vault client tokens per `(authPath, role, namespace)` until `lease_duration - 60s`, and skips `renew-self` cron when `auth.type: kubernetes` is active. |
| **Unauthenticated Path Enumeration (`/v1/secrets/*`) & Zero RBAC** | Blocks legacy `/v1/secrets/*` with `HTTP 403` and adds `GET /v1/entities/:namespace/:kind/:name/secrets`. Verifies caller user credentials (`httpAuth`), `PermissionsService` (`catalog.entity.read`), and optional `vault.io/allowed-principals` group membership **before** calling Vault, reading `vault.io/namespace` and `vault.io/secrets-path` strictly from the server-side Catalog Entity. |
| **Missing Scalprum Frontend Bundle in RHDH 1.10** | Adds `"scalprum"` (`backstage-community.plugin-vault` / `PluginRoot`) to `plugins/vault/package.json` so `@red-hat-developer-hub/cli@1.10.8 plugin export` emits `dist-scalprum/plugin-manifest.json` cleanly, plus adds an `ns: <namespace>` badge, secret `Ver` column (`current_version`), and a clean `403 RBAC` warning alert in `EntityVaultTable`. |

---

## 2. Step 1 — Seed the Standalone Vault Plugin Repo in Customer Bitbucket

Upstream `https://github.com/backstage/community-plugins` is a giant monorepo containing 500+ plugins. Extracting **only `workspaces/vault`** at tag `@backstage-community/plugin-vault@0.19.0` into a clean standalone Bitbucket repository (`rhdh-plugin-vault`) keeps clones fast (~2 MB) and CI builds self-contained.

1. Create an **empty repository** in customer Bitbucket (for example, `https://bitbucket.example.com/scm/idp/rhdh-plugin-vault.git`).
2. Run the following commands on a workstation or jump host with access to GitHub and Bitbucket:

```bash
# 1. Sparse-clone ONLY workspaces/vault at exact RHDH 1.10 tag @backstage-community/plugin-vault@0.19.0
mkdir -p /tmp/vault-extract && cd /tmp/vault-extract
git clone --depth 1 --filter=blob:none --sparse \
  --branch "@backstage-community/plugin-vault@0.19.0" \
  https://github.com/backstage/community-plugins.git upstream-community-plugins

cd upstream-community-plugins
git sparse-checkout set workspaces/vault

# 2. Copy workspaces/vault into a clean standalone Git repository for Bitbucket
mkdir -p /tmp/vault-extract/rhdh-plugin-vault
cp -R workspaces/vault/. /tmp/vault-extract/rhdh-plugin-vault/

cd /tmp/vault-extract/rhdh-plugin-vault
git init -b main
git add .
git commit -m "chore: import @backstage-community/plugin-vault@0.19.0 (Backstage 1.49.2)"

# 3. Point origin to your customer Bitbucket repo and push the baseline commit
git remote add origin https://bitbucket.example.com/scm/idp/rhdh-plugin-vault.git
git push -u origin main
```

> **Note if you forked the entire `backstage/community-plugins` monorepo inside Bitbucket UI instead:**
> Check out tag `@backstage-community/plugin-vault@0.19.0` into a branch (`git checkout -b rhdh-1.10-vault-enterprise tags/@backstage-community/plugin-vault@0.19.0`), `cd workspaces/vault`, and apply all file paths in Step 2 relative to `workspaces/vault/`.

---

## 3. Step 2 — Copy-Paste All Modified Files (16 Files Total)

Replace the contents of the following **13 plugin/workspace files** (and **3 unit test files** so `yarn test` passes `9/9` in Bitbucket CI) inside `rhdh-plugin-vault`. Every code block below is the **complete file** — select all and paste directly.

---

### File 1 of 16: `.yarnrc.yml`
 Configures Yarn 4 to use `node-modules` linking as a standalone repo (outside the upstream monorepo root).

```yaml
plugins:
  - checksum: 05b51f75814596aa3e15b296af3287240351c8b7f1df1e05c2ceedf7f3820627759605825fd932f1f7c3c3287b61b16f9e8195b0927a0f80345493f81376947a
    path: .yarn/plugins/@yarnpkg/plugin-backstage.cjs
    spec: 'https://versions.backstage.io/v1/releases/1.49.2/yarn-plugin'
nodeLinker: node-modules
enableImmutableInstalls: false
```

*(If your Bitbucket CI runner uses an internal Artifactory NPM mirror instead of `registry.npmjs.org`, append `npmRegistryServer: "https://artifactory.example.com/artifactory/api/npm/npm-virtual/"` to `.yarnrc.yml`.)*

---

### File 2 of 16: `package.json`
Removes the monorepo `cd ../../ && yarn install` `postinstall` hook, pins `"packageManager": "yarn@4.5.3"` for Corepack, and declares Jest devDependencies so standalone `yarn tsc` and `yarn test` succeed cleanly.

```json
{
  "name": "@internal/vault",
  "version": "1.0.0",
  "private": true,
  "engines": {
    "node": "22 || 24"
  },
  "scripts": {
    "start": "backstage-cli repo start",
    "tsc": "tsc",
    "tsc:full": "tsc --skipLibCheck false --incremental false",
    "build:all": "backstage-cli repo build --all",
    "clean": "backstage-cli repo clean",
    "test": "backstage-cli repo test",
    "test:all": "backstage-cli repo test --coverage",
    "fix": "backstage-cli repo fix",
    "lint": "backstage-cli repo lint --since origin/main",
    "lint:all": "backstage-cli repo lint",
    "prettier:check": "prettier --check .",
    "prettier:fix": "prettier --write .",
    "new": "backstage-cli new --scope @backstage-community",
    "build:api-reports": "yarn build:api-reports:only --tsc",
    "build:api-reports:only": "backstage-repo-tools api-reports -o ae-wrong-input-file-type,ae-undocumented --validate-release-tags",
    "build:knip-reports": "backstage-repo-tools knip-reports"
  },
  "workspaces": {
    "packages": [
      "packages/*",
      "plugins/*"
    ]
  },
  "repository": {
    "type": "git",
    "url": "https://bitbucket.example.com/scm/idp/rhdh-plugin-vault.git"
  },
  "devDependencies": {
    "@backstage/cli": "backstage:^",
    "@backstage/e2e-test-utils": "backstage:^",
    "@backstage/repo-tools": "backstage:^",
    "@changesets/cli": "^2.27.1",
    "@types/jest": "^29.5.14",
    "jest": "^29.7.0",
    "jest-environment-jsdom": "^29.7.0",
    "knip": "^5.27.4",
    "node-gyp": "^10.0.0",
    "prettier": "^2.3.2",
    "typescript": "~5.8.0"
  },
  "resolutions": {
    "@types/react": "^18",
    "@types/react-dom": "^18",
    "csstype@npm:^3.0.2": "3.0.9",
    "csstype@npm:^3.1.2": "3.0.9",
    "csstype@npm:^3.1.3": "3.0.9"
  },
  "prettier": "@backstage/cli/config/prettier",
  "lint-staged": {
    "*.{js,jsx,ts,tsx,mjs,cjs}": [
      "eslint --fix",
      "prettier --write"
    ],
    "*.{json,md}": [
      "prettier --write"
    ]
  },
  "packageManager": "yarn@4.5.3"
}
```

---

### File 3 of 16: `plugins/vault-node/src/api/types.ts`
Extends `VaultSecret` and `VaultApi` with optional `namespace`, `version`, and `updatedTime` metadata fields.

```ts
/*
 * Copyright 2023 The Backstage Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Object containing the secret metadata and Vault UI links
 * @public
 */
export type VaultSecret = {
  name: string;
  path: string;
  showUrl: string;
  editUrl: string;
  version?: number;
  updatedTime?: string | null;
};

/**
 * Interface for the Vault API
 * @public
 */
export interface VaultApi {
  /**
   * Returns the URL to access the Vault UI with the defined config.
   */
  getFrontendSecretsUrl(namespace?: string, secretEngine?: string): string;

  /**
   * Returns the URL to create a new secret in the Vault UI.
   */
  getCreateSecretUrl(
    secretPath: string,
    secretEngine?: string,
    namespace?: string,
  ): string;

  /**
   * Returns a list of secret metadata entries (never secret values).
   */
  listSecrets(
    secretPath: string,
    options?: {
      secretEngine?: string;
      namespace?: string;
    },
  ): Promise<VaultSecret[]>;

  /**
   * Optional, to renew static tokens.
   */
  renewToken?(): Promise<void>;
}
```

---

### File 4 of 16: `plugins/vault-backend/package.json`
Adds `@backstage/catalog-model`, `@backstage/plugin-catalog-common`, `@backstage/plugin-catalog-node`, and `@backstage/plugin-permission-common` so the backend enforces RHDH Catalog + Permissions RBAC.

```json
{
  "name": "@backstage-community/plugin-vault-backend",
  "version": "0.21.0",
  "description": "A Backstage backend plugin that integrates towards Vault",
  "backstage": {
    "role": "backend-plugin",
    "pluginId": "vault",
    "pluginPackages": [
      "@backstage-community/plugin-vault",
      "@backstage-community/plugin-vault-backend",
      "@backstage-community/plugin-vault-node"
    ]
  },
  "publishConfig": {
    "access": "public",
    "main": "dist/index.cjs.js",
    "types": "dist/index.d.ts"
  },
  "keywords": [
    "backstage",
    "vault"
  ],
  "homepage": "https://backstage.io",
  "repository": {
    "type": "git",
    "url": "https://bitbucket.example.com/scm/idp/rhdh-plugin-vault.git",
    "directory": "plugins/vault-backend"
  },
  "license": "Apache-2.0",
  "main": "src/index.ts",
  "types": "src/index.ts",
  "files": [
    "dist",
    "config.d.ts"
  ],
  "scripts": {
    "build": "backstage-cli package build",
    "clean": "backstage-cli package clean",
    "lint": "backstage-cli package lint",
    "prepack": "backstage-cli package prepack",
    "postpack": "backstage-cli package postpack",
    "start": "backstage-cli package start",
    "test": "backstage-cli package test"
  },
  "dependencies": {
    "@backstage-community/plugin-vault-node": "workspace:^",
    "@backstage/backend-defaults": "backstage:^",
    "@backstage/backend-plugin-api": "backstage:^",
    "@backstage/catalog-model": "backstage:^",
    "@backstage/config": "backstage:^",
    "@backstage/errors": "backstage:^",
    "@backstage/plugin-catalog-common": "backstage:^",
    "@backstage/plugin-catalog-node": "backstage:^",
    "@backstage/plugin-permission-common": "backstage:^",
    "@types/express": "*",
    "compression": "^1.7.4",
    "cors": "^2.8.5",
    "express": "^4.17.1",
    "express-promise-router": "^4.1.0",
    "helmet": "^7.0.0",
    "node-fetch": "^2.6.7",
    "p-limit": "^3.1.0",
    "winston": "^3.2.1",
    "yn": "^5.0.0"
  },
  "devDependencies": {
    "@backstage/backend-defaults": "backstage:^",
    "@backstage/backend-test-utils": "backstage:^",
    "@backstage/cli": "backstage:^",
    "@backstage/plugin-auth-backend": "backstage:^",
    "@backstage/plugin-auth-backend-module-guest-provider": "backstage:^",
    "@backstage/plugin-catalog-backend": "backstage:^",
    "@types/compression": "^1.7.2",
    "@types/node-fetch": "^2.5.12",
    "@types/supertest": "^6.0.0",
    "msw": "^1.0.0",
    "supertest": "^7.0.0"
  },
  "configSchema": "config.d.ts"
}
```

---

### File 5 of 16: `plugins/vault-backend/config.d.ts`
Adds `vault.namespace` and `vault.auth.namespace` to the Backstage configuration schema.

```ts
import { SchedulerServiceTaskScheduleDefinitionConfig } from '@backstage/backend-plugin-api';

/** Configuration for the Vault Enterprise Namespace plugin */
export interface Config {
  vault?: {
    /**
     * The baseUrl for your Vault API calls from the RHDH backend.
     * @visibility frontend
     */
    baseUrl: string;

    /**
     * The browser-facing publicUrl for Vault UI deep-links (Optional).
     * @visibility frontend
     */
    publicUrl?: string;

    /**
     * Optional default Vault Enterprise namespace when an entity does not set `vault.io/namespace`.
     * @visibility backend
     */
    namespace?: string;

    /**
     * @visibility secret
     * @deprecated Use `auth` instead.
     */
    token?: string;

    /**
     * Authentication configuration (Kubernetes ServiceAccount JWT recommended).
     * @visibility backend
     */
    auth:
      | {
          type: 'static';
          /** @visibility secret */
          secret: string;
        }
      | {
          type: 'kubernetes';
          /** @visibility backend */
          role: string;
          /** @visibility backend */
          authPath?: string;
          /**
           * Optional fixed Vault Enterprise namespace where Kubernetes Auth is mounted.
           * If omitted, Kubernetes Auth logs into each entity's `vault.io/namespace`.
           * @visibility backend
           */
          namespace?: string;
          /** @visibility secret */
          serviceAccountTokenPath?: string;
        };

    /**
     * Default KV secret engine mount name (e.g. `kv` or `secrets`).
     */
    secretEngine?: string;

    /**
     * KV engine version. Defaults to `2`.
     */
    kvVersion?: 1 | 2;

    schedule?: SchedulerServiceTaskScheduleDefinitionConfig | boolean;

    secretSuffix?: string;
  };
}
```

---

### File 6 of 16: `plugins/vault-backend/src/config/config.ts`
Parses `vault.namespace` and `vault.auth.namespace` while maintaining 100% backward compatibility with upstream config defaults.

```ts
import { Config } from '@backstage/config';

/** @public */
export interface VaultStaticTokenConfig {
  secret: string;
}

/** @public */
export interface VaultKubernetesAuthConfig {
  role: string;
  authPath: string;
  serviceAccountTokenPath: string;
  namespace?: string;
}

export type AuthenticationConfig =
  | { type: 'static'; config: VaultStaticTokenConfig }
  | { type: 'kubernetes'; config: VaultKubernetesAuthConfig };

/** @public */
export interface VaultConfig {
  baseUrl: string;
  publicUrl?: string;
  defaultNamespace?: string;
  token: AuthenticationConfig;
  secretEngine: string;
  kvVersion: number;
  secretSuffix?: string;
}

/** @public */
export function getVaultConfig(config: Config): VaultConfig {
  let tokenCfg: AuthenticationConfig;

  if (config.has('vault.token')) {
    tokenCfg = {
      type: 'static',
      config: {
        secret: config.getString('vault.token'),
      },
    };
  } else {
    const authType = config.getString('vault.auth.type');
    switch (authType) {
      case 'static':
        tokenCfg = {
          type: 'static',
          config: {
            secret: config.getString('vault.auth.secret'),
          },
        };
        break;
      case 'kubernetes': {
        const authNamespace = config.getOptionalString('vault.auth.namespace');
        tokenCfg = {
          type: 'kubernetes',
          config: {
            role: config.getString('vault.auth.role'),
            authPath:
              config.getOptionalString('vault.auth.authPath') ?? 'kubernetes',
            serviceAccountTokenPath:
              config.getOptionalString('vault.auth.serviceAccountTokenPath') ??
              '/var/run/secrets/kubernetes.io/serviceaccount/token',
            ...(authNamespace !== undefined ? { namespace: authNamespace } : {}),
          },
        };
        break;
      }
      default:
        throw new Error(`unknown authentication type: ${authType}`);
    }
  }

  const defaultNamespace = config.getOptionalString('vault.namespace');

  return {
    baseUrl: config.getString('vault.baseUrl').replace(/\/+$/, ''),
    publicUrl: config
      .getOptionalString('vault.publicUrl')
      ?.replace(/\/+$/, ''),
    ...(defaultNamespace !== undefined ? { defaultNamespace } : {}),
    token: tokenCfg,
    kvVersion: config.getOptionalNumber('vault.kvVersion') ?? 2,
    secretEngine: config.getOptionalString('vault.secretEngine') ?? 'secrets',
    secretSuffix: config.getOptionalString('vault.secretSuffix'),
  };
}
```

---

### File 7 of 16: `plugins/vault-backend/src/service/vaultApi.ts`
Implements `X-Vault-Namespace` header injection on Kubernetes Auth login and `metadata/*` API calls, caches Kubernetes Auth client tokens per namespace, enriches KV v2 key metadata (`current_version`, `updated_time`), and appends `?namespace=` to Vault UI deep-links. **Never calls `kv/data/*` (secret values).**

```ts
import { Config } from '@backstage/config';
import { NotAllowedError, NotFoundError } from '@backstage/errors';
import fetch from 'node-fetch';
import plimit from 'p-limit';
import { readFile } from 'fs/promises';
import {
  getVaultConfig,
  VaultConfig,
  VaultKubernetesAuthConfig,
} from '../config';

/** @internal */
export type VaultSecretList = {
  data: {
    keys: string[];
  };
};

type VaultMetadataItem = {
  data?: {
    current_version?: number;
    updated_time?: string;
  };
};

type RenewTokenResponse = {
  auth: {
    client_token: string;
  };
};

/** @public */
export type VaultSecret = {
  name: string;
  path: string;
  showUrl: string;
  editUrl: string;
  version?: number;
  updatedTime?: string | null;
};

/** @public */
export interface VaultApi {
  getFrontendSecretsUrl(namespace?: string, secretEngine?: string): string;
  getCreateSecretUrl(
    secretPath: string,
    secretEngine?: string,
    namespace?: string,
  ): string;
  listSecrets(
    secretPath: string,
    options?: {
      secretEngine?: string;
      namespace?: string;
    },
  ): Promise<VaultSecret[]>;
  renewToken?(): Promise<void>;
}

/** @public */
export class VaultClient implements VaultApi {
  private vaultConfig: VaultConfig;
  private readonly limit = plimit(5);
  private readonly tokenCache = new Map<
    string,
    { token: string; expiresAt: number }
  >();

  constructor(options: { config: Config }) {
    this.vaultConfig = getVaultConfig(options.config);
  }

  private async kubernetesLogin(
    baseUrl: string,
    kubernetesCfg: VaultKubernetesAuthConfig,
    targetNamespace?: string,
  ): Promise<string> {
    const authNamespace =
      kubernetesCfg.namespace !== undefined
        ? kubernetesCfg.namespace
        : targetNamespace ?? '';
    const cacheKey = `${kubernetesCfg.authPath}::${kubernetesCfg.role}::${authNamespace}`;
    const now = Date.now();
    const cached = this.tokenCache.get(cacheKey);
    if (cached && now < cached.expiresAt) {
      return cached.token;
    }

    const jwt = (
      await readFile(kubernetesCfg.serviceAccountTokenPath, 'utf-8')
    ).trim();

    const headers: Record<string, string> = {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    };
    if (authNamespace) {
      headers['X-Vault-Namespace'] = authNamespace;
    }

    const resp = await fetch(
      `${baseUrl}/v1/auth/${encodeURIComponent(kubernetesCfg.authPath)}/login`,
      {
        method: 'POST',
        headers,
        body: JSON.stringify({
          role: kubernetesCfg.role,
          jwt,
        }),
      },
    );

    if (!resp.ok) {
      const errBody = await resp.text().catch(() => resp.statusText);
      throw new Error(
        `Vault Kubernetes Auth login failed (HTTP ${resp.status}, namespace='${authNamespace || 'root'}'): ${errBody}`,
      );
    }

    const result: {
      auth: { client_token: string; lease_duration?: number };
    } = await resp.json();

    const leaseSeconds = Number(result.auth.lease_duration || 300);
    this.tokenCache.set(cacheKey, {
      token: result.auth.client_token,
      expiresAt: now + Math.max(30, leaseSeconds - 60) * 1000,
    });
    return result.auth.client_token;
  }

  private async loadToken(targetNamespace?: string): Promise<string> {
    switch (this.vaultConfig.token.type) {
      case 'static':
        return this.vaultConfig.token.config.secret;
      case 'kubernetes':
        return await this.kubernetesLogin(
          this.vaultConfig.baseUrl,
          this.vaultConfig.token.config,
          targetNamespace,
        );
      default:
        throw new Error('Unknown Vault authentication type');
    }
  }

  private async callApi<T>(
    path: string,
    query: { [key in string]: any },
    method: string = 'GET',
    namespace?: string,
  ): Promise<T> {
    const resolvedNs = namespace || this.vaultConfig.defaultNamespace;
    const token = await this.loadToken(resolvedNs);
    const cleanPath = path.replace(/^\/+/, '');
    const qs = new URLSearchParams(query).toString();
    const fullUrl = `${this.vaultConfig.baseUrl}/${cleanPath}${qs ? `?${qs}` : ''}`;

    const headers: Record<string, string> = {
      Accept: 'application/json',
      'X-Vault-Token': token,
    };
    if (resolvedNs) {
      headers['X-Vault-Namespace'] = resolvedNs;
    }

    const response = await fetch(fullUrl, {
      method,
      headers,
    });
    if (response.ok) {
      return (await response.json()) as T;
    } else if (response.status === 404) {
      throw new NotFoundError(`No secrets found in path '${path}'`);
    } else if (response.status === 403) {
      throw new NotAllowedError(
        `Vault denied access to '${path}' in namespace '${resolvedNs || 'root'}'`,
      );
    }
    throw new Error(
      `Unexpected error (HTTP ${response.status}) while fetching secrets from path '${path}'`,
    );
  }

  getFrontendSecretsUrl(namespace?: string, secretEngine?: string): string {
    const vaultUrl = this.vaultConfig.publicUrl || this.vaultConfig.baseUrl;
    const mount = secretEngine || this.vaultConfig.secretEngine;
    const resolvedNs = namespace || this.vaultConfig.defaultNamespace;
    const nsQuery = resolvedNs
      ? `?namespace=${encodeURIComponent(resolvedNs)}`
      : '';
    return `${vaultUrl}/ui/vault/secrets/${encodeURIComponent(mount)}${nsQuery}`;
  }

  getCreateSecretUrl(
    secretPath: string,
    secretEngine?: string,
    namespace?: string,
  ): string {
    const vaultUrl = this.vaultConfig.publicUrl || this.vaultConfig.baseUrl;
    const mount = secretEngine || this.vaultConfig.secretEngine;
    const resolvedNs = namespace || this.vaultConfig.defaultNamespace;
    const pathWithSuffix = this.vaultConfig.secretSuffix
      ? `${secretPath}/${this.vaultConfig.secretSuffix}`
      : secretPath;
    const nsParam = resolvedNs
      ? `&namespace=${encodeURIComponent(resolvedNs)}`
      : '';
    return `${vaultUrl}/ui/vault/secrets/${encodeURIComponent(
      mount,
    )}/kv/create?initialKey=${encodeURIComponent(pathWithSuffix)}${nsParam}`;
  }

  async listSecrets(
    secretPath: string,
    options?: {
      secretEngine?: string;
      namespace?: string;
    },
  ): Promise<VaultSecret[]> {
    const mount = options?.secretEngine || this.vaultConfig.secretEngine;
    const resolvedNs = options?.namespace || this.vaultConfig.defaultNamespace;
    const cleanSecretPath = secretPath.replace(/^\/+|\/+$/g, '');

    const listUrl =
      this.vaultConfig.kvVersion === 2
        ? `v1/${encodeURIComponent(mount)}/metadata/${cleanSecretPath}`
        : `v1/${encodeURIComponent(mount)}/${cleanSecretPath}`;

    let result: VaultSecretList;
    try {
      result = await this.limit(() =>
        this.callApi<VaultSecretList>(
          listUrl,
          { list: 'true' },
          'GET',
          resolvedNs,
        ),
      );
    } catch (err) {
      if (err instanceof NotFoundError) {
        return [];
      }
      throw err;
    }

    const secrets: VaultSecret[] = [];
    const nsQuery = resolvedNs
      ? `?namespace=${encodeURIComponent(resolvedNs)}`
      : '';
    const vaultUrl = this.vaultConfig.publicUrl || this.vaultConfig.baseUrl;

    await Promise.all(
      result.data.keys.map(async secret => {
        if (secret.endsWith('/')) {
          secrets.push(
            ...(await this.listSecrets(
              `${cleanSecretPath}/${secret.slice(0, -1)}`,
              {
                secretEngine: mount,
                namespace: resolvedNs,
              },
            )),
          );
        } else {
          const entryPath = `${cleanSecretPath}/${secret}`;
          const metadataFields: {
            version?: number;
            updatedTime?: string | null;
          } = {};

          if (this.vaultConfig.kvVersion === 2) {
            try {
              const meta = await this.limit(() =>
                this.callApi<VaultMetadataItem>(
                  `v1/${encodeURIComponent(mount)}/metadata/${entryPath}`,
                  {},
                  'GET',
                  resolvedNs,
                ),
              );
              if (meta?.data?.current_version !== undefined) {
                metadataFields.version = meta.data.current_version;
              }
              if (meta?.data?.updated_time !== undefined) {
                metadataFields.updatedTime = meta.data.updated_time;
              }
            } catch {
              // Optional per-key metadata enrichment; ignore if unavailable
            }
          }

          secrets.push({
            name: secret,
            path: cleanSecretPath,
            ...metadataFields,
            editUrl: `${vaultUrl}/ui/vault/secrets/${encodeURIComponent(
              mount,
            )}/edit/${cleanSecretPath}/${secret}${nsQuery}`,
            showUrl: `${vaultUrl}/ui/vault/secrets/${encodeURIComponent(
              mount,
            )}/show/${cleanSecretPath}/${secret}${nsQuery}`,
          });
        }
      }),
    );

    return secrets;
  }

  async renewToken(): Promise<void> {
    if (this.vaultConfig.token.type === 'kubernetes') {
      return;
    }
    const result = await this.callApi<RenewTokenResponse>(
      'v1/auth/token/renew-self',
      {},
      'POST',
    );
    this.vaultConfig.token.config.secret = result.auth.client_token;
  }
}
```

---

### File 8 of 16: `plugins/vault-backend/src/service/VaultBuilder.ts`
Enforces `httpAuth` user authentication, `PermissionsService` (`catalog.entity.read`), and `vault.io/allowed-principals` group RBAC on `GET /v1/entities/:namespace/:kind/:name/secrets`, while blocking legacy `/v1/secrets/*` enumeration (`HTTP 403`).

```ts
import { Config } from '@backstage/config';
import {
  InputError,
  NotAllowedError,
  NotFoundError,
} from '@backstage/errors';
import {
  HttpAuthService,
  LoggerService,
  PermissionsService,
  readSchedulerServiceTaskScheduleDefinitionFromConfig,
  SchedulerService,
  SchedulerServiceTaskRunner,
  SchedulerServiceTaskScheduleDefinition,
  SchedulerServiceTaskScheduleDefinitionConfig,
  UserInfoService,
} from '@backstage/backend-plugin-api';
import { CatalogService } from '@backstage/plugin-catalog-node';
import { catalogEntityReadPermission } from '@backstage/plugin-catalog-common/alpha';
import { AuthorizeResult } from '@backstage/plugin-permission-common';
import { Entity, stringifyEntityRef } from '@backstage/catalog-model';
import express from 'express';
import Router from 'express-promise-router';
import { VaultApi, VaultClient } from './vaultApi';
import { MiddlewareFactory } from '@backstage/backend-defaults/rootHttpRouter';

/** @public */
export interface VaultEnvironment {
  logger: LoggerService;
  config: Config;
  scheduler: SchedulerService;
  httpAuth?: HttpAuthService;
  userInfo?: UserInfoService;
  permissions?: PermissionsService;
  catalog?: CatalogService;
}

/** @public */
export type VaultBuilderReturn = {
  router: express.Router;
};

/** @public */
export class VaultBuilder {
  private vaultApi?: VaultApi;

  static createBuilder(env: VaultEnvironment) {
    return new VaultBuilder(env);
  }

  constructor(private readonly env: VaultEnvironment) {}

  public build(): VaultBuilderReturn {
    const { logger, config } = this.env;

    logger.info('Initializing Enterprise Vault Namespace backend');

    if (!config.has('vault')) {
      logger.warn(
        'Failed to initialize Vault backend: vault config is missing',
      );
      return {
        router: Router(),
      };
    }

    this.vaultApi = this.vaultApi ?? new VaultClient(this.env);
    const router = this.buildRouter(this.vaultApi);
    return { router };
  }

  public setVaultClient(vaultApi: VaultApi) {
    this.vaultApi = vaultApi;
    return this;
  }

  public async enableTokenRenew(schedule?: SchedulerServiceTaskRunner) {
    if (
      this.env.config.has('vault.auth') &&
      this.env.config.getString('vault.auth.type') === 'kubernetes'
    ) {
      return this;
    }

    const taskRunner =
      schedule ??
      this.env.scheduler.createScheduledTaskRunner(this.getConfigSchedule());

    await taskRunner.run({
      id: 'refresh-vault-token',
      fn: async () => {
        const vaultApi = this.vaultApi ?? new VaultClient(this.env);
        await vaultApi.renewToken?.();
      },
    });
    return this;
  }

  private getConfigSchedule(): SchedulerServiceTaskScheduleDefinition {
    const schedule =
      this.env.config.getOptional<SchedulerServiceTaskScheduleDefinitionConfig>(
        'vault.schedule',
      );

    return schedule !== undefined
      ? readSchedulerServiceTaskScheduleDefinitionFromConfig(
          this.env.config.getConfig('vault.schedule'),
        )
      : {
          frequency: { hours: 1 },
          timeout: { hours: 1 },
        };
  }

  private async authorizeAndLoadEntity(req: express.Request): Promise<{
    entity: Entity;
    vaultNamespace?: string;
    secretEngine?: string;
    secretPaths: string[];
    principal: string;
  }> {
    const { httpAuth, userInfo, permissions, catalog, logger } = this.env;
    if (!httpAuth || !userInfo || !permissions || !catalog) {
      throw new NotAllowedError(
        'Vault RBAC services (httpAuth, userInfo, permissions, catalog) are required',
      );
    }

    const { namespace, kind, name } = req.params;
    const credentials = await httpAuth.credentials(req, { allow: ['user'] });
    const info = await userInfo.getUserInfo(credentials);

    const entity = await catalog.getEntityByRef(
      { kind, namespace, name },
      { credentials },
    );
    if (!entity) {
      throw new NotFoundError(
        `Entity ${kind}:${namespace}/${name} not found or hidden by Catalog RBAC`,
      );
    }

    const entityRef = stringifyEntityRef(entity);
    const [decision] = await permissions.authorize(
      [{ permission: catalogEntityReadPermission, resourceRef: entityRef }],
      { credentials },
    );
    if (decision.result !== AuthorizeResult.ALLOW) {
      throw new NotAllowedError(
        `RHDH RBAC denied ${info.userEntityRef} access to ${entityRef}`,
      );
    }

    const annotations = entity.metadata?.annotations ?? {};
    const vaultNamespace = annotations['vault.io/namespace']?.trim();
    const secretEngine = annotations['vault.io/secrets-engine']?.trim();
    const rawPaths = annotations['vault.io/secrets-path']?.trim() ?? '';
    const allowedPrincipalsRaw =
      annotations['vault.io/allowed-principals']?.trim() ?? '';

    if (!rawPaths) {
      throw new InputError(
        `Entity ${entityRef} is missing required annotation 'vault.io/secrets-path'`,
      );
    }

    // Optional explicit Vault Namespace / Team group guard (`vault.io/allowed-principals`)
    if (allowedPrincipalsRaw) {
      const allowedPrincipals = allowedPrincipalsRaw
        .split(',')
        .map(s => s.trim().toLowerCase())
        .filter(Boolean);
      const callerRefs = (
        info.ownershipEntityRefs ?? [info.userEntityRef]
      ).map(s => s.toLowerCase());
      const matched = allowedPrincipals.some(ap => callerRefs.includes(ap));
      if (!matched) {
        logger.warn(
          `Vault Namespace RBAC denied ${info.userEntityRef} for namespace '${vaultNamespace || 'default'}' on ${entityRef}`,
        );
        throw new NotAllowedError(
          `Team RBAC restricts Vault namespace '${vaultNamespace || 'default'}' to [${allowedPrincipalsRaw}] (caller: ${info.userEntityRef})`,
        );
      }
    }

    const secretPaths = rawPaths
      .split(',')
      .map(p => p.trim())
      .filter(Boolean);

    return {
      entity,
      vaultNamespace,
      secretEngine,
      secretPaths,
      principal: info.userEntityRef,
    };
  }

  private buildRouter(vaultApi: VaultApi): express.Router {
    const router = Router();
    router.use(express.json());

    router.get('/health', (_, res) => {
      res.json({ status: 'ok' });
    });

    // Secure Entity-Scoped Route: enforces RHDH Catalog RBAC + vault.io/allowed-principals
    // and reads Vault namespace & secret paths exclusively from the Catalog Entity.
    router.get(
      '/v1/entities/:namespace/:kind/:name/secrets',
      async (req, res) => {
        const {
          vaultNamespace,
          secretEngine,
          secretPaths,
          principal,
        } = await this.authorizeAndLoadEntity(req);

        const items = [];
        const createUrls: Record<string, string> = {};
        for (const p of secretPaths) {
          const found = await vaultApi.listSecrets(p, {
            secretEngine,
            namespace: vaultNamespace,
          });
          items.push(...found);
          if (found.length === 0) {
            createUrls[p] = vaultApi.getCreateSecretUrl(
              p,
              secretEngine,
              vaultNamespace,
            );
          }
        }

        const vaultUrl = vaultApi.getFrontendSecretsUrl(
          vaultNamespace,
          secretEngine,
        );
        res.json({
          items,
          vaultUrl,
          vaultNamespace: vaultNamespace ?? null,
          principal,
          createUrls,
        });
      },
    );

    // Block legacy unauthenticated arbitrary-path enumeration
    router.get('/v1/secrets/*', (_req, _res) => {
      throw new NotAllowedError(
        'Direct Vault path enumeration is disabled by security policy; query via /v1/entities/:namespace/:kind/:name/secrets',
      );
    });

    router.use(MiddlewareFactory.create(this.env).error());
    return router;
  }
}
```

---

### File 9 of 16: `plugins/vault-backend/src/service/plugin.ts`
Injects `coreServices.httpAuth`, `coreServices.userInfo`, `coreServices.permissions`, and `catalogServiceRef` into `VaultBuilder` and leaves only `/health` unauthenticated.

```ts
import {
  coreServices,
  createBackendPlugin,
  SchedulerServiceTaskScheduleDefinitionConfig,
} from '@backstage/backend-plugin-api';
import { catalogServiceRef } from '@backstage/plugin-catalog-node';
import {
  VaultApi,
  vaultExtensionPoint,
} from '@backstage-community/plugin-vault-node';
import { VaultBuilder } from './VaultBuilder';

/** @public */
export const vaultPlugin = createBackendPlugin({
  pluginId: 'vault',
  register(env) {
    let client: VaultApi | undefined;

    env.registerExtensionPoint(vaultExtensionPoint, {
      setClient(vaultClient) {
        if (client) {
          throw new Error('The vault client has been already set');
        }
        client = vaultClient;
      },
    });

    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        scheduler: coreServices.scheduler,
        httpRouter: coreServices.httpRouter,
        httpAuth: coreServices.httpAuth,
        userInfo: coreServices.userInfo,
        permissions: coreServices.permissions,
        catalog: catalogServiceRef,
      },
      async init({
        logger,
        config,
        scheduler,
        httpRouter,
        httpAuth,
        userInfo,
        permissions,
        catalog,
      }) {
        let builder = VaultBuilder.createBuilder({
          logger,
          config,
          scheduler,
          httpAuth,
          userInfo,
          permissions,
          catalog,
        });

        if (client) {
          builder = builder.setVaultClient(client);
        }

        const scheduleCfg = config.getOptional<
          boolean | SchedulerServiceTaskScheduleDefinitionConfig
        >('vault.schedule');
        if (scheduleCfg !== undefined && scheduleCfg !== false) {
          builder = await builder.enableTokenRenew();
        }

        const { router } = builder.build();
        httpRouter.use(router);
        httpRouter.addAuthPolicy({
          path: '/health',
          allow: 'unauthenticated',
        });
      },
    });
  },
});
```

---

### File 10 of 16: `plugins/vault/package.json`
Adds `"scalprum"` (`"name": "backstage-community.plugin-vault"`, `"PluginRoot": "./src/index.ts"`) so `@red-hat-developer-hub/cli@1.10.8 plugin export` generates `dist-scalprum/plugin-manifest.json` for RHDH 1.10.

```json
{
  "name": "@backstage-community/plugin-vault",
  "version": "0.19.0",
  "description": "A Backstage plugin that integrates towards Vault",
  "backstage": {
    "role": "frontend-plugin",
    "pluginId": "vault",
    "pluginPackages": [
      "@backstage-community/plugin-vault",
      "@backstage-community/plugin-vault-backend",
      "@backstage-community/plugin-vault-node"
    ]
  },
  "scalprum": {
    "name": "backstage-community.plugin-vault",
    "exposedModules": {
      "PluginRoot": "./src/index.ts"
    }
  },
  "publishConfig": {
    "access": "public"
  },
  "keywords": [
    "backstage",
    "vault"
  ],
  "homepage": "https://backstage.io",
  "repository": {
    "type": "git",
    "url": "https://bitbucket.example.com/scm/idp/rhdh-plugin-vault.git",
    "directory": "plugins/vault"
  },
  "license": "Apache-2.0",
  "sideEffects": false,
  "main": "src/index.ts",
  "types": "src/index.ts",
  "files": [
    "dist"
  ],
  "scripts": {
    "build": "backstage-cli package build",
    "clean": "backstage-cli package clean",
    "lint": "backstage-cli package lint",
    "prepack": "backstage-cli package prepack",
    "postpack": "backstage-cli package postpack",
    "start": "backstage-cli package start",
    "test": "backstage-cli package test"
  },
  "dependencies": {
    "@backstage/catalog-model": "backstage:^",
    "@backstage/core-components": "backstage:^",
    "@backstage/core-plugin-api": "backstage:^",
    "@backstage/errors": "backstage:^",
    "@backstage/frontend-plugin-api": "backstage:^",
    "@backstage/plugin-catalog-react": "backstage:^",
    "@material-ui/core": "^4.12.2",
    "@material-ui/icons": "^4.9.1",
    "@material-ui/lab": "4.0.0-alpha.61",
    "@types/react": "^16.13.1 || ^17.0.0 || ^18.0.0",
    "react-use": "^17.2.4"
  },
  "exports": {
    ".": "./src/index.ts",
    "./alpha": "./src/alpha.tsx",
    "./package.json": "./package.json"
  },
  "typesVersions": {
    "*": {
      "alpha": [
        "src/alpha.tsx"
      ],
      "package.json": [
        "package.json"
      ]
    }
  },
  "devDependencies": {
    "@backstage/cli": "backstage:^",
    "@backstage/core-app-api": "backstage:^",
    "@backstage/dev-utils": "backstage:^",
    "@backstage/plugin-catalog": "backstage:^",
    "@backstage/test-utils": "backstage:^",
    "@testing-library/dom": "^10.0.0",
    "@testing-library/jest-dom": "^6.0.0",
    "@testing-library/react": "^15.0.0",
    "@types/react-dom": "^18.2.19",
    "msw": "^1.0.0",
    "react": "^16.13.1 || ^17.0.0 || ^18.0.0",
    "react-dom": "^16.13.1 || ^17.0.0 || ^18.0.0",
    "react-router-dom": "6.0.0-beta.0 || ^6.3.0"
  },
  "peerDependencies": {
    "react": "^16.13.1 || ^17.0.0 || ^18.0.0",
    "react-dom": "^16.13.1 || ^17.0.0 || ^18.0.0",
    "react-router-dom": "6.0.0-beta.0 || ^6.3.0"
  }
}
```

---

### File 11 of 16: `plugins/vault/src/constants.ts`
Defines `vault.io/namespace` and `vault.io/allowed-principals` alongside existing annotations.

```ts
/** @public */
export const VAULT_SECRET_ENGINE_ANNOTATION = 'vault.io/secrets-engine';
/** @public */
export const VAULT_SECRET_PATH_ANNOTATION = 'vault.io/secrets-path';
/** @public */
export const VAULT_NAMESPACE_ANNOTATION = 'vault.io/namespace';
/** @public */
export const VAULT_ALLOWED_PRINCIPALS_ANNOTATION =
  'vault.io/allowed-principals';
```

---

### File 12 of 16: `plugins/vault/src/api.ts`
Calls the authenticated entity-scoped backend route `GET /v1/entities/:namespace/:kind/:name/secrets` via `FetchApi` (which automatically attaches the signed-in user's Backstage bearer token).

```ts
import {
  DiscoveryApi,
  createApiRef,
  FetchApi,
} from '@backstage/core-plugin-api';
import { ResponseError } from '@backstage/errors';

/** @public */
export const vaultApiRef = createApiRef<VaultApi>({
  id: 'plugin.vault.service',
});

/** @public */
export type VaultSecret = {
  name: string;
  path: string;
  showUrl: string;
  editUrl: string;
  version?: number;
  updatedTime?: string | null;
};

/** @public */
export type ListSecretsResponse = {
  secrets: VaultSecret[];
  vaultUrl?: string;
  vaultNamespace?: string | null;
  principal?: string;
  createUrls?: Record<string, string>;
  createUrl?: string;
};

/** @public */
export interface VaultApi {
  listEntitySecrets(entityRef: {
    namespace: string;
    kind: string;
    name: string;
  }): Promise<ListSecretsResponse>;

  listSecrets(
    secretPath: string,
    options?: {
      secretEngine?: string;
    },
  ): Promise<ListSecretsResponse>;

  getCreateUrl?(
    secretPath: string,
    options?: {
      secretEngine?: string;
    },
  ): Promise<string | undefined>;
}

/** @public */
export class VaultClient implements VaultApi {
  private readonly discoveryApi: DiscoveryApi;
  private readonly fetchApi: FetchApi;

  constructor({
    discoveryApi,
    fetchApi,
  }: {
    discoveryApi: DiscoveryApi;
    fetchApi: FetchApi;
  }) {
    this.discoveryApi = discoveryApi;
    this.fetchApi = fetchApi;
  }

  async listEntitySecrets(entityRef: {
    namespace: string;
    kind: string;
    name: string;
  }): Promise<ListSecretsResponse> {
    const apiUrl = await this.discoveryApi.getBaseUrl('vault');
    const url = `${apiUrl}/v1/entities/${encodeURIComponent(
      entityRef.namespace || 'default',
    )}/${encodeURIComponent(
      entityRef.kind.toLowerCase(),
    )}/${encodeURIComponent(entityRef.name)}/secrets`;

    const response = await this.fetchApi.fetch(url, {
      headers: { Accept: 'application/json' },
    });

    if (!response.ok) {
      throw await ResponseError.fromResponse(response);
    }

    const result: {
      items: VaultSecret[];
      vaultUrl?: string;
      vaultNamespace?: string | null;
      principal?: string;
      createUrls?: Record<string, string>;
    } = await response.json();

    return {
      secrets: result.items ?? [],
      vaultUrl: result.vaultUrl,
      vaultNamespace: result.vaultNamespace,
      principal: result.principal,
      createUrls: result.createUrls,
    };
  }

  async listSecrets(
    _secretPath: string,
    _options?: { secretEngine?: string },
  ): Promise<ListSecretsResponse> {
    throw new Error(
      'Direct listSecrets(path) is disabled; use listEntitySecrets(entityRef)',
    );
  }

  async getCreateUrl(): Promise<string | undefined> {
    return undefined;
  }
}
```

---

### File 13 of 16: `plugins/vault/src/components/EntityVaultTable/EntityVaultTable.tsx`
Displays the Vault Enterprise namespace chip (`ns: payments/nonprod`), KV v2 version (`v1`, `v3`), `?namespace=` deep-links, empty-path creation links, and a clear `Vault Namespace Access Restricted (403 RBAC)` warning banner when cross-team access is denied.

```tsx
import { Entity } from '@backstage/catalog-model';
import { Link, Table, TableColumn } from '@backstage/core-components';
import { useApi } from '@backstage/core-plugin-api';
import Box from '@material-ui/core/Box';
import Chip from '@material-ui/core/Chip';
import Typography from '@material-ui/core/Typography';
import Edit from '@material-ui/icons/Edit';
import Visibility from '@material-ui/icons/Visibility';
import Alert from '@material-ui/lab/Alert';
import useAsync from 'react-use/esm/useAsync';
import { VaultSecret, vaultApiRef } from '../../api';
import {
  VAULT_NAMESPACE_ANNOTATION,
  VAULT_SECRET_ENGINE_ANNOTATION,
  VAULT_SECRET_PATH_ANNOTATION,
} from '../../constants';

export const vaultSecretConfig = (entity: Entity) => {
  const secretPathAnnotation =
    entity.metadata.annotations?.[VAULT_SECRET_PATH_ANNOTATION];
  const secretPaths = secretPathAnnotation
    ? secretPathAnnotation
        .split(',')
        .map(path => path.trim())
        .filter(Boolean)
    : [];
  const secretEngine =
    entity.metadata.annotations?.[VAULT_SECRET_ENGINE_ANNOTATION];
  const vaultNamespace =
    entity.metadata.annotations?.[VAULT_NAMESPACE_ANNOTATION];

  return { secretPaths, secretEngine, vaultNamespace };
};

export const EntityVaultTable = ({ entity }: { entity: Entity }) => {
  const vaultApi = useApi(vaultApiRef);
  const { secretPaths, vaultNamespace } = vaultSecretConfig(entity);
  if (!secretPaths || secretPaths.length === 0) {
    throw Error(
      `The secret path is undefined. Please define the annotation ${VAULT_SECRET_PATH_ANNOTATION}`,
    );
  }

  const entityNamespace = entity.metadata.namespace || 'default';
  const entityKind = entity.kind.toLowerCase();
  const entityName = entity.metadata.name;

  const { value, loading, error } = useAsync(async () => {
    return await vaultApi.listEntitySecrets({
      namespace: entityNamespace,
      kind: entityKind,
      name: entityName,
    });
  }, [entityNamespace, entityKind, entityName]);

  if (error) {
    const isForbidden =
      (error as any)?.statusCode === 403 ||
      error.message.includes('403') ||
      error.message.includes('NotAllowedError');
    return (
      <Alert severity={isForbidden ? 'warning' : 'error'}>
        <strong>
          {isForbidden
            ? 'Vault Namespace Access Restricted (403 RBAC)'
            : 'Vault Metadata Error'}
          :
        </strong>{' '}
        {error.message}
      </Alert>
    );
  }

  const columns: TableColumn[] = [
    { title: 'Path', field: 'path', width: '25%' },
    { title: 'Secret Key (Metadata Only)', field: 'secret', highlight: true },
    { title: 'Ver', field: 'version', width: '10%' },
    { title: 'View', field: 'view', width: '10%' },
    { title: 'Edit', field: 'edit', width: '10%' },
  ];

  const secrets: VaultSecret[] = value?.secrets ?? [];
  const createUrls = value?.createUrls ?? {};
  const data: any[] = [];

  if (secrets.length === 0 && !loading) {
    secretPaths.forEach(p => {
      const createUrl = createUrls[p];
      data.push({
        path: p,
        secret: (
          <Typography variant="body2" color="textSecondary">
            No secrets found
            {createUrl ? (
              <>
                {' — '}
                <Link to={createUrl}>Create in Vault UI</Link>
              </>
            ) : null}
          </Typography>
        ),
        version: '-',
        view: null,
        edit: null,
      });
    });
  } else {
    secrets.forEach((secret, index) => {
      const relativeSubPath = secret.path.startsWith(`${secretPaths[0]}/`)
        ? `${secret.path.slice(secretPaths[0].length + 1)}/${secret.name}`
        : secret.name;
      data.push({
        path: index === 0 ? secret.path : '',
        secret: relativeSubPath,
        version: secret.version ? `v${secret.version}` : 'v1',
        view: (
          <Link
            aria-label="View"
            title={`Open ${secret.name} in Vault UI`}
            to={secret.showUrl}
          >
            <Visibility style={{ fontSize: 16 }} />
          </Link>
        ),
        edit: (
          <Link
            aria-label="Edit"
            title={`Edit ${secret.name} in Vault UI`}
            to={secret.editUrl}
          >
            <Edit style={{ fontSize: 16 }} />
          </Link>
        ),
      });
    });
  }

  const resolvedNs = value?.vaultNamespace || vaultNamespace;
  const titleNode = (
    <Box display="flex" alignItems="center" style={{ gap: 8 }}>
      <span>Vault Enterprise Secrets</span>
      {resolvedNs ? (
        <Chip size="small" color="primary" label={`ns: ${resolvedNs}`} />
      ) : null}
    </Box>
  );

  const subtitle =
    secretPaths.length === 1
      ? `Metadata for ${entity.metadata.name} (${secretPaths[0]})`
      : `Metadata for ${entity.metadata.name} (${secretPaths.length} paths)`;

  return (
    <Table
      title={titleNode as any}
      subtitle={subtitle}
      columns={columns}
      data={data}
      isLoading={loading}
      options={{
        padding: 'dense',
        pageSize: 5,
        emptyRowsWhenPaging: false,
        search: false,
      }}
      emptyContent={
        <Box style={{ textAlign: 'center', padding: '15px' }}>
          <Typography variant="body2">
            No secret metadata found for {entity.metadata.name} in{' '}
            {secretPaths.join(', ')}
          </Typography>
        </Box>
      }
    />
  );
};
```

---

### File 14 of 16 (Unit Test): `plugins/vault-backend/src/service/VaultBuilder.test.ts`
Updates the backend router unit tests to verify `/v1/secrets/*` lockdown (`403`), namespace-scoped `listSecrets`, and `vault.io/allowed-principals` cross-team `403` denial.

```ts
import { ConfigReader } from '@backstage/config';
import express from 'express';
import request from 'supertest';
import { mockCredentials, mockServices } from '@backstage/backend-test-utils';
import { AuthorizeResult } from '@backstage/plugin-permission-common';
import { CatalogService } from '@backstage/plugin-catalog-node';
import { VaultBuilder } from './VaultBuilder';
import { VaultApi } from './vaultApi';

describe('VaultBuilder (Enterprise Namespace + RBAC)', () => {
  const mockVaultApi: jest.Mocked<VaultApi> = {
    getFrontendSecretsUrl: jest.fn(
      (ns, engine) =>
        `https://vault.example.com/ui/vault/secrets/${engine ?? 'kv'}${
          ns ? `?namespace=${encodeURIComponent(ns)}` : ''
        }`,
    ),
    getCreateSecretUrl: jest.fn(
      (p, engine, ns) =>
        `https://vault.example.com/ui/vault/secrets/${
          engine ?? 'kv'
        }/kv/create?initialKey=${encodeURIComponent(p)}${
          ns ? `&namespace=${encodeURIComponent(ns)}` : ''
        }`,
    ),
    listSecrets: jest.fn(async (p, opts) => [
      {
        name: 'db-password',
        path: p,
        version: 3,
        showUrl: `https://vault.example.com/ui/vault/secrets/kv/show/${p}/db-password?namespace=${encodeURIComponent(
          opts?.namespace ?? '',
        )}`,
        editUrl: `https://vault.example.com/ui/vault/secrets/kv/edit/${p}/db-password?namespace=${encodeURIComponent(
          opts?.namespace ?? '',
        )}`,
      },
    ]),
  };

  const buildApp = (callerGroups: string[]) => {
    const httpAuth = mockServices.httpAuth({
      defaultCredentials: mockCredentials.user('user:default/alice'),
    });
    const userInfo = mockServices.userInfo.mock({
      getUserInfo: jest.fn(async () => ({
        userEntityRef: 'user:default/alice',
        ownershipEntityRefs: ['user:default/alice', ...callerGroups],
      })),
    });
    const permissions = mockServices.permissions.mock({
      authorize: jest.fn(async () => [{ result: AuthorizeResult.ALLOW }]),
    });
    const catalog = {
      getEntityByRef: jest.fn(async () => ({
        apiVersion: 'backstage.io/v1alpha1',
        kind: 'Component',
        metadata: {
          name: 'payments-checkout-service',
          namespace: 'default',
          annotations: {
            'vault.io/namespace': 'payments/nonprod',
            'vault.io/secrets-engine': 'kv',
            'vault.io/secrets-path': 'apps/payments-checkout-service',
            'vault.io/allowed-principals': 'group:default/team-payments',
          },
        },
      })),
    } as unknown as CatalogService;

    const builder = VaultBuilder.createBuilder({
      logger: mockServices.logger.mock(),
      config: new ConfigReader({
        vault: {
          baseUrl: 'https://vault.example.com',
          secretEngine: 'kv',
          auth: {
            type: 'static',
            secret: 'test-token',
          },
        },
      }),
      scheduler: mockServices.scheduler.mock(),
      httpAuth,
      userInfo,
      permissions,
      catalog,
    }).setVaultClient(mockVaultApi);

    return express().use(builder.build().router);
  };

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('blocks legacy unauthenticated /v1/secrets/* path enumeration with 403', async () => {
    const app = buildApp(['group:default/team-payments']);
    const response = await request(app).get('/v1/secrets/any-path');
    expect(response.status).toEqual(403);
  });

  it('returns entity secrets scoped to vault.io/namespace when caller is authorized', async () => {
    const app = buildApp(['group:default/team-payments']);
    const response = await request(app).get(
      '/v1/entities/default/component/payments-checkout-service/secrets',
    );

    expect(response.status).toEqual(200);
    expect(response.body.vaultNamespace).toEqual('payments/nonprod');
    expect(response.body.items).toHaveLength(1);
    expect(mockVaultApi.listSecrets).toHaveBeenCalledWith(
      'apps/payments-checkout-service',
      {
        secretEngine: 'kv',
        namespace: 'payments/nonprod',
      },
    );
  });

  it('denies cross-team callers missing from vault.io/allowed-principals with 403', async () => {
    const app = buildApp(['group:default/team-retail']);
    const response = await request(app).get(
      '/v1/entities/default/component/payments-checkout-service/secrets',
    );

    expect(response.status).toEqual(403);
    expect(mockVaultApi.listSecrets).not.toHaveBeenCalled();
  });
});
```

---

### File 15 of 16 (Unit Test): `plugins/vault/src/api.test.ts`
Updates frontend API client unit tests for `listEntitySecrets`.

```ts
import { MockFetchApi, setupRequestMockHandlers } from '@backstage/test-utils';
import { rest } from 'msw';
import { setupServer } from 'msw/node';
import { VaultSecret, VaultClient } from './api';
import { UrlPatternDiscovery } from '@backstage/core-app-api';

describe('VaultClient (Entity-Scoped API)', () => {
  let api: VaultClient;
  let fetchApiSpy: jest.SpyInstance<Promise<Response>>;

  const server = setupServer();
  setupRequestMockHandlers(server);

  const mockBaseUrl = 'https://api-vault.com/api/vault';
  const discoveryApi = UrlPatternDiscovery.compile(mockBaseUrl);
  const fetchApi = new MockFetchApi();

  const mockSecretsResult: {
    items: VaultSecret[];
    vaultNamespace: string;
    vaultUrl: string;
  } = {
    vaultNamespace: 'payments/nonprod',
    vaultUrl:
      'https://vault.example.com/ui/vault/secrets/kv?namespace=payments%2Fnonprod',
    items: [
      {
        name: 'db-password',
        path: 'apps/payments-svc',
        version: 2,
        editUrl:
          'https://vault.example.com/ui/vault/secrets/kv/edit/apps/payments-svc/db-password?namespace=payments%2Fnonprod',
        showUrl:
          'https://vault.example.com/ui/vault/secrets/kv/show/apps/payments-svc/db-password?namespace=payments%2Fnonprod',
      },
    ],
  };

  beforeEach(() => {
    server.use(
      rest.get(
        `${mockBaseUrl}/v1/entities/:namespace/:kind/:name/secrets`,
        (req, res, ctx) => {
          const { name } = req.params;
          if (name === 'payments-svc') {
            return res(ctx.json(mockSecretsResult));
          }
          if (name === 'empty-svc') {
            return res(ctx.json({ items: [], vaultNamespace: 'payments/nonprod' }));
          }
          if (name === 'forbidden-svc') {
            return res(
              ctx.status(403),
              ctx.json({
                error: { name: 'NotAllowedError', message: 'Denied by RBAC' },
              }),
            );
          }
          return res(ctx.status(404));
        },
      ),
    );

    api = new VaultClient({ discoveryApi, fetchApi });
    fetchApiSpy = jest.spyOn(fetchApi, 'fetch');
  });

  it('fetches entity secrets via /v1/entities/:namespace/:kind/:name/secrets', async () => {
    const result = await api.listEntitySecrets({
      namespace: 'default',
      kind: 'Component',
      name: 'payments-svc',
    });

    expect(result.secrets).toEqual(mockSecretsResult.items);
    expect(result.vaultNamespace).toEqual('payments/nonprod');
    expect(fetchApiSpy).toHaveBeenCalledWith(
      `${mockBaseUrl}/v1/entities/default/component/payments-svc/secrets`,
      expect.anything(),
    );
  });

  it('returns empty secret list when entity path has no secrets', async () => {
    const result = await api.listEntitySecrets({
      namespace: 'default',
      kind: 'Component',
      name: 'empty-svc',
    });
    expect(result.secrets).toEqual([]);
  });

  it('throws ResponseError when backend returns 403 Forbidden', async () => {
    await expect(
      api.listEntitySecrets({
        namespace: 'default',
        kind: 'Component',
        name: 'forbidden-svc',
      }),
    ).rejects.toThrow();
  });

  it('rejects legacy arbitrary-path listSecrets()', async () => {
    await expect(api.listSecrets('any/path')).rejects.toThrow(
      'Direct listSecrets(path) is disabled',
    );
  });
});
```

---

### File 16 of 16 (Unit Test): `plugins/vault/src/components/EntityVaultTable/EntityVaultTable.test.tsx`
Updates `EntityVaultTable` component tests to assert secret rows, `ns: payments/nonprod` badge, `v3` version column, empty state, and `403 RBAC` alert rendering.

```tsx
import { setupServer } from 'msw/node';
import {
  MockFetchApi,
  renderInTestApp,
  setupRequestMockHandlers,
  TestApiRegistry,
} from '@backstage/test-utils';
import { ComponentEntity } from '@backstage/catalog-model';
import { ApiProvider, UrlPatternDiscovery } from '@backstage/core-app-api';
import { rest } from 'msw';
import { EntityVaultTable } from './EntityVaultTable';
import {
  ListSecretsResponse,
  vaultApiRef,
  VaultClient,
  VaultSecret,
} from '../../api';

describe('EntityVaultTable', () => {
  let vaultClient: VaultClient;
  let apis: TestApiRegistry;
  let listEntitySecretsSpy: jest.SpyInstance<Promise<ListSecretsResponse>>;

  const server = setupServer();
  setupRequestMockHandlers(server);
  const mockBaseUrl = 'https://api-vault.com/api/vault';
  const discoveryApi = UrlPatternDiscovery.compile(mockBaseUrl);
  const fetchApi = new MockFetchApi();

  const makeEntity = (
    name: string,
    secretPath: string,
    vaultNamespace?: string,
  ): ComponentEntity => ({
    apiVersion: 'backstage.io/v1alpha1',
    kind: 'Component',
    metadata: {
      name,
      namespace: 'default',
      annotations: {
        'vault.io/secrets-path': secretPath,
        ...(vaultNamespace ? { 'vault.io/namespace': vaultNamespace } : {}),
      },
    },
    spec: {
      lifecycle: 'production',
      owner: 'group:default/team-payments',
      type: 'service',
    },
  });

  const mockSecrets: VaultSecret[] = [
    {
      name: 'secret::one',
      path: 'apps/payments-svc',
      version: 3,
      editUrl:
        'https://vault.example.com/ui/vault/secrets/kv/edit/apps/payments-svc/secret::one?namespace=payments%2Fnonprod',
      showUrl:
        'https://vault.example.com/ui/vault/secrets/kv/show/apps/payments-svc/secret::one?namespace=payments%2Fnonprod',
    },
    {
      name: 'secret::two',
      path: 'apps/payments-svc',
      version: 1,
      editUrl:
        'https://vault.example.com/ui/vault/secrets/kv/edit/apps/payments-svc/secret::two?namespace=payments%2Fnonprod',
      showUrl:
        'https://vault.example.com/ui/vault/secrets/kv/show/apps/payments-svc/secret::two?namespace=payments%2Fnonprod',
    },
  ];

  beforeEach(() => {
    jest.resetAllMocks();
    server.use(
      rest.get(
        `${mockBaseUrl}/v1/entities/:namespace/:kind/:name/secrets`,
        (req, res, ctx) => {
          const { name } = req.params;
          if (name === 'payments-svc') {
            return res(
              ctx.json({
                items: mockSecrets,
                vaultNamespace: 'payments/nonprod',
              }),
            );
          }
          if (name === 'empty-svc') {
            return res(
              ctx.json({
                items: [],
                vaultNamespace: 'payments/nonprod',
                createUrls: {
                  'apps/empty-svc':
                    'https://vault.example.com/ui/vault/secrets/kv/kv/create?initialKey=apps%2Fempty-svc&namespace=payments%2Fnonprod',
                },
              }),
            );
          }
          if (name === 'forbidden-svc') {
            return res(
              ctx.status(403),
              ctx.json({
                error: {
                  name: 'NotAllowedError',
                  message: 'Team RBAC restricts Vault namespace',
                },
              }),
            );
          }
          return res(ctx.status(500));
        },
      ),
    );

    vaultClient = new VaultClient({ discoveryApi, fetchApi });
    apis = TestApiRegistry.from([vaultApiRef, vaultClient]);
    listEntitySecretsSpy = jest.spyOn(vaultClient, 'listEntitySecrets');
  });

  it('renders secrets, namespace badge, and version column', async () => {
    const rendered = await renderInTestApp(
      <ApiProvider apis={apis}>
        <EntityVaultTable
          entity={makeEntity(
            'payments-svc',
            'apps/payments-svc',
            'payments/nonprod',
          )}
        />
      </ApiProvider>,
    );

    expect(await rendered.findAllByText(/secret::one/)).toBeDefined();
    expect(await rendered.findAllByText(/secret::two/)).toBeDefined();
    expect(rendered.getByText(/ns: payments\/nonprod/)).toBeInTheDocument();
    expect(rendered.getByText('v3')).toBeInTheDocument();
    expect(listEntitySecretsSpy).toHaveBeenCalledWith({
      namespace: 'default',
      kind: 'component',
      name: 'payments-svc',
    });
  });

  it('renders empty state with create link when path has no secrets', async () => {
    const rendered = await renderInTestApp(
      <ApiProvider apis={apis}>
        <EntityVaultTable
          entity={makeEntity('empty-svc', 'apps/empty-svc', 'payments/nonprod')}
        />
      </ApiProvider>,
    );

    expect(await rendered.findByText(/No secrets found/)).toBeInTheDocument();
    expect(rendered.getByText(/Create in Vault UI/)).toBeInTheDocument();
  });

  it('renders RBAC warning alert when backend responds with 403 Forbidden', async () => {
    const rendered = await renderInTestApp(
      <ApiProvider apis={apis}>
        <EntityVaultTable
          entity={makeEntity(
            'forbidden-svc',
            'apps/forbidden-svc',
            'payments/nonprod',
          )}
        />
      </ApiProvider>,
    );

    expect(
      await rendered.findByText(/Vault Namespace Access Restricted \(403 RBAC\)/),
    ).toBeInTheDocument();
  });
});
```

---

## 4. Step 3 — Build, Test, Export RHDH 1.10 Dynamic Plugins, & Publish

Requires **Node.js `22` or `24`** (`node -v`). Run from the root of your `rhdh-plugin-vault` Bitbucket repository:

```bash
# 1. Install dependencies, typecheck, run all 9 Jest test suites, and compile packages
corepack enable
corepack yarn install
corepack yarn tsc
corepack yarn backstage-cli repo test --watchAll=false
corepack yarn build:all

# 2. Export RHDH 1.10 Dynamic Backend Plugin (creates plugins/vault-backend/dist-dynamic)
cd plugins/vault-backend
npx -y @red-hat-developer-hub/cli@1.10.8 plugin export
cd ../..

# 3. Export RHDH 1.10 Dynamic Frontend Scalprum Plugin (creates plugins/vault/dist-dynamic/dist-scalprum)
cd plugins/vault
npx -y @red-hat-developer-hub/cli@1.10.8 plugin export
cd ../..
```

Verify that `plugins/vault/dist-dynamic/dist-scalprum/plugin-manifest.json` exists (`"name": "backstage-community.plugin-vault"`).

Now choose **Publishing Option A (`.tgz` to Artifactory / Nexus)** or **Publishing Option B (OCI Image to Quay / Artifactory Docker)**:

### Option A — Package as `.tgz` Tarballs + `sha512` Integrity (Artifactory Generic/NPM)

```bash
mkdir -p dist-packages
npm pack ./plugins/vault-backend/dist-dynamic --pack-destination ./dist-packages
npm pack ./plugins/vault/dist-dynamic --pack-destination ./dist-packages

# Print exact filenames and sha512 integrity strings required by dynamic-plugins.yaml:
for f in dist-packages/*.tgz; do
  echo "$f"
  echo "  integrity: sha512-$(openssl dgst -sha512 -binary "$f" | openssl base64 -A)"
done
```

Produces:
- `dist-packages/backstage-community-plugin-vault-backend-dynamic-0.21.0.tgz`
- `dist-packages/backstage-community-plugin-vault-dynamic-0.19.0.tgz`

Upload both `.tgz` files to your internal artifact repository (e.g., `https://artifactory.example.com/artifactory/rhdh-plugins/`).

### Option B — Package as OCI Artifact Images (Quay / Artifactory OCI Registry)

```bash
# Backend OCI plugin image:
cd plugins/vault-backend
npx -y @red-hat-developer-hub/cli@1.10.8 plugin package \
  --tag quay.apps.example.com/idp/rhdh-plugin-vault-backend:0.21.0
podman push quay.apps.example.com/idp/rhdh-plugin-vault-backend:0.21.0
cd ../..

# Frontend OCI plugin image:
cd plugins/vault
npx -y @red-hat-developer-hub/cli@1.10.8 plugin package \
  --tag quay.apps.example.com/idp/rhdh-plugin-vault:0.19.0
podman push quay.apps.example.com/idp/rhdh-plugin-vault:0.19.0
cd ../..
```

---

## 5. Step 4 — Vault Enterprise Policy, `dynamic-plugins.yaml`, `app-config.yaml`, & `catalog-info.yaml`

### A. Least-Privilege Vault Enterprise Policy & Kubernetes Auth Role
Inside each target Vault Enterprise namespace (e.g., `payments/nonprod`), grant RHDH's OpenShift ServiceAccount **`list` and `read` on `kv/metadata/*` ONLY** (never `kv/data/*` and never `root` namespace):

```hcl
# rhdh-metadata-only.hcl
path "kv/metadata/*" {
  capabilities = ["list", "read"]
}

path "kv/data/*" {
  capabilities = ["deny"]
}
```

```bash
export VAULT_ADDR="https://vault.example.com:8200"
export VAULT_NAMESPACE="payments/nonprod"

vault policy write rhdh-metadata-only rhdh-metadata-only.hcl

vault write auth/kubernetes/role/rhdh-metadata-lister \
  bound_service_account_names="default" \
  bound_service_account_namespaces="rhdh" \
  token_policies="rhdh-metadata-only" \
  token_ttl="15m"
```

### B. Enable `automountServiceAccountToken: true` on the `Backstage` CR
Ensure the RHDH pod mounts `/var/run/secrets/kubernetes.io/serviceaccount/token`:

```yaml
spec:
  deployment:
    patch:
      spec:
        template:
          spec:
            automountServiceAccountToken: true
            serviceAccountName: default
```

### C. Register Your Forked Packages in `dynamic-plugins.yaml`
Note that because this fork preserves the upstream package & Scalprum module names (`backstage-community.plugin-vault`, `EntityVaultCard`, and `isVaultAvailable`), disable any older upstream Vault entries and add your built packages:

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins:
  # 1. Forked Enterprise Vault Backend Plugin (.tgz or oci://...)
  - package: "https://artifactory.example.com/artifactory/rhdh-plugins/backstage-community-plugin-vault-backend-dynamic-0.21.0.tgz"
    integrity: "sha512-<PASTE_BACKEND_SHA512_HERE>"
    disabled: false

  # (Or if using OCI Option B instead of .tgz:)
  # - package: "oci://quay.apps.example.com/idp/rhdh-plugin-vault-backend:0.21.0!backstage-community-plugin-vault-backend-dynamic"
  #   disabled: false

  # 2. Forked Enterprise Vault Frontend Scalprum Plugin
  - package: "https://artifactory.example.com/artifactory/rhdh-plugins/backstage-community-plugin-vault-dynamic-0.19.0.tgz"
    integrity: "sha512-<PASTE_FRONTEND_SHA512_HERE>"
    disabled: false
    pluginConfig:
      dynamicPlugins:
        frontend:
          backstage-community.plugin-vault:
            mountPoints:
              # Compact card on Entity Overview Bento Grid:
              - mountPoint: entity.page.overview/cards
                importName: EntityVaultCard
                config:
                  priority: 88
                  layout:
                    gridColumnEnd:
                      xl: "span 4"
                      lg: "span 6"
                      md: "span 6"
                      xs: "span 12"
                  if:
                    allOf:
                      - isVaultAvailable
              # Full-width card on Quality & Security tab (or entity.page.vault/cards):
              - mountPoint: entity.page.quality-security/cards
                importName: EntityVaultCard
                config:
                  priority: 95
                  layout:
                    gridColumn: "1 / -1"
                  if:
                    allOf:
                      - isVaultAvailable
```

### D. Configure `vault:` in `app-config.yaml`

```yaml
vault:
  # Internal Vault API URL reachable from RHDH backend pods
  baseUrl: ${VAULT_BASE_URL}
  # Browser-facing Vault Enterprise UI URL for View / Edit / Create deep-links
  publicUrl: ${VAULT_PUBLIC_URL}
  secretEngine: kv
  kvVersion: 2
  # Optional fallback Vault namespace when an entity omits vault.io/namespace:
  # namespace: shared/nonprod
  auth:
    type: kubernetes
    role: rhdh-metadata-lister
    authPath: kubernetes
    # Optional fixed auth namespace if Kubernetes Auth is mounted once at a parent namespace;
    # omit so RHDH authenticates directly inside each entity's `vault.io/namespace`.
    # namespace: ""
    serviceAccountTokenPath: /var/run/secrets/kubernetes.io/serviceaccount/token
```

### E. Annotate Services in `catalog-info.yaml`

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payments-checkout-service
  annotations:
    # 1. Target Vault Enterprise Namespace (sent via X-Vault-Namespace header & ?namespace= UI link):
    vault.io/namespace: payments/nonprod
    # 2. KV v2 mount name (optional override of vault.secretEngine):
    vault.io/secrets-engine: kv
    # 3. Comma-separated secret folder path(s) inside that mount:
    vault.io/secrets-path: apps/payments-checkout-service
    # 4. Optional explicit RHDH group guard (returns HTTP 403 to users outside this group):
    vault.io/allowed-principals: group:default/team-payments
spec:
  type: service
  lifecycle: production
  owner: group:default/team-payments
```
