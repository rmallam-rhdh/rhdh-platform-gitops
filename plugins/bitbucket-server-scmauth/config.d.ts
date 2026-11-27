export interface Config {
  auth?: {
    bitbucketServer?: {
      /**
       * Optional OAuth 2.0 scope overrides for Bitbucket Data Center ScmAuth.
       *
       * @visibility frontend
       */
      scopeMapping?: {
        /**
         * Default read scopes requested by ScmAuth for Bitbucket Data Center.
         * Defaults to `['PUBLIC_REPOS', 'REPO_READ']`.
         *
         * @visibility frontend
         */
        default?: string[];

        /**
         * Additional write scopes requested when `repoWrite: true` is set
         * (for example, Scaffolder repository creation and Pull Requests).
         * Defaults to `['REPO_WRITE', 'PROJECT_ADMIN']`.
         *
         * @visibility frontend
         */
        repoWrite?: string[];
      };
    };
  };
}
