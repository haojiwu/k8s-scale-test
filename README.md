# k8s-scale-test

A single bash script to scale-test **kube-proxy** by creating many Kubernetes
`Service` + `EndpointSlice` objects in a cluster — **without creating any Pods**.

The EndpointSlice IPs are synthetic. kube-proxy programs nftables (or iptables)
rules pointing at them, but no traffic ever hits those IPs. That's enough to
exercise kube-proxy's rule-sync path at scale and reproduce sync-latency or
sync-wedge behavior on large clusters.

## Why no Pods?

kube-proxy only watches `Service` and `EndpointSlice` objects — it never talks
to Pods. An EndpointSlice is just a list of (IP, port) records; nothing checks
whether those IPs are backed by a live Pod. So fabricated EndpointSlices are
sufficient to drive the proxier, and they're vastly cheaper to create than real
workloads.

## Requirements

- `kubectl` on `PATH`
- Access to a test cluster (do **not** run this against production)
- A ServiceCIDR large enough for the scale you want (e.g. `/16` for ~64k services)

## Configuration

The script targets a kube context via environment variables:

```bash
# Defaults (override as needed)
KUBE_CONTEXT=aws-us-west-2-1-dev-haoji   # which kube context to use
KUBECTL_BIN=kubectl                      # kubectl binary
NS=kube-proxy-test                       # namespace for the test objects
BATCH=500                                # services per kubectl apply call
```

> The script ships with a default `KUBE_CONTEXT` pointing at a personal dev
> cluster. **Always set `KUBE_CONTEXT` to your own context** before running:
>
> ```bash
> KUBE_CONTEXT=my-test-cluster ./k8s-scale-test.sh stat
> ```

## Usage

```text
./k8s-scale-test.sh load    N_SERVICES [ENDPOINTS_PER_SVC] [PORTS_PER_SVC]  # wipe + create N services
./k8s-scale-test.sh addsvc  N_MORE     [ENDPOINTS_PER_SVC] [PORTS_PER_SVC]  # add N more (grows from top)
./k8s-scale-test.sh range   START END  [ENDPOINTS_PER_SVC] [PORTS_PER_SVC]  # apply an explicit index range
./k8s-scale-test.sh trim    TARGET_N                                        # shrink down to TARGET_N services
./k8s-scale-test.sh delsvc  N_TO_DELETE                                     # delete the top N services
./k8s-scale-test.sh churn   [INTERVAL_SECONDS] [BATCH_SIZE]                 # add/remove BATCH_SIZE every INTERVAL
./k8s-scale-test.sh stat                                                    # count test objects
./k8s-scale-test.sh watch   [KUBE_PROXY_POD]                                # tail kube-proxy sync timings
./k8s-scale-test.sh cleanup                                                 # delete the test namespace
```

### Examples

```bash
# Create 10k services with 1 synthetic endpoint each
KUBE_CONTEXT=my-test ./k8s-scale-test.sh load 10000 1

# Grow to 20k
KUBE_CONTEXT=my-test ./k8s-scale-test.sh addsvc 10000 1

# Shrink back to 5k
KUBE_CONTEXT=my-test ./k8s-scale-test.sh trim 5000

# Give each service 3 ports. kube-proxy programs one rule per service *port*,
# so this triples the rule count without tripling the Service count.
KUBE_CONTEXT=my-test ./k8s-scale-test.sh load 10000 1 3

# Load in parallel. Each worker owns a disjoint index range, so there is no
# shared cursor to race on; re-running a range is idempotent.
for i in 0 1 2 3; do
  KUBE_CONTEXT=my-test ./k8s-scale-test.sh range $((i * 2500)) $((i * 2500 + 2499)) 1 &
done
wait

# Generate steady churn: every 30s add 50 new services and delete the 50 oldest.
# Forces kube-proxy to do real reconciliation work each tick.
KUBE_CONTEXT=my-test ./k8s-scale-test.sh churn 30 50

# Watch kube-proxy sync latency while churn runs (separate terminal)
KUBE_CONTEXT=my-test ./k8s-scale-test.sh watch

# Tear everything down
KUBE_CONTEXT=my-test ./k8s-scale-test.sh cleanup
```

## How objects are shaped

Each "service" is:

- a `Service` of `type: ClusterIP` with **no selector** (so the EndpointSlice
  controller leaves the synthetic slices alone), labeled `test/run=scale-test`
- an `EndpointSlice` labeled `kubernetes.io/service-name: <svc>`, with
  `ENDPOINTS_PER_SVC` synthetic IPv4 addresses
- `PORTS_PER_SVC` ports on both objects (default 1): `80/http`, then
  `8001/p1`, `8002/p2`, ...

Churn objects are labeled `test/run=churn` so they can be cleaned up
independently of the bulk-loaded scale objects.

## Safety notes

- **Test clusters only.** At high scale this puts real load on the apiserver and
  etcd, and a brief data-plane gap is possible if you wipe and reload while
  workloads depend on the test namespace.
- **Only `range` is safe to run concurrently.** `addsvc` derives its start index
  from the highest existing service, so parallel `addsvc` calls collide.
- `cleanup` (or `kubectl delete ns kube-proxy-test`) removes everything the
  script created. At very high scale, namespace deletion can take several
  minutes as the apiserver garbage-collects each object.
- Churn's `Ctrl-C` handler deletes only `test/run=churn` objects, leaving any
  bulk-loaded `test/run=scale-test` data intact.

## License

MIT
