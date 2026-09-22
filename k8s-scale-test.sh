#!/usr/bin/env bash
#
# k8s-scale-test.sh — create N Kubernetes Services + EndpointSlices at scale
# to reproduce kube-proxy nftables wedge in a real cluster.
#
# No Pods are created. The EndpointSlice IPs are synthetic — kube-proxy will
# program nftables rules pointing at them, but no traffic ever hits the IPs.
# This is sufficient to stress the kube-proxy sync path.
#
# Usage:
#   ./k8s-scale-test.sh load    N_SERVICES [ENDPOINTS_PER_SVC] [PORTS_PER_SVC]
#   ./k8s-scale-test.sh addsvc  N_MORE     [ENDPOINTS_PER_SVC] [PORTS_PER_SVC]
#   ./k8s-scale-test.sh range   START END  [ENDPOINTS_PER_SVC] [PORTS_PER_SVC]
#   ./k8s-scale-test.sh trim    TARGET_N
#   ./k8s-scale-test.sh delsvc  N_TO_DELETE
#   ./k8s-scale-test.sh churn   [INTERVAL_SECONDS] [BATCH_SIZE]
#   ./k8s-scale-test.sh stat
#   ./k8s-scale-test.sh watch   KUBE_PROXY_POD
#   ./k8s-scale-test.sh cleanup
#
# Environment:
#   NS=<namespace>             default: kube-proxy-test
#   BATCH=<services-per-apply> default: 500
#
set -euo pipefail

NS="${NS:-kube-proxy-test}"
BATCH="${BATCH:-500}"
# Pinned to the dev cluster context. Override with KUBE_CONTEXT=... if you need
# a different cluster, or set KUBECTL_BIN to a different binary path.
KUBE_CONTEXT="${KUBE_CONTEXT:-aws-us-west-2-1-dev-haoji}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
# Use an array so the multi-word command splits correctly on invocation.
KUBECTL=("$KUBECTL_BIN" "--context=$KUBE_CONTEXT")

usage() { sed -n '2,23p' "$0"; exit 1; }

# Deterministic synthetic endpoint IP from a service index + endpoint index.
# Uses 10.244.0.0/14 (CIDR with ~262k addresses) which is the common pod-network
# range — but since these IPs aren't routable to anywhere real, no conflict
# with actual pod traffic.
ep_ip() {
    local svc_i="$1" ep_i="$2"
    local n=$(( svc_i * 8 + ep_i ))
    local o2=$(( (n >> 16) % 256 ))   # second octet
    local o3=$(( (n >> 8)  % 256 ))   # third octet
    local o4=$(( n         % 256 ))   # fourth octet
    echo "10.${o2}.${o3}.${o4}"
}

# Generate one Service + one EndpointSlice as YAML to stdout.
gen_one() {
    local i="$1" eps="$2" ports="${3:-1}"
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: svc-${i}
  namespace: ${NS}
  labels:
    test/run: scale-test
spec:
  type: ClusterIP
  ports:
  - port: 80
    protocol: TCP
    targetPort: 8080
    name: http
$(for ((k=1; k<ports; k++)); do
    printf '  - port: %d\n    protocol: TCP\n    targetPort: %d\n    name: p%d\n' $((8000 + k)) $((9000 + k)) "$k"
done)
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: svc-${i}-fake
  namespace: ${NS}
  labels:
    kubernetes.io/service-name: svc-${i}
    test/run: scale-test
addressType: IPv4
ports:
- name: http
  port: 8080
  protocol: TCP
$(for ((k=1; k<ports; k++)); do
    printf -- '- name: p%d\n  port: %d\n  protocol: TCP\n' "$k" $((9000 + k))
done)
endpoints:
EOF
    for ((j=0; j<eps; j++)); do
        cat <<EOF
- addresses: ["$(ep_ip "$i" "$j")"]
  conditions: {ready: true}
EOF
    done
}

ensure_namespace() {
    if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
        echo "[setup] Creating namespace $NS" >&2
        "${KUBECTL[@]}" create namespace "$NS" >/dev/null
    fi
}

# Apply YAML in chunks of BATCH services to keep request bodies manageable.
apply_range() {
    local start="$1" end="$2" eps="$3" ports="${4:-1}"
    local total=$(( end - start + 1 ))
    local applied=0
    local t_start
    t_start=$(date +%s)

    local tmpfile
    tmpfile=$(mktemp /tmp/k8s-scale-XXXXXX)
    trap "rm -f $tmpfile" RETURN

    local i
    for ((i=start; i<=end; i++)); do
        gen_one "$i" "$eps" "$ports" >> "$tmpfile"
        if (( (i - start + 1) % BATCH == 0 || i == end )); then
            "${KUBECTL[@]}" apply -f "$tmpfile" --server-side --force-conflicts >/dev/null
            applied=$(( i - start + 1 ))
            local now=$(date +%s)
            local elapsed=$(( now - t_start ))
            local rate
            if (( elapsed > 0 )); then rate=$(( applied / elapsed )); else rate=0; fi
            printf '\r[apply] %d/%d services (%d sec elapsed, %d svc/sec)' \
                "$applied" "$total" "$elapsed" "$rate" >&2
            : > "$tmpfile"
        fi
    done
    local t_end=$(date +%s)
    printf '\n[apply] done — %d services in %d sec\n' "$total" $(( t_end - t_start )) >&2
}

current_max_index() {
    "${KUBECTL[@]}" -n "$NS" get svc -l test/run=scale-test -o name 2>/dev/null \
        | sed -E 's|.*/svc-||' \
        | sort -n | tail -1
}

cmd_load() {
    local n="${1:?N_SERVICES required}"
    local eps="${2:-1}"
    local ports="${3:-1}"
    echo "[load] Wipe namespace and create $n services x $eps endpoints x $ports ports each." >&2
    "${KUBECTL[@]}" delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    ensure_namespace
    apply_range 0 $((n - 1)) "$eps" "$ports"
    echo "[load] done." >&2
}

cmd_addsvc() {
    local n_more="${1:?N_MORE required}"
    local eps="${2:-1}"
    local ports="${3:-1}"
    ensure_namespace
    local start
    start=$(current_max_index)
    if [ -z "$start" ]; then
        start=0
    else
        start=$((start + 1))
    fi
    local end=$((start + n_more - 1))
    echo "[addsvc] Adding services ${start}..${end} (${n_more} services x ${eps} endpoints x ${ports} ports each)." >&2
    apply_range "$start" "$end" "$eps" "$ports"
}

# Delete services svc-${start}..svc-${end} (and their EndpointSlices) in
# batches of BATCH names per kubectl delete call. Each call uses --wait=false
# so apiserver returns immediately and we don't block on object GC.
delete_range() {
    local start="$1" end="$2"
    local total=$(( end - start + 1 ))
    if (( total <= 0 )); then
        echo "[delete] Nothing to delete (range ${start}..${end})." >&2
        return
    fi
    local t_start
    t_start=$(date +%s)
    local deleted=0

    # Build name lists in chunks. Services and EndpointSlices share the index
    # but differ in name suffix, so build both per batch.
    local svc_names=() ep_names=()
    local i
    for ((i=start; i<=end; i++)); do
        svc_names+=("svc-${i}")
        ep_names+=("svc-${i}-fake")
        if (( ${#svc_names[@]} >= BATCH || i == end )); then
            # Delete services and slices for this batch. --wait=false so
            # apiserver doesn't make us spin on GC for each batch.
            "${KUBECTL[@]}" -n "$NS" delete svc "${svc_names[@]}" \
                --ignore-not-found --wait=false >/dev/null 2>&1 || true
            "${KUBECTL[@]}" -n "$NS" delete endpointslices "${ep_names[@]}" \
                --ignore-not-found --wait=false >/dev/null 2>&1 || true
            deleted=$(( i - start + 1 ))
            local now=$(date +%s)
            local elapsed=$(( now - t_start ))
            local rate
            if (( elapsed > 0 )); then rate=$(( deleted / elapsed )); else rate=0; fi
            printf '\r[delete] %d/%d services (%d sec elapsed, %d svc/sec)' \
                "$deleted" "$total" "$elapsed" "$rate" >&2
            svc_names=()
            ep_names=()
        fi
    done
    local t_end=$(date +%s)
    printf '\n[delete] done — %d services in %d sec\n' "$total" $(( t_end - t_start )) >&2
}

# Trim down to TARGET_N services. Deletes the highest-numbered services down
# to (and including) svc-${TARGET_N} so that only svc-0..svc-${TARGET_N-1}
# remain. Useful for reducing scale without re-loading from scratch.
cmd_trim() {
    local target="${1:?TARGET_N required}"
    if ! [[ "$target" =~ ^[0-9]+$ ]]; then
        echo "[trim] TARGET_N must be a non-negative integer (got: $target)" >&2
        exit 2
    fi
    if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
        echo "[trim] Namespace '$NS' does not exist." >&2
        return
    fi
    local cur_max
    cur_max=$(current_max_index)
    if [ -z "$cur_max" ]; then
        echo "[trim] No scale-test services found." >&2
        return
    fi
    local cur_count=$(( cur_max + 1 ))
    if (( target >= cur_count )); then
        echo "[trim] Current count ${cur_count} already <= target ${target}. Nothing to do." >&2
        echo "[trim] (use 'addsvc' to grow.)" >&2
        return
    fi
    echo "[trim] Trimming ${cur_count} -> ${target} services (deleting svc-${target}..svc-${cur_max})." >&2
    delete_range "$target" "$cur_max"
}

# Delete the highest N_TO_DELETE services. Symmetric counterpart to 'addsvc':
# addsvc grows from the top, delsvc shrinks from the top.
cmd_delsvc() {
    local n="${1:?N_TO_DELETE required}"
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        echo "[delsvc] N_TO_DELETE must be a positive integer (got: $n)" >&2
        exit 2
    fi
    if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
        echo "[delsvc] Namespace '$NS' does not exist." >&2
        return
    fi
    local cur_max
    cur_max=$(current_max_index)
    if [ -z "$cur_max" ]; then
        echo "[delsvc] No scale-test services found." >&2
        return
    fi
    local cur_count=$(( cur_max + 1 ))
    local n_actual="$n"
    if (( n > cur_count )); then
        n_actual="$cur_count"
        echo "[delsvc] Only ${cur_count} services exist; deleting all of them." >&2
    fi
    local start=$(( cur_max - n_actual + 1 ))
    echo "[delsvc] Deleting svc-${start}..svc-${cur_max} (${n_actual} services)." >&2
    delete_range "$start" "$cur_max"
}

# Apply an explicit index range. Unlike addsvc this takes no lock on
# current_max_index, so disjoint ranges can run concurrently. Server-side apply
# makes re-running a range idempotent.
cmd_range() {
    local start="${1:?START required}" end="${2:?END required}" eps="${3:-1}" ports="${4:-1}"
    ensure_namespace
    echo "[range] Applying svc-${start}..svc-${end} (${eps} endpoints, ${ports} ports each)." >&2
    apply_range "$start" "$end" "$eps" "$ports"
}

cmd_stat() {
    if ! "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1; then
        echo "[stat] Namespace '$NS' does not exist."
        return
    fi
    local svc_count ep_count addr_count
    svc_count=$("${KUBECTL[@]}" -n "$NS" get svc -l test/run=scale-test --no-headers 2>/dev/null | wc -l)
    ep_count=$("${KUBECTL[@]}" -n "$NS" get endpointslices -l test/run=scale-test --no-headers 2>/dev/null | wc -l)
    addr_count=$("${KUBECTL[@]}" -n "$NS" get endpointslices -l test/run=scale-test \
        -o jsonpath='{range .items[*]}{.endpoints[*].addresses[*]}{"\n"}{end}' 2>/dev/null \
        | grep -v '^$' | wc -l)
    cat <<EOF
[stat] namespace:      ${NS}
[stat]   services:     ${svc_count}
[stat]   endpointslices: ${ep_count}
[stat]   total endpoints: ${addr_count}
EOF
}

cmd_watch() {
    local pod="${1:-}"
    if [ -z "$pod" ]; then
        # Auto-pick: kube-proxy pod with most CPU (likely the test node's).
        pod=$("${KUBECTL[@]}" -n kube-system get pod -l k8s-app=kube-proxy \
            -o jsonpath='{.items[0].metadata.name}')
        echo "[watch] No pod given, defaulting to: $pod" >&2
    fi
    echo "[watch] Tailing $pod for sync timings — Ctrl-C to stop." >&2
    "${KUBECTL[@]}" -n kube-system logs -f "$pod" --tail=20 \
        | grep --line-buffered -E "Reloading|SyncProxyRules|Syncing nftables|fullSync|Failed"
}

# Generate a single "churn" service YAML — same shape as gen_one, but labeled
# test/run=churn so we can target/delete churn services separately from the
# bulk-loaded ones.
gen_churn() {
    local name="$1"
    local ip="$2"
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    test/run: churn
spec:
  type: ClusterIP
  ports:
  - port: 80
    protocol: TCP
    targetPort: 8080
    name: http
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${name}-fake
  namespace: ${NS}
  labels:
    kubernetes.io/service-name: ${name}
    test/run: churn
addressType: IPv4
ports:
- name: http
  port: 8080
  protocol: TCP
endpoints:
- addresses: ["${ip}"]
  conditions: {ready: true}
EOF
}

# Churn: every INTERVAL seconds, add BATCH_SIZE new services AND remove the
# BATCH_SIZE oldest currently-alive ones. Steady-state alive count = BATCH_SIZE
# (after a one-tick warmup). Each tick produces ~2 * BATCH_SIZE informer events
# for kube-proxy.
#
# Naming: churn-<counter>. Counter is never reused so the kube-proxy informer
# always sees genuinely new objects.
#
# IPs taken from 10.255.0.0/16 (~65k addresses) so churn IPs don't collide with
# scale-test IPs. Counter wraps within 16 bits for IP allocation, but service
# names remain unique because they use the full counter.
#
# Ctrl-C stops the loop and cleans up the churn services it created. The
# bulk-loaded scale services (test/run=scale-test) are NOT touched.
cmd_churn() {
    local interval="${1:-30}"
    local batch_size="${2:-50}"
    if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
        echo "[churn] INTERVAL_SECONDS must be a positive integer (got: $interval)" >&2
        exit 2
    fi
    if ! [[ "$batch_size" =~ ^[1-9][0-9]*$ ]]; then
        echo "[churn] BATCH_SIZE must be a positive integer (got: $batch_size)" >&2
        exit 2
    fi
    ensure_namespace

    # Wipe any leftover churn services from a previous run.
    "${KUBECTL[@]}" -n "$NS" delete svc,endpointslices -l test/run=churn \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true

    echo "[churn] Every ${interval}s: +${batch_size} new / -${batch_size} oldest. Ctrl-C to stop." >&2
    echo "[churn] Naming: churn-<N>. IPs from 10.255.x.y to avoid conflict." >&2

    local counter=0
    local alive_indices=()   # FIFO of currently-alive churn indices (oldest first)

    # Cleanup handler — only deletes churn services, leaves scale-test data alone.
    cleanup_churn() {
        echo "" >&2
        echo "[churn] Stopping. Cleaning up churn services (scale-test data left intact)..." >&2
        "${KUBECTL[@]}" -n "$NS" delete svc,endpointslices -l test/run=churn \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
        echo "[churn] Done. Run 'cleanup' if you want to remove all test data." >&2
    }
    trap cleanup_churn INT TERM EXIT

    while true; do
        local tick_start
        tick_start=$(date +%s)

        # --- Build the add batch ---
        local tmpfile
        tmpfile=$(mktemp /tmp/churn-XXXXXX.yaml)
        local first_added="$counter"
        local k
        for ((k=0; k<batch_size; k++)); do
            local name="churn-${counter}"
            local ip="10.255.$(( (counter >> 8) % 256 )).$(( counter % 256 ))"
            gen_churn "$name" "$ip" >> "$tmpfile"
            counter=$((counter + 1))
        done
        local last_added=$((counter - 1))

        # --- Determine what to remove (oldest ${batch_size}, or all alive if fewer) ---
        local n_alive="${#alive_indices[@]}"
        local n_to_remove="$batch_size"
        if (( n_to_remove > n_alive )); then
            n_to_remove="$n_alive"
        fi

        local removed_svc_names=() removed_ep_names=()
        local first_removed="" last_removed=""
        if (( n_to_remove > 0 )); then
            local idx
            first_removed="${alive_indices[0]}"
            last_removed="${alive_indices[$((n_to_remove - 1))]}"
            for ((k=0; k<n_to_remove; k++)); do
                idx="${alive_indices[$k]}"
                removed_svc_names+=("churn-${idx}")
                removed_ep_names+=("churn-${idx}-fake")
            done
            # Drop the removed prefix from the alive FIFO.
            alive_indices=("${alive_indices[@]:n_to_remove}")
        fi

        # --- Apply adds (single kubectl call) ---
        "${KUBECTL[@]}" apply -f "$tmpfile" >/dev/null
        rm -f "$tmpfile"

        # --- Apply deletes (single kubectl call each for svc/ep) ---
        if (( n_to_remove > 0 )); then
            "${KUBECTL[@]}" -n "$NS" delete svc "${removed_svc_names[@]}" \
                --ignore-not-found --wait=false >/dev/null 2>&1 || true
            "${KUBECTL[@]}" -n "$NS" delete endpointslices "${removed_ep_names[@]}" \
                --ignore-not-found --wait=false >/dev/null 2>&1 || true
        fi

        # --- Update alive FIFO with the newly-added indices ---
        for ((k=first_added; k<=last_added; k++)); do
            alive_indices+=("$k")
        done

        # --- Report ---
        local tick_end
        tick_end=$(date +%s)
        if (( n_to_remove > 0 )); then
            printf '[%s] +add churn-%d..churn-%d  -del churn-%d..churn-%d  alive=%d  apply=%ds\n' \
                "$(date +%H:%M:%S)" \
                "$first_added" "$last_added" \
                "$first_removed" "$last_removed" \
                "${#alive_indices[@]}" \
                "$((tick_end - tick_start))" >&2
        else
            printf '[%s] +add churn-%d..churn-%d  -del (none, warmup)  alive=%d  apply=%ds\n' \
                "$(date +%H:%M:%S)" \
                "$first_added" "$last_added" \
                "${#alive_indices[@]}" \
                "$((tick_end - tick_start))" >&2
        fi

        sleep "$interval"
    done
}

cmd_cleanup() {
    echo "[cleanup] Deleting namespace $NS (this can take a while at high scale)..." >&2
    "${KUBECTL[@]}" delete namespace "$NS" --ignore-not-found --wait=true
}

case "${1:-}" in
    load)    shift; cmd_load    "$@" ;;
    addsvc)  shift; cmd_addsvc  "$@" ;;
    range)   shift; cmd_range   "$@" ;;
    trim)    shift; cmd_trim    "$@" ;;
    delsvc)  shift; cmd_delsvc  "$@" ;;
    churn)   shift; cmd_churn   "$@" ;;
    stat)           cmd_stat ;;
    watch)   shift; cmd_watch   "$@" ;;
    cleanup)        cmd_cleanup ;;
    *)              usage ;;
esac
