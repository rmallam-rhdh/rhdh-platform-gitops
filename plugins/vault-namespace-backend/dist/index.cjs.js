'use strict';

Object.defineProperty(exports, '__esModule', { value: true });

const fs = require('fs/promises');
const http = require('http');
const https = require('https');
const express = require('express');
const { createBackendPlugin, coreServices } = require('@backstage/backend-plugin-api');
const { catalogServiceRef } = require('@backstage/plugin-catalog-node');
const { catalogEntityReadPermission } = require('@backstage/plugin-catalog-common/alpha');
const { AuthorizeResult } = require('@backstage/plugin-permission-common');
const { stringifyEntityRef } = require('@backstage/catalog-model');

/**
 * Direct HTTP/HTTPS JSON helper so in-cluster Vault calls are never hijacked by
 * outbound corporate HTTP_PROXY settings.
 */
function requestJson(urlStr, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const lib = u.protocol === 'https:' ? https : http;
    const payload = body ? JSON.stringify(body) : undefined;
    const reqHeaders = {
      Accept: 'application/json',
      ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
      ...headers,
    };
    const req = lib.request(
      {
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || (u.protocol === 'https:' ? 443 : 80),
        path: `${u.pathname}${u.search}`,
        method,
        headers: reqHeaders,
        rejectUnauthorized: false,
      },
      res => {
        let raw = '';
        res.on('data', chunk => {
          raw += chunk;
        });
        res.on('end', () => {
          let parsed = null;
          try {
            parsed = raw ? JSON.parse(raw) : {};
          } catch {
            parsed = { raw };
          }
          resolve({ status: res.statusCode || 500, ok: (res.statusCode || 500) >= 200 && (res.statusCode || 500) < 300, data: parsed });
        });
      },
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

class EnterpriseVaultNamespaceClient {
  constructor(cfg, logger) {
    this.baseUrl = cfg.getString('vaultNamespace.baseUrl').replace(/\/+$/, '');
    this.publicUrl = (cfg.getOptionalString('vaultNamespace.publicUrl') || this.baseUrl).replace(/\/+$/, '');
    this.defaultMount = cfg.getOptionalString('vaultNamespace.defaultMount') || 'kv';
    this.role = cfg.getString('vaultNamespace.kubernetesAuth.role');
    this.authPath = cfg.getOptionalString('vaultNamespace.kubernetesAuth.authPath') || 'kubernetes';
    this.saTokenPath =
      cfg.getOptionalString('vaultNamespace.kubernetesAuth.serviceAccountTokenPath') ||
      '/var/run/secrets/kubernetes.io/serviceaccount/token';
    this.logger = logger;
    this.cachedToken = null;
    this.tokenExpiresAt = 0;
  }

  async getVaultToken() {
    const now = Date.now();
    if (this.cachedToken && now < this.tokenExpiresAt) {
      return this.cachedToken;
    }
    const jwt = (await fs.readFile(this.saTokenPath, 'utf8')).trim();
    const loginUrl = `${this.baseUrl}/v1/auth/${encodeURIComponent(this.authPath)}/login`;
    const res = await requestJson(loginUrl, {
      method: 'POST',
      body: { role: this.role, jwt },
    });
    if (!res.ok || !res.data?.auth?.client_token) {
      throw new Error(`Vault Kubernetes Auth login failed (HTTP ${res.status}): ${JSON.stringify(res.data?.errors || res.data)}`);
    }
    this.cachedToken = res.data.auth.client_token;
    const leaseSec = Number(res.data.auth.lease_duration || 300);
    this.tokenExpiresAt = now + Math.max(30, leaseSec - 60) * 1000;
    return this.cachedToken;
  }

  buildUiUrl(vaultNamespace, mount, entryPath) {
    const encodedPath = entryPath
      .split('/')
      .filter(Boolean)
      .map(encodeURIComponent)
      .join('%2F');
    return `${this.publicUrl}/ui/vault/secrets/${encodeURIComponent(mount)}/kv/${encodedPath}/details?namespace=${encodeURIComponent(vaultNamespace)}`;
  }

  async listSecretsRecursive(vaultNamespace, mount, prefixPath, depth = 0) {
    if (depth > 5) return [];
    const token = await this.getVaultToken();
    const cleanPrefix = prefixPath.replace(/^\/+|\/+$/g, '');
    const listUrl = `${this.baseUrl}/v1/${encodeURIComponent(mount)}/metadata/${cleanPrefix}?list=true`;
    const res = await requestJson(listUrl, {
      headers: {
        'X-Vault-Token': token,
        'X-Vault-Namespace': vaultNamespace,
      },
    });
    if (res.status === 404) {
      return [];
    }
    if (!res.ok) {
      const err = new Error(`Vault metadata list failed for namespace '${vaultNamespace}' path '${cleanPrefix}' (HTTP ${res.status})`);
      err.status = res.status;
      throw err;
    }

    const keys = Array.isArray(res.data?.data?.keys) ? res.data.data.keys : [];
    const results = [];
    for (const key of keys) {
      if (key.endsWith('/')) {
        const sub = await this.listSecretsRecursive(vaultNamespace, mount, `${cleanPrefix}/${key.slice(0, -1)}`, depth + 1);
        results.push(...sub);
      } else {
        const entryPath = `${cleanPrefix}/${key}`;
        let version = 1;
        let updatedTime = null;
        let keyCount = null;
        const metaUrl = `${this.baseUrl}/v1/${encodeURIComponent(mount)}/metadata/${entryPath}`;
        const metaRes = await requestJson(metaUrl, {
          headers: {
            'X-Vault-Token': token,
            'X-Vault-Namespace': vaultNamespace,
          },
        });
        if (metaRes.ok && metaRes.data?.data) {
          version = metaRes.data.data.current_version || 1;
          updatedTime = metaRes.data.data.updated_time || null;
        }
        results.push({
          name: key,
          path: entryPath,
          version,
          updatedTime,
          keyCount,
          vaultUiUrl: this.buildUiUrl(vaultNamespace, mount, entryPath),
        });
      }
    }
    return results;
  }
}

const vaultNamespaceBackendPlugin = createBackendPlugin({
  pluginId: 'vault-namespace',
  register(env) {
    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        httpRouter: coreServices.httpRouter,
        httpAuth: coreServices.httpAuth,
        userInfo: coreServices.userInfo,
        permissions: coreServices.permissions,
        catalog: catalogServiceRef,
      },
      async init({ logger, config, httpRouter, httpAuth, userInfo, permissions, catalog }) {
        const router = express.Router();
        router.use(express.json());

        router.get('/health', (_req, res) => {
          res.json({ status: 'ok', plugin: 'vault-namespace' });
        });

        if (!config.has('vaultNamespace')) {
          logger.warn('vaultNamespace config block missing; Vault Namespace backend routes will return 503');
          router.use((_req, res) => res.status(503).json({ error: 'vaultNamespace is not configured in app-config' }));
          httpRouter.use(router);
          httpRouter.addAuthPolicy({ path: '/health', allow: 'unauthenticated' });
          return;
        }

        const vaultClient = new EnterpriseVaultNamespaceClient(config, logger);
        logger.info(`Initialized Enterprise Vault Namespace backend -> ${vaultClient.baseUrl} (Kube Auth role=${vaultClient.role})`);

        router.get('/v1/entities/:namespace/:kind/:name/secrets', async (req, res) => {
          try {
            // 1. Authenticate calling RHDH human user
            const credentials = await httpAuth.credentials(req, { allow: ['user'] });
            const info = await userInfo.getUserInfo(credentials);

            // 2. Load Catalog Entity on behalf of caller (never accept arbitrary Vault paths from query params!)
            const { namespace, kind, name } = req.params;
            const entity = await catalog.getEntityByRef({ kind, namespace, name }, { credentials });
            if (!entity) {
              return res.status(404).json({
                error: 'EntityNotFound',
                message: `Entity ${kind}:${namespace}/${name} not found or hidden by Catalog RBAC.`,
              });
            }

            const entityRef = stringifyEntityRef(entity);

            // 3. Enforce Backstage PermissionsService (`catalog.entity.read` / conditional RBAC)
            const [decision] = await permissions.authorize(
              [{ permission: catalogEntityReadPermission, resourceRef: entityRef }],
              { credentials },
            );
            if (decision.result !== AuthorizeResult.ALLOW) {
              return res.status(403).json({
                error: 'RBACDenied',
                message: `Backstage RBAC denied ${info.userEntityRef} access to ${entityRef}.`,
                principal: info.userEntityRef,
              });
            }

            const annotations = entity.metadata?.annotations || {};
            const vaultNamespace = (annotations['vault.io/namespace'] || '').trim();
            const secretsPath = (annotations['vault.io/secrets-path'] || '').trim();
            const mount = (annotations['vault.io/secrets-engine'] || vaultClient.defaultMount).trim();
            const allowedPrincipalsRaw = (annotations['vault.io/allowed-principals'] || '').trim();

            if (!vaultNamespace || !secretsPath) {
              return res.status(400).json({
                error: 'MissingAnnotations',
                message: 'Component requires both vault.io/namespace and vault.io/secrets-path annotations.',
              });
            }

            // 4. Enforce optional explicit Team / Vault-Namespace principal guard (`vault.io/allowed-principals`)
            if (allowedPrincipalsRaw) {
              const allowedPrincipals = allowedPrincipalsRaw
                .split(',')
                .map(s => s.trim().toLowerCase())
                .filter(Boolean);
              const callerRefs = (info.ownershipEntityRefs || [info.userEntityRef]).map(s => s.toLowerCase());
              const matched = allowedPrincipals.some(ap => callerRefs.includes(ap));
              if (!matched) {
                logger.warn(
                  `Vault Namespace RBAC denied ${info.userEntityRef} (${callerRefs.join(',')}) for namespace '${vaultNamespace}' on ${entityRef}`,
                );
                return res.status(403).json({
                  error: 'VaultNamespaceRBACDenied',
                  message: `Team RBAC policy restricts Vault namespace '${vaultNamespace}' to [${allowedPrincipalsRaw}].`,
                  vaultNamespace,
                  principal: info.userEntityRef,
                  callerGroups: info.ownershipEntityRefs || [],
                  requiredPrincipals: allowedPrincipalsRaw.split(',').map(s => s.trim()),
                });
              }
            }

            // 5. Query Vault metadata using Kubernetes Auth + X-Vault-Namespace (metadata only, zero secret values!)
            const paths = secretsPath
              .split(',')
              .map(s => s.trim())
              .filter(Boolean);
            const allItems = [];
            for (const p of paths) {
              const items = await vaultClient.listSecretsRecursive(vaultNamespace, mount, p);
              allItems.push(...items);
            }

            const namespaceUiUrl = `${vaultClient.publicUrl}/ui/vault/secrets/${encodeURIComponent(mount)}/kv/list?namespace=${encodeURIComponent(vaultNamespace)}`;

            return res.json({
              entityRef,
              vaultNamespace,
              secretEngine: mount,
              secretsPath,
              authMethod: 'kubernetes',
              kubernetesRole: vaultClient.role,
              principal: info.userEntityRef,
              rbacStatus: 'ALLOW',
              namespaceUiUrl,
              items: allItems,
            });
          } catch (err) {
            logger.error(`Vault Namespace plugin error: ${err.message}`);
            const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 500;
            return res.status(status).json({
              error: 'VaultBackendError',
              message: err.message || 'Failed to query Vault metadata',
            });
          }
        });

        httpRouter.use(router);
        httpRouter.addAuthPolicy({
          path: '/health',
          allow: 'unauthenticated',
        });
      },
    });
  },
});

exports.vaultNamespaceBackendPlugin = vaultNamespaceBackendPlugin;
exports.default = vaultNamespaceBackendPlugin;
