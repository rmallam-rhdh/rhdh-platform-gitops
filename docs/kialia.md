oc exec -n rhdh deploy/backstage-developer-hub -c backstage-backend -- sh -c "
  echo '=== Step 1: Check Kiali Auth Strategy (/api/auth/info) ==='
  curl -sk https://kiali.istio-system.svc:20001/api/auth/info && echo ''
  echo '=== Step 2: Authenticate with ServiceAccount Token (POST /api/authenticate) ==='
  curl -sk -i -c /tmp/kiali.cookie \
    -H 'X-Auth-Type-Kiali-UI: 1' \
    --data-urlencode \"token=${SA_TOKEN}\" \
    https://kiali.istio-system.svc:20001/api/authenticate
  echo ''
  echo '=== Step 3: Query Kiali Namespaces & Istio Config Using Session Cookie ==='
  curl -sk -b /tmp/kiali.cookie https://kiali.istio-system.svc:20001/api/namespaces
  echo ''
"
