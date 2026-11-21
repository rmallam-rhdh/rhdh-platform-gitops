# ${{ values.appName }}

${{ values.appDescription }}

Catalog: **System** `${{ values.systemName }}` ← **Component** (service) `${{ values.appName }}` **providesApis** `${{ values.appName }}-api`.

| Piece | Path |
|---|---|
| App | `GET /health`, `GET /api` |
| Tests | `mvn test` |
| Sonar | `sonar-project.properties` |
| CI | `Jenkinsfile` |
| Deploy | `chart/` (Helm + OSSM: Route → Gateway → HTTPRoute, deny-all, STRICT mTLS) |
| IDE | `devfile.yaml` |

```bash
mvn -q test
helm lint chart
```
