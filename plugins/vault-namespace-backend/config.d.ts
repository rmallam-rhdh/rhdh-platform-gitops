export interface Config {
  vaultNamespace?: {
    /**
     * Internal Vault API URL (or Vault Enterprise Namespace gateway URL).
     * @visibility backend
     */
    baseUrl: string;

    /**
     * External Vault UI URL used to build `?namespace=<ns>` deep-links.
     * @visibility frontend
     */
    publicUrl?: string;

    /**
     * Default KV v2 engine mount inside each Vault Enterprise namespace.
     * @default "kv"
     */
    defaultMount?: string;

    /**
     * Kubernetes Auth settings for RHDH's Pod ServiceAccount (list/read metadata only).
     * @visibility backend
     */
    kubernetesAuth: {
      role: string;
      authPath?: string;
      serviceAccountTokenPath?: string;
    };
  };
}
