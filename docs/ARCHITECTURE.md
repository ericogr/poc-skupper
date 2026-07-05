# Detailed PoC architecture

*Languages: English (this file) · [Português (pt-BR)](ARCHITECTURE.pt-BR.md).*

This document details, with Mermaid diagrams, how the PoC described in
`README.md` and `PLAN.md` (in Portuguese) is put together: network
topology, components per cluster, the link's bootstrap sequence,
application traffic flow, the mTLS chain, and defense-in-depth for the
unidirectionality. For the reasoning behind each decision (why Calico
only on A, why `extraPortMappings` instead of MetalLB, etc.), see
`PLAN.md`.

## 1. Overview

| Item | Cluster A (`skupper-a`) | Cluster B (`skupper-b`) |
|---|---|---|
| Docker network | `net-skupper-a` (isolated) | `net-skupper-b` (isolated) |
| CNI | Calico (enforces `NetworkPolicy`) | kindnet (kind's default) |
| Pod CIDR | `192.168.0.0/16` | kind's default |
| Exposure | `site-a --enable-link-access` (only reachable side) | none |
| Role in the link | receives (never dials out) | initiates (`token redeem`) |
| Local workload | `echo-a` → replies `hello from A` | `echo-b` → replies `hello from B` |
| Exposes to the other | `connector svc-a` (echo-a) | `connector svc-b` (echo-b) |
| Consumes from the other | `listener svc-b` | `listener svc-a` |
| `Link` resource | doesn't exist (A never "knows" how to dial) | exists (B is who redeemed the token) |

Two of A's ports are published on the host via kind's
`extraPortMappings` (a standard kind/Docker mechanism, equivalent to
what already publishes the Kubernetes API port — no manual firewall
rule):

| Host port | Use | Service / namespace in A |
|---|---|---|
| `30671` | inter-router link (link traffic, mTLS) | `app/skupper-router` (fixed nodePort) |
| `30672` | token bootstrap (`grant-server`) | `skupper/skupper-grant-server` (fixed nodePort) |

## 2. Network topology — simulating "over the internet" without touching the host

The core idea: `net-skupper-a` and `net-skupper-b` are different Docker
networks and are **never connected to each other**. Docker already
isolates different networks by default. The only path between them is
indirect, via the host: kind publishes A's ports on the host (`-p
hostPort:containerPort`, generated from `extraPortMappings`), and any
container on `net-skupper-b` already sees the host through **that
network's own gateway** (`net-skupper-b` has, by Docker's default, a
host interface acting as gateway — the same address containers on that
network use to reach the real internet). This simulates a "public IP"
for A quite well: B only knows that gateway + published port, never
site A's real internal IP.

```mermaid
flowchart TB
    subgraph HOST["Local host — Docker Engine (no network config changed)"]
        direction LR
        PORT1["published port :30671<br/>(inter-router / link-access)"]
        PORT2["published port :30672<br/>(grant-server / token bootstrap)"]
    end

    subgraph NETA["docker network: net-skupper-a (isolated)"]
        NODEA["container skupper-a-control-plane<br/>(kind node, 1 control-plane)"]
    end

    subgraph NETB["docker network: net-skupper-b (isolated)"]
        NODEB["container skupper-b-control-plane<br/>(kind node, 1 control-plane)"]
    end

    NODEA -- "kind's extraPortMappings<br/>(docker -p 30671:30671, -p 30672:30672)" --> PORT1
    NODEA --> PORT2

    PORT1 -- "reachable via net-skupper-b's<br/>gateway<br/>(e.g. 172.24.0.1)" --> NODEB
    PORT2 -- "same" --> NODEB

    NETA -.->|"NO direct route —<br/>Docker's default isolation,<br/>nothing needs to be configured"| NETB

    style NETA fill:#1f3b57,color:#fff
    style NETB fill:#4a1f1f,color:#fff
    style HOST fill:#2d2d2d,color:#fff
```

Key points:

- **A never dials out.** The only inbound path into A is the port
  published on the host. Outside of it, `net-skupper-a` stays isolated.
- **B only knows A's "public address"** (gateway + published port),
  never `net-skupper-a`'s real internal network — exactly what would
  happen if A were behind a NAT/router on the real internet.
- Once the TCP/TLS link is established (B → A), the resulting connection
  is **bidirectional**: A can expose `svc-a` to B and consume `svc-b`
  from B over that same connection, without ever needing its own
  outbound route.

## 3. Components inside each cluster

```mermaid
flowchart LR
    subgraph clusterA["cluster skupper-a — CNI: Calico"]
        subgraph nsSkupperA["namespace: skupper"]
            ctrlA["deployment/skupper-controller<br/>(helm chart 2.1.1)"]
            grantA["Service skupper-grant-server<br/>nodePort 30672 (fixed)"]
        end
        subgraph nsAppA["namespace: app"]
            siteA["site-a<br/>--enable-link-access<br/>--link-access-type loadbalancer"]
            routerA["deployment/skupper-router<br/>Service type=LoadBalancer<br/>(pending; nodePort 30671 fixed;<br/>status.loadBalancer.ingress<br/>resolved manually)"]
            echoA["deployment/echo-a<br/>hashicorp/http-echo<br/>'hello from A'"]
            connA["connector svc-a → echo-a:8080"]
            listA["listener svc-b<br/>(consumes echo-b from B)"]
            npA["NetworkPolicy<br/>skupper-a-deny-egress<br/>(defense in depth)"]
        end
    end

    subgraph clusterB["cluster skupper-b — CNI: kindnet (default)"]
        subgraph nsSkupperB["namespace: skupper"]
            ctrlB["deployment/skupper-controller<br/>(helm chart 2.1.1)"]
        end
        subgraph nsAppB["namespace: app"]
            siteB["site-b<br/>(no exposure)"]
            routerB["deployment/skupper-router"]
            echoB["deployment/echo-b<br/>hashicorp/http-echo<br/>'hello from B'"]
            connB["connector svc-b → echo-b:8080"]
            listB["listener svc-a<br/>(consumes echo-a from A)"]
            linkObj["Link resource<br/>site-a-...<br/>(only exists in B —<br/>B is who initiated it)"]
        end
    end

    linkObj == "inter-router mTLS link<br/>initiated by B, via :30671" ==> routerA
    listB -. "app call<br/>A ← svc-a" .-> connA
    listA -. "app call<br/>B → svc-b" .-> connB
```

## 4. Link bootstrap sequence (grant → token → redeem)

```mermaid
sequenceDiagram
    participant Ops as make up (scripts 05→07)
    participant A as cluster skupper-a
    participant Host as Host (published ports)
    participant B as cluster skupper-b

    Ops->>A: skupper site create site-a --enable-link-access
    Ops->>A: kubectl patch svc/skupper-router (nodePort=30671)
    Ops->>A: kubectl patch svc/skupper-grant-server (nodePort=30672)
    Ops->>A: patch status.loadBalancer.ingress = net-skupper-b's gateway
    Note over A: site-a only becomes "Ready" after<br/>those 2 patches (kind has no<br/>real LoadBalancer)

    Ops->>A: skupper token issue site-a-token.yaml
    A-->>Ops: token (spec.url = https://<gw>:9090/<grant-id>)
    Ops->>Ops: sed: port 9090 → 30672<br/>(real published grant-server port)

    Ops->>B: skupper token redeem site-a-token.yaml
    B->>Host: HTTPS bootstrap on :30672
    Host->>A: forwards to skupper-grant-server
    A-->>B: mTLS certificates issued<br/>+ Link resource created in B

    Ops->>B: kubectl patch link<br/>(inter-router→30671, edge→dynamic port)
    Ops->>B: kubectl rollout restart deployment/skupper-router
    Note over B: B's router only re-reads the<br/>fixed config after restarting

    B->>Host: persistent inter-router TLS connection on :30671
    Host->>A: forwards to skupper-router
    A-->>B: link status = Ready, Operational=True
```

## 5. Bidirectional application traffic over the single link

```mermaid
sequenceDiagram
    participant EchoA as echo-a (cluster A)
    participant RouterA as skupper-router (A)
    participant LinkTLS as inter-router link (mTLS)<br/>initiated by B
    participant RouterB as skupper-router (B)
    participant EchoB as echo-b (cluster B)

    Note over RouterA,RouterB: a single TCP/TLS connection,<br/>established B → A,<br/>but bidirectional after the handshake

    RouterB->>LinkTLS: request for "svc-a" (listener svc-a in B)
    LinkTLS->>RouterA: forwards over the already-established link
    RouterA->>EchoA: connector svc-a → echo-a:8080
    EchoA-->>RouterA: "hello from A"
    RouterA-->>LinkTLS: response
    LinkTLS-->>RouterB: response
    RouterB-->>RouterB: listener svc-a delivers to the caller in B

    RouterA->>LinkTLS: request for "svc-b" (listener svc-b in A)
    LinkTLS->>RouterB: forwards over the SAME link
    RouterB->>EchoB: connector svc-b → echo-b:8080
    EchoB-->>RouterB: "hello from B"
    RouterB-->>LinkTLS: response
    LinkTLS-->>RouterA: response
```

Different routing keys (`svc-a`, `svc-b`) avoid collisions, since both
sides have a **connector and a listener at the same time** — that's what
gives bidirectional service access over a unidirectional network
connection.

## 6. Connection security — mTLS

```mermaid
flowchart LR
    ca["Secret skupper-site-ca<br/>(kubernetes.io/tls, generated in A<br/>at site create)"]
    certRouter["skupper-router A's cert<br/>CN=skupper-router"]
    certClient["client cert issued to B<br/>during token redeem"]
    handshake["TLS 1.3 handshake<br/>(validated with openssl s_client)"]
    negControl["negative control:<br/>connection without client cert"]
    rejected["rejected: 'certificate required'<br/>(TLS alert)"]

    ca -->|signs| certRouter
    ca -->|signs| certClient
    certRouter -->|presented at :30671| handshake
    certClient -->|required by mTLS| handshake
    negControl --> rejected

    style handshake fill:#1f3b57,color:#fff
    style rejected fill:#4a1f1f,color:#fff
```

`scripts/10-validate-tls.sh` proves this two ways: (1) it inspects the
`kubernetes.io/tls` Secrets in A's `app` namespace (the site's own CA,
not plain text); (2) it performs a raw TLS handshake against
`<gateway>:30671`, confirms `Peer certificate: CN=skupper-router`, and
then confirms that the same connection **without** a client certificate
is rejected by mTLS (`tlsv1.3 alert certificate required`) — a negative
control that proves mutual authentication, not just one-sided
encryption.

## 7. Defense-in-depth for unidirectionality (NetworkPolicy + Calico)

Docker's network isolation already guarantees A has no outbound route of
its own (section 2). `networkpolicy/skupper-a-deny-egress.yaml` adds a
second layer, **inside** cluster A, enforced by Calico (the default CNI,
kindnet, doesn't enforce `NetworkPolicy` — which is why A needs Calico
and B doesn't):

```mermaid
flowchart TB
    subgraph A["cluster skupper-a — namespace app"]
        pods["pods (echo-a, skupper-router, ...)"]
        policy["NetworkPolicy skupper-a-deny-egress<br/>egress allowed only to:<br/>• DNS (kube-system:53 UDP/TCP)<br/>• CIDR 192.168.0.0/16 (intra-cluster)"]
    end
    established["already-established connection<br/>(link B→A, return traffic via conntrack)"]
    external["new external IP<br/>(e.g. 1.1.1.1)"]

    pods -- "return traffic of an<br/>existing connection: allowed" --> established
    pods -- "NEW outbound connection: blocked" --x external
    policy -. enforced on .-> pods
```

`scripts/11-validate-unidirectional.sh` proves both halves: with the
policy applied, the **already-established** bidirectional traffic keeps
working (Calico's egress-deny only affects *new* connections; return
traffic of an existing connection keeps flowing via conntrack); and an
attempt at a **new** connection from inside A to `1.1.1.1` fails — a
negative control that proves the policy is real (Calico), not an inert
NetworkPolicy.

## 8. Makefile execution order

```mermaid
flowchart LR
    preflight["make preflight<br/>(check-tools.sh:<br/>docker/kind/kubectl/<br/>helm/skupper/jq)"]
    preflight -.->|"prerequisite of<br/>EVERY target below"| up["make up<br/>(00-preflight + scripts 01→09)"]
    up --> validate["make validate<br/>(09 + 10 + 11)"]
    validate --> metrics["make metrics<br/>(12, link still up)"]
    metrics --> drop["make test-network-drop<br/>(13 — non-destructive,<br/>ends with link Ready)"]
    drop --> revoke["make test-revocation<br/>(14 — DESTRUCTIVE,<br/>ends with link removed)"]
    revoke -.->|"optional: restores the link"| relink["make relink<br/>(re-runs script 07)"]
    relink --> validate
    validate --> down["make down<br/>(99 — full teardown)"]
    revoke --> down

    style revoke fill:#4a1f1f,color:#fff
    style up fill:#1f3b57,color:#fff
    style preflight fill:#2d2d2d,color:#fff
```

`test-network-drop` runs before `test-revocation` on purpose: the first
ends with the link active again (automatic reconnection after `docker
network disconnect`/`connect` on B's node); the second is destructive by
definition (`skupper link delete`) and therefore runs last. `make
relink` exists precisely to reconnect the clusters after
`test-revocation` without having to recreate anything.

Every Makefile target (`up`, `validate`, `test-tls`,
`test-unidirectional`, `metrics`, `test-network-drop`,
`test-revocation`, `relink`, `down`) declares `preflight` as a
prerequisite — `make` runs `scripts/check-tools.sh` before any other
command. That script scans `docker`, `kind`, `kubectl`, `helm`,
`skupper`, and `jq`, reports **every** missing tool at once (not just
the first one) with an install suggestion for each, and only lets the
requested target proceed if all of them are present. `00-preflight.sh`
(called only by `make up`) reuses that same `check-tools.sh` and then
also checks for the absence of cluster/network/port name collisions
before creating anything.

## 9. Simulated failure scenarios

| Scenario | Script | Mechanism | Expected result |
|---|---|---|---|
| B's network drop | `13-simulate-network-drop.sh` | `docker network disconnect/connect net-skupper-b skupper-b-control-plane` | Link goes back to `Operational=True` on its own; bidirectional traffic recovers (with a short retry) |
| Link revocation | `14-test-link-revocation.sh` | `skupper link delete <name>` (from B, who created it) | Traffic fails **in both directions** — proves there's no alternate path |

Both scenarios use only standard Docker/Skupper operations on the PoC's
own containers and resources — no change to the host's network.
