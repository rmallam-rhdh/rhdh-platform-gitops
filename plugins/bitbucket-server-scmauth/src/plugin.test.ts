import { ConfigReader } from '@backstage/config';
import { OAuthApi } from '@backstage/core-plugin-api';
import { bitbucketServerScmAuthPlugin, scmAuthApi } from './plugin';

function createMockOAuthApi(token: string): jest.Mocked<OAuthApi> {
  return {
    getAccessToken: jest.fn().mockResolvedValue(token),
  };
}

describe('bitbucket-server-scmauth plugin', () => {
  it('exports the plugin and scmAuthApi factory', () => {
    expect(bitbucketServerScmAuthPlugin.getId()).toBe(
      'bitbucket-server-scmauth',
    );
    expect(scmAuthApi.api.id).toBe('core.scmauth');
  });

  it('resolves Bitbucket Data Center read and repoWrite credentials from bitbucketServerAuthApiRef', async () => {
    const github = createMockOAuthApi('gh-token');
    const gitlab = createMockOAuthApi('gl-token');
    const azure = createMockOAuthApi('az-token');
    const bitbucket = createMockOAuthApi('bb-cloud-token');
    const bitbucketServer = createMockOAuthApi('bb-dc-oauth-token');

    const configApi = new ConfigReader({
      integrations: {
        bitbucketServer: [
          {
            host: 'bitbucket.example.com',
            apiBaseUrl: 'https://bitbucket.example.com/rest/api/1.0',
          },
        ],
      },
    });

    const instance = scmAuthApi.factory({
      github: github as any,
      gitlab: gitlab as any,
      azure: azure as any,
      bitbucket: bitbucket as any,
      bitbucketServer: bitbucketServer as any,
      configApi,
    });

    // 1. Default read scopes
    const readCreds = await instance.getCredentials({
      url: 'https://bitbucket.example.com/scm/idp/orders-service.git',
    });
    expect(readCreds).toEqual({
      token: 'bb-dc-oauth-token',
      headers: { Authorization: 'Bearer bb-dc-oauth-token' },
    });
    expect(bitbucketServer.getAccessToken).toHaveBeenCalledWith(
      ['PUBLIC_REPOS', 'REPO_READ'],
      {},
    );

    // 2. Scaffolder repoWrite + customScopes.bitbucket
    await instance.getCredentials({
      url: 'https://bitbucket.example.com/projects/IDP/repos/orders-service',
      additionalScope: {
        repoWrite: true,
        customScopes: {
          bitbucket: ['REPO_ADMIN'],
        },
      },
    });
    expect(bitbucketServer.getAccessToken).toHaveBeenLastCalledWith(
      ['PUBLIC_REPOS', 'REPO_READ', 'REPO_WRITE', 'PROJECT_ADMIN', 'REPO_ADMIN'],
      {},
    );
  });

  it('supports overriding Bitbucket Server OAuth scopes via app-config without code changes', async () => {
    const bitbucketServer = createMockOAuthApi('bb-custom-scope-token');
    const configApi = new ConfigReader({
      auth: {
        bitbucketServer: {
          scopeMapping: {
            default: ['PUBLIC_REPOS', 'REPO_READ'],
            repoWrite: ['REPO_WRITE'],
          },
        },
      },
      integrations: {
        bitbucketServer: [{ host: 'bitbucket.example.com' }],
      },
    });

    const instance = scmAuthApi.factory({
      github: createMockOAuthApi('gh') as any,
      gitlab: createMockOAuthApi('gl') as any,
      azure: createMockOAuthApi('az') as any,
      bitbucket: createMockOAuthApi('bb') as any,
      bitbucketServer: bitbucketServer as any,
      configApi,
    });

    await instance.getCredentials({
      url: 'https://bitbucket.example.com/scm/idp/demo.git',
      additionalScope: { repoWrite: true },
    });
    expect(bitbucketServer.getAccessToken).toHaveBeenCalledWith(
      ['PUBLIC_REPOS', 'REPO_READ', 'REPO_WRITE'],
      {},
    );
  });

  it('preserves default GitHub, GitLab, Azure, and Bitbucket Cloud providers', async () => {
    const github = createMockOAuthApi('gh-token');
    const instance = scmAuthApi.factory({
      github: github as any,
      gitlab: createMockOAuthApi('gl') as any,
      azure: createMockOAuthApi('az') as any,
      bitbucket: createMockOAuthApi('bb') as any,
      bitbucketServer: createMockOAuthApi('bbs') as any,
      configApi: new ConfigReader({}),
    });

    const ghCreds = await instance.getCredentials({
      url: 'https://github.com/acme/demo-service',
    });
    expect(ghCreds.token).toBe('gh-token');
    expect(github.getAccessToken).toHaveBeenCalledWith(
      ['repo', 'read:org', 'read:user'],
      {},
    );

    await expect(
      instance.getCredentials({ url: 'https://unknown-git.example.com/a/b' }),
    ).rejects.toThrow(
      "No auth provider available for 'https://unknown-git.example.com/a/b'",
    );
  });
});
