# Edge protection (optional)

Rate limiting and DDoS / abuse protection for every site served by the AIO Traefik ingress. Nothing here is on
by default. There are three layers, and each one can be used without the next.

| Layer | What it stops | Cost | Files |
| --- | --- | --- | --- |
| 1. Edge flood guard | One source sending a request flood or holding hundreds of slow requests open (429 above 100 req/s sustained, 300 burst, 200 open requests per IP) | none (built into Traefik) | `middlewares.yaml`, `traefik-values.yaml` |
| 2. CrowdSec bans | Scanners, brute force, CVE probes, crawlers and repeat flooders, plus IPs on the CrowdSec community blocklist; banned IPs get 403 at the edge | ~0.1 vCPU, ~350 MiB on a 2-node cluster | `crowdsec` connector, `bouncer-middleware.yaml`, `traefik-crowdsec-values.yaml` |
| 3. Per-app limits | Tighter limits for one app (login, API, forms) | none | app chart `rateLimit` (aio-gitops `helm/app`) |

What this cannot stop: volumetric network floods (many Gbit/s) saturate the load balancer before any request
reaches Traefik. On Azure the public IP already has the free DDoS infrastructure protection; the paid Azure DDoS IP
Protection (about USD 199 per IP per month) or a CDN/WAF in front (for example Cloudflare) is the answer there.

## Layer 1: edge flood guard

Status on sarvaikam (AKS): ON since 2026-11-18 (Traefik release revision 10). All 23 hosts answered as before;
a 1,500-request burst from one IP got 273 x 429 and the site answered 200 seconds later.


```bash
# CATALOG=path to this repo. Build on the LIVE values (helm get values), not on files that may be stale:
# an upgrade from an old values file can drop plugins, namespaces or the public load balancer.
helm -n aio-ingress get values aio-azure-ingress -o yaml > live-ingress-values.yaml
kubectl apply -f $CATALOG/extras/edge-protection/middlewares.yaml      # first: the overlay refers to these
helm upgrade aio-azure-ingress traefik --repo https://traefik.github.io/charts --version 42.4.0 -n aio-ingress   -f live-ingress-values.yaml -f $CATALOG/extras/edge-protection/traefik-values.yaml --wait
```

Check: sites still answer, then a burst from one machine gets 429:

```bash
for i in $(seq 1 600); do curl -s -o /dev/null -w '%{http_code}\n' https://app.sarvaikam.com/ & done | sort | uniq -c
```

Turning on `externalTrafficPolicy: Local` changes the load balancer rule: expect a few seconds of failed
connections while the cloud updates its health probe. Roll back with `helm rollback aio-azure-ingress -n aio-ingress`
(then `kubectl delete -f middlewares.yaml`).

## Layer 2: CrowdSec bans

Status on sarvaikam (AKS): ON since 2026-11-18 (connector-crowdsec 0.24.2, Traefik release revision 11). All 23
hosts answered as before; a test ban of one IP gave 403 within ~30s on every site, lifted within ~60s; Traefik
access lines parse 100% (crowdsecurity/traefik-logs); community blocklist pull enabled.


1. Enable the **CrowdSec** connector in the AIO portal (Security). On its own it only detects:
   `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list`. Layer 1 must be on (it turns on the access logs).
2. Create the bouncer key once, in both namespaces (the same value; never commit it):
   ```bash
   KEY=$(openssl rand -hex 32)
   kubectl -n crowdsec create secret generic crowdsec-bouncer --from-literal=api-key=$KEY
   kubectl -n aio-ingress create secret generic crowdsec-bouncer --from-literal=api-key=$KEY
   kubectl -n crowdsec rollout restart deploy/crowdsec-lapi      # registers the key
   kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli bouncers list   # shows "traefik"
   ```
3. Turn on the bouncer: apply the middleware, then the overlay last:
   ```bash
   kubectl apply -f $CATALOG/extras/edge-protection/bouncer-middleware.yaml
   helm upgrade aio-azure-ingress ... -f live-ingress-values.yaml -f $CATALOG/extras/edge-protection/traefik-values.yaml \
     -f $CATALOG/extras/edge-protection/traefik-crowdsec-values.yaml
   kubectl -n aio-ingress logs deploy/aio-azure-ingress-traefik | grep -i -E 'plugin|crowdsec'   # loaded, no errors
   ```
4. Check: ban your own IP for two minutes and see 403, then lift it:
   ```bash
   kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions add --ip <your-ip> --duration 2m
   curl -s -o /dev/null -w '%{http_code}\n' https://app.sarvaikam.com/        # 403 within 60s
   kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip <your-ip>
   ```

Failure behaviour: if CrowdSec is down, traffic keeps flowing (`updateMaxFailure: -1`). Traefik downloads the
plugin from GitHub when it starts; if that download fails, every route using the entrypoint middleware fails, so
after any Traefik restart check its log for plugin errors. Turning layer 2 off: upgrade again without
`traefik-crowdsec-values.yaml`, then `kubectl delete -f bouncer-middleware.yaml` and disable the connector.

## Layer 3: per-app limits

In the app's `apps/<app>/values-<env>.yaml` (aio-gitops):

```yaml
rateLimit:
  enabled: true
  average: 20         # requests per second per client IP
  burst: 50
  maxConcurrent: 20   # open requests per client IP (0 = no limit)
```

Applies to the app's main host and all its custom domains. Works on Traefik (Middleware objects) and
ingress-nginx (limit annotations).
