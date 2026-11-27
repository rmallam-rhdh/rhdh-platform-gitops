import {
  bitbucketAuthApiRef,
  bitbucketServerAuthApiRef,
  ConfigApi,
  configApiRef,
  createApiFactory,
  createPlugin,
  githubAuthApiRef,
  gitlabAuthApiRef,
  microsoftAuthApiRef,
} from '@backstage/core-plugin-api';
import { ScmAuth, scmAuthApiRef } from '@backstage/integration-react';

const DEFAULT_BITBUCKET_SERVER_READ_SCOPES = ['PUBLIC_REPOS', 'REPO_READ'];
const DEFAULT_BITBUCKET_SERVER_WRITE_SCOPES = ['REPO_WRITE', 'PROJECT_ADMIN'];

function getConfiguredHosts(
  configApi: ConfigApi,
  configPaths: string[],
  defaultHost?: string,
): string[] {
  const hosts = new Set<string>();

  for (const path of configPaths) {
    const entries = configApi.getOptionalConfigArray(path) ?? [];
    for (const entry of entries) {
      const host = entry.getOptionalString('host') ?? defaultHost;
      if (host) {
        hosts.add(host);
      }
    }
  }

  if (hosts.size === 0 && defaultHost) {
    hosts.add(defaultHost);
  }

  return Array.from(hosts);
}

/**
 * Dynamic RHDH / Backstage `scmAuthApiRef` factory that preserves all built-in
 * SCM OAuth providers (`github`, `gitlab`, `azure`, `bitbucket` Cloud) while
 * registering every configured `integrations.bitbucketServer` Data Center host
 * against `bitbucketServerAuthApiRef`.
 *
 * Scopes requested for Bitbucket Data Center default to:
 * - Read (`default`): `['PUBLIC_REPOS', 'REPO_READ']`
 * - Write (`repoWrite`): `['REPO_WRITE', 'PROJECT_ADMIN']`
 * and can optionally be overridden via `auth.bitbucketServer.scopeMapping` in
 * `app-config.yaml` without rebuilding the plugin.
 *
 * @public
 */
export const scmAuthApi = createApiFactory({
  api: scmAuthApiRef,
  deps: {
    github: githubAuthApiRef,
    gitlab: gitlabAuthApiRef,
    azure: microsoftAuthApiRef,
    bitbucket: bitbucketAuthApiRef,
    bitbucketServer: bitbucketServerAuthApiRef,
    configApi: configApiRef,
  },
  factory: ({
    github,
    gitlab,
    azure,
    bitbucket,
    bitbucketServer,
    configApi,
  }) => {
    const bitbucketServerDefaultScopes =
      configApi.getOptionalStringArray(
        'auth.bitbucketServer.scopeMapping.default',
      ) ?? DEFAULT_BITBUCKET_SERVER_READ_SCOPES;

    const bitbucketServerRepoWriteScopes =
      configApi.getOptionalStringArray(
        'auth.bitbucketServer.scopeMapping.repoWrite',
      ) ?? DEFAULT_BITBUCKET_SERVER_WRITE_SCOPES;

    const providers: ScmAuth[] = [
      ...getConfiguredHosts(
        configApi,
        ['integrations.github'],
        'github.com',
      ).map(host => ScmAuth.forGithub(github, { host })),

      ...getConfiguredHosts(
        configApi,
        ['integrations.gitlab'],
        'gitlab.com',
      ).map(host => ScmAuth.forGitlab(gitlab, { host })),

      ...getConfiguredHosts(
        configApi,
        ['integrations.azure'],
        'dev.azure.com',
      ).map(host => ScmAuth.forAzure(azure, { host })),

      ...getConfiguredHosts(
        configApi,
        ['integrations.bitbucketCloud', 'integrations.bitbucket'],
        'bitbucket.org',
      ).map(host => ScmAuth.forBitbucket(bitbucket, { host })),

      ...getConfiguredHosts(configApi, ['integrations.bitbucketServer']).map(
        host =>
          ScmAuth.forBitbucketServer(bitbucketServer, {
            host,
            scopeMapping: {
              default: bitbucketServerDefaultScopes,
              repoWrite: bitbucketServerRepoWriteScopes,
            },
          }),
      ),
    ];

    return ScmAuth.merge(...providers);
  },
});

/**
 * Dynamic frontend plugin wrapper for RHDH / Backstage.
 *
 * @public
 */
export const bitbucketServerScmAuthPlugin = createPlugin({
  id: 'bitbucket-server-scmauth',
  apis: [scmAuthApi],
});
