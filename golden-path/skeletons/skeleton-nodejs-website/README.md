# ${{ values.appName }}

${{ values.appDescription }}

Catalog: **Component** (website) `${{ values.appName }}` **consumesApis** `${{ values.backendApiName }}` and **dependsOn** `${{ values.backendServiceRef }}` in system `${{ values.systemName }}`.

| Piece | Path |
|---|---|
| App | `server.js` (`GET /health`, page calls backend `/api`) |
| Tests | `npm test` / `npm run lint` |
| Sonar | `sonar-project.properties` |
| CI | `Jenkinsfile` |
| Deploy | `chart/` (Helm + OSSM: Route → Gateway → HTTPRoute, deny-all, STRICT mTLS) |
| IDE | `devfile.yaml` |

```bash
BACKEND_URL=${{ values.backendUrl }} npm start
npm run lint
npm test
helm lint chart
```
