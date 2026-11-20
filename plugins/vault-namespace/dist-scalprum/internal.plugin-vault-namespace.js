/* Enterprise Vault Namespace Dynamic Frontend Plugin for RHDH 1.10 (Scalprum) */
__load_plugin_entry__(
  "internal.plugin-vault-namespace",
  (function () {
    "use strict";

    var shareScopeRef = null;
    var cachedFactoryPromise = null;

    function resolveShared(pkgName) {
      var root = shareScopeRef || {};
      var scope = root[pkgName] ? root : root.default || {};
      var versions = scope[pkgName];
      if (!versions) {
        return Promise.reject(
          new Error("Shared singleton '" + pkgName + "' not found in Scalprum shareScope")
        );
      }
      var verKeys = Object.keys(versions).sort();
      var chosen = versions[verKeys[verKeys.length - 1]];
      return Promise.resolve(chosen.get()).then(function (factory) {
        var mod = factory();
        return mod && mod.__esModule && mod.default ? mod : mod;
      });
    }

    function parseEntityFromLocation() {
      var path = (window.location && window.location.pathname) || "";
      var m = path.match(/\/catalog\/([^/]+)\/([^/]+)\/([^/]+)/);
      if (!m) {
        return { namespace: "default", kind: "component", name: "" };
      }
      return {
        namespace: decodeURIComponent(m[1]),
        kind: decodeURIComponent(m[2]),
        name: decodeURIComponent(m[3]),
      };
    }

    function isVaultNamespaceAvailable(entity) {
      var ann = (entity && entity.metadata && entity.metadata.annotations) || {};
      return Boolean(ann["vault.io/namespace"] && ann["vault.io/secrets-path"]);
    }

    function createPluginExports(ReactMod, coreApi) {
      var React = ReactMod.default || ReactMod;
      var h = React.createElement;

      function Badge(props) {
        return h(
          "span",
          {
            style: {
              display: "inline-flex",
              alignItems: "center",
              gap: "4px",
              padding: "2px 8px",
              borderRadius: "999px",
              fontSize: "0.72rem",
              fontWeight: 600,
              letterSpacing: "0.02em",
              background: props.bg,
              color: props.fg,
              border: "1px solid " + props.border,
              whiteSpace: "nowrap",
            },
          },
          props.text
        );
      }

      function VaultNamespaceCardInner() {
        var discoveryApi = coreApi.useApi(coreApi.discoveryApiRef);
        var fetchApi = coreApi.useApi(coreApi.fetchApiRef);
        var routeEntity = parseEntityFromLocation();

        var stateTuple = React.useState({
          loading: true,
          status: 0,
          data: null,
          error: null,
        });
        var state = stateTuple[0];
        var setState = stateTuple[1];

        React.useEffect(
          function () {
            var cancelled = false;
            if (!routeEntity.name) {
              setState({ loading: false, status: 400, data: null, error: "No entity in route" });
              return undefined;
            }
            setState({ loading: true, status: 0, data: null, error: null });
            discoveryApi
              .getBaseUrl("vault-namespace")
              .then(function (baseUrl) {
                var url =
                  baseUrl +
                  "/v1/entities/" +
                  encodeURIComponent(routeEntity.namespace) +
                  "/" +
                  encodeURIComponent(routeEntity.kind) +
                  "/" +
                  encodeURIComponent(routeEntity.name) +
                  "/secrets";
                return fetchApi.fetch(url);
              })
              .then(function (res) {
                return res.json().then(function (body) {
                  return { ok: res.ok, status: res.status, body: body };
                });
              })
              .then(function (resObj) {
                if (cancelled) return;
                if (resObj.ok) {
                  setState({ loading: false, status: resObj.status, data: resObj.body, error: null });
                } else {
                  setState({
                    loading: false,
                    status: resObj.status,
                    data: resObj.body || null,
                    error: (resObj.body && resObj.body.message) || "Request denied",
                  });
                }
              })
              .catch(function (err) {
                if (cancelled) return;
                setState({
                  loading: false,
                  status: 500,
                  data: null,
                  error: err && err.message ? err.message : String(err),
                });
              });
            return function () {
              cancelled = true;
            };
          },
          [routeEntity.namespace, routeEntity.kind, routeEntity.name]
        );

        var nsLabel =
          (state.data && state.data.vaultNamespace) ||
          (state.loading ? "resolving..." : "restricted");
        var isDenied = state.status === 403;

        return h(
          "div",
          {
            className: "MuiPaper-root MuiPaper-outlined MuiPaper-rounded MuiCard-root",
            style: {
              borderRadius: "12px",
              display: "flex",
              flexDirection: "column",
              height: "100%",
              overflow: "hidden",
            },
          },
          h(
            "div",
            {
              className: "MuiCardHeader-root",
              style: {
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                gap: "8px",
                flexWrap: "wrap",
                padding: "10px 16px",
                borderBottom: "1px solid rgba(148, 163, 184, 0.2)",
              },
            },
            h(
              "div",
              { style: { display: "flex", alignItems: "center", gap: "8px" } },
              h(
                "span",
                {
                  className: "MuiTypography-root MuiCardHeader-title",
                  style: { fontSize: "0.95rem", fontWeight: 600 },
                },
                "Vault Enterprise Secrets"
              ),
              h(Badge, {
                text: "ns: " + nsLabel,
                bg: "rgba(56, 189, 248, 0.14)",
                fg: "#38BDF8",
                border: "rgba(56, 189, 248, 0.35)",
              })
            ),
            isDenied
              ? h(Badge, {
                  text: "403 RBAC Restricted",
                  bg: "rgba(248, 113, 113, 0.14)",
                  fg: "#F87171",
                  border: "rgba(248, 113, 113, 0.35)",
                })
              : h(Badge, {
                  text: "Kube Auth \u00b7 RBAC Verified",
                  bg: "rgba(52, 211, 153, 0.14)",
                  fg: "#34D399",
                  border: "rgba(52, 211, 153, 0.35)",
                })
          ),
          h(
            "div",
            {
              className: "MuiCardContent-root",
              style: {
                padding: "12px 16px",
                overflowY: "auto",
                flexGrow: 1,
                fontSize: "0.82rem",
              },
            },
            state.loading
              ? h("div", { style: { opacity: 0.75, padding: "8px 0" } }, "Authenticating via Kubernetes SA JWT & checking Team RBAC...")
              : isDenied
              ? h(
                  "div",
                  {
                    style: {
                      padding: "10px 12px",
                      borderRadius: "8px",
                      background: "rgba(248, 113, 113, 0.10)",
                      border: "1px solid rgba(248, 113, 113, 0.30)",
                      lineHeight: 1.45,
                    },
                  },
                  h(
                    "div",
                    { style: { fontWeight: 600, color: "#F87171", marginBottom: "4px" } },
                    "Access Restricted by Vault Namespace RBAC"
                  ),
                  h("div", { style: { opacity: 0.9 } }, state.error),
                  state.data && state.data.principal
                    ? h(
                        "div",
                        { style: { marginTop: "6px", fontSize: "0.75rem", opacity: 0.75 } },
                        "Caller: " + state.data.principal + " \u2014 Zero Vault API calls executed."
                      )
                    : null
                )
              : state.error
              ? h("div", { style: { color: "#F87171" } }, state.error)
              : h(
                  "div",
                  null,
                  !state.data || !state.data.items || state.data.items.length === 0
                    ? h("div", { style: { opacity: 0.75 } }, "No secret metadata entries found under path '" + (state.data && state.data.secretsPath) + "'.")
                    : h(
                        "table",
                        {
                          style: {
                            width: "100%",
                            borderCollapse: "collapse",
                            fontSize: "0.8rem",
                          },
                        },
                        h(
                          "thead",
                          null,
                          h(
                            "tr",
                            { style: { textAlign: "left", opacity: 0.72, borderBottom: "1px solid rgba(148, 163, 184, 0.2)" } },
                            h("th", { style: { padding: "4px 6px" } }, "Secret Path (Metadata Only)"),
                            h("th", { style: { padding: "4px 6px" } }, "Ver"),
                            h("th", { style: { padding: "4px 6px", textAlign: "right" } }, "Vault UI")
                          )
                        ),
                        h(
                          "tbody",
                          null,
                          state.data.items.map(function (item) {
                            return h(
                              "tr",
                              {
                                key: item.path,
                                style: { borderBottom: "1px solid rgba(148, 163, 184, 0.12)" },
                              },
                              h(
                                "td",
                                {
                                  style: {
                                    padding: "6px",
                                    fontFamily: "RedHatMono, monospace",
                                    fontSize: "0.76rem",
                                  },
                                },
                                item.path
                              ),
                              h("td", { style: { padding: "6px", opacity: 0.85 } }, "v" + (item.version || 1)),
                              h(
                                "td",
                                { style: { padding: "6px", textAlign: "right" } },
                                h(
                                  "a",
                                  {
                                    href: item.vaultUiUrl,
                                    target: "_blank",
                                    rel: "noopener noreferrer",
                                    style: {
                                      color: "#60A5FA",
                                      textDecoration: "none",
                                      fontWeight: 600,
                                      fontSize: "0.76rem",
                                    },
                                  },
                                  "Open \u2197"
                                )
                              )
                            );
                          })
                        )
                      )
                )
          )
        );
      }

      var vaultNamespacePlugin = coreApi.createPlugin({
        id: "vault-namespace",
      });

      var EntityVaultNamespaceCard = vaultNamespacePlugin.provide(
        coreApi.createComponentExtension({
          name: "EntityVaultNamespaceCard",
          component: {
            sync: VaultNamespaceCardInner,
          },
        })
      );

      return {
        __esModule: true,
        default: vaultNamespacePlugin,
        vaultNamespacePlugin: vaultNamespacePlugin,
        EntityVaultNamespaceCard: EntityVaultNamespaceCard,
        isVaultNamespaceAvailable: isVaultNamespaceAvailable,
      };
    }

    function getPluginRootFactory() {
      if (!cachedFactoryPromise) {
        cachedFactoryPromise = Promise.all([
          resolveShared("react"),
          resolveShared("@backstage/core-plugin-api"),
        ]).then(function (mods) {
          var exported = createPluginExports(mods[0], mods[1]);
          return function () {
            return exported;
          };
        });
      }
      return cachedFactoryPromise;
    }

    return {
      init: function (shareScope) {
        shareScopeRef = shareScope;
        return Promise.resolve();
      },
      get: function (module) {
        if (module === "PluginRoot" || module === "./PluginRoot" || module === ".") {
          return getPluginRootFactory();
        }
        return Promise.reject(new Error("Unknown exposed module: " + module));
      },
    };
  })()
);
