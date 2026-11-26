/* RHDH 1.10 ScmAuth API Factory Dynamic Frontend Plugin (Adds Bitbucket Data Center / bitbucketServer OAuth support) */
__load_plugin_entry__(
  "internal.plugin-bitbucket-server-scmauth",
  (function () {
    "use strict";

    function makeApiRef(id) {
      return {
        id: id,
        toString: function () {
          return "apiRef{" + id + "}";
        },
      };
    }

    var scmAuthApiRef = makeApiRef("core.scmauth");
    var githubAuthApiRef = makeApiRef("core.auth.github");
    var gitlabAuthApiRef = makeApiRef("core.auth.gitlab");
    var microsoftAuthApiRef = makeApiRef("core.auth.microsoft");
    var bitbucketAuthApiRef = makeApiRef("core.auth.bitbucket");
    var bitbucketServerAuthApiRef = makeApiRef("core.auth.bitbucket-server");
    var configApiRef = makeApiRef("core.config");

    function createScmAuthEntry(providerName, authApi, host, scopeMapping) {
      return {
        isUrlSupported: function (url) {
          return url && url.host === host;
        },
        getCredentials: function (options) {
          var additionalScope = (options && options.additionalScope) || {};
          var restOptions = {};
          if (options) {
            Object.keys(options).forEach(function (k) {
              if (k !== "url" && k !== "additionalScope") {
                restOptions[k] = options[k];
              }
            });
          }

          var scopes = (scopeMapping.default || []).slice();
          if (additionalScope.repoWrite && scopeMapping.repoWrite) {
            scopes.push.apply(scopes, scopeMapping.repoWrite);
          }

          var customScopes = additionalScope.customScopes || {};
          var extra =
            customScopes[providerName] ||
            (providerName === "bitbucketServer" ? customScopes.bitbucket : null) ||
            [];
          if (extra && extra.length) {
            scopes.push.apply(scopes, extra);
          }

          var uniqueScopes = [];
          scopes.forEach(function (s) {
            if (uniqueScopes.indexOf(s) === -1) {
              uniqueScopes.push(s);
            }
          });

          return Promise.resolve(authApi.getAccessToken(uniqueScopes, restOptions)).then(
            function (token) {
              return {
                token: token,
                headers: {
                  Authorization: "Bearer " + token,
                },
              };
            }
          );
        },
      };
    }

    function createScmAuthMux(providers) {
      return {
        getCredentials: function (options) {
          var url = new URL(options.url);
          var match = null;
          for (var i = 0; i < providers.length; i++) {
            if (providers[i].isUrlSupported(url)) {
              match = providers[i];
              break;
            }
          }
          if (!match) {
            return Promise.reject(
              new Error(
                "No auth provider available for '" +
                  options.url +
                  "', see https://backstage.io/link?scm-auth"
              )
            );
          }
          return match.getCredentials(options);
        },
      };
    }

    var SCOPE_MAPPINGS = {
      github: {
        defaultHost: "github.com",
        default: ["repo", "read:org", "read:user"],
        repoWrite: ["gist"],
      },
      gitlab: {
        defaultHost: "gitlab.com",
        default: ["read_user", "read_api", "read_repository"],
        repoWrite: ["write_repository", "api"],
      },
      azure: {
        defaultHost: "dev.azure.com",
        default: [
          "499b84ac-1321-427f-aa17-267ca6975798/vso.build",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.code",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.graph",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.project",
          "499b84ac-1321-427f-aa17-267ca6975798/vso.profile",
        ],
        repoWrite: ["499b84ac-1321-427f-aa17-267ca6975798/vso.code_manage"],
      },
      bitbucket: {
        defaultHost: "bitbucket.org",
        default: ["account", "team", "pullrequest", "snippet", "issue", "project"],
        repoWrite: ["pullrequest:write", "snippet:write", "issue:write"],
      },
      bitbucketServer: {
        defaultHost: null,
        default: ["PUBLIC_REPOS", "REPO_READ"],
        repoWrite: ["REPO_WRITE", "PROJECT_ADMIN"],
      },
    };

    var scmAuthApi = {
      api: scmAuthApiRef,
      deps: {
        github: githubAuthApiRef,
        gitlab: gitlabAuthApiRef,
        azure: microsoftAuthApiRef,
        bitbucket: bitbucketAuthApiRef,
        bitbucketServer: bitbucketServerAuthApiRef,
        configApi: configApiRef,
      },
      factory: function (deps) {
        var providerDefs = [
          { key: "github", ref: deps.github, mapping: SCOPE_MAPPINGS.github },
          { key: "gitlab", ref: deps.gitlab, mapping: SCOPE_MAPPINGS.gitlab },
          { key: "azure", ref: deps.azure, mapping: SCOPE_MAPPINGS.azure },
          { key: "bitbucket", ref: deps.bitbucket, mapping: SCOPE_MAPPINGS.bitbucket },
          {
            key: "bitbucketServer",
            ref: deps.bitbucketServer,
            mapping: SCOPE_MAPPINGS.bitbucketServer,
          },
        ];

        var entries = [];
        providerDefs.forEach(function (def) {
          var configs =
            deps.configApi.getOptionalConfigArray("integrations." + def.key) || [];
          if (!configs.length) {
            if (def.mapping.defaultHost) {
              entries.push(
                createScmAuthEntry(def.key, def.ref, def.mapping.defaultHost, def.mapping)
              );
            }
            return;
          }
          configs.forEach(function (c) {
            var host = c.getString("host");
            entries.push(createScmAuthEntry(def.key, def.ref, host, def.mapping));
          });
        });

        return createScmAuthMux(entries);
      },
    };

    var exportedModule = {
      __esModule: true,
      default: scmAuthApi,
      scmAuthApi: scmAuthApi,
    };

    return {
      init: function () {
        return Promise.resolve();
      },
      get: function (module) {
        if (module === "PluginRoot" || module === "./PluginRoot" || module === ".") {
          return Promise.resolve(function () {
            return exportedModule;
          });
        }
        return Promise.reject(new Error("Unknown exposed module: " + module));
      },
    };
  })()
);
