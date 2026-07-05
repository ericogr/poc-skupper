# Arquitetura detalhada da PoC

*Idiomas: [English](ARCHITECTURE.md) · Português (pt-BR) — este arquivo.*

Este documento detalha, com diagramas Mermaid, como a PoC descrita no
`README.pt-BR.md` e no `PLAN.md` é montada: topologia de rede, componentes
por cluster, sequência de bootstrap do link, fluxo de tráfego de
aplicação, cadeia de mTLS e defesa em profundidade da unidirecionalidade.
Para o raciocínio por trás de cada decisão (por que Calico só em A, por
que `extraPortMappings` em vez de MetalLB, etc.), ver `PLAN.md`.

## 1. Visão geral

| Item | Cluster A (`skupper-a`) | Cluster B (`skupper-b`) |
|---|---|---|
| Rede docker | `net-skupper-a` (isolada) | `net-skupper-b` (isolada) |
| CNI | Calico (aplica `NetworkPolicy`) | kindnet (padrão do kind) |
| Pod CIDR | `192.168.0.0/16` | padrão do kind |
| Exposição | `site-a --enable-link-access` (único lado alcançável) | nenhuma |
| Papel no link | recebe (nunca disca para fora) | inicia (`token redeem`) |
| Workload local | `echo-a` → responde `hello from A` | `echo-b` → responde `hello from B` |
| Expõe para o outro | `connector svc-a` (echo-a) | `connector svc-b` (echo-b) |
| Consome do outro | `listener svc-b` | `listener svc-a` |
| Recurso `Link` | não existe (A nunca "sabe" discar) | existe (B é quem resgatou o token) |

Duas portas de A são publicadas no host via `extraPortMappings` do kind
(mecanismo padrão do kind/Docker, equivalente ao que já publica a porta da
API do Kubernetes — nenhuma regra de firewall manual):

| Porta host | Uso | Service / namespace em A |
|---|---|---|
| `30671` | link inter-router (tráfego do link, mTLS) | `app/skupper-router` (nodePort fixo) |
| `30672` | bootstrap do token (`grant-server`) | `skupper/skupper-grant-server` (nodePort fixo) |

## 2. Topologia de rede — simulação "via internet" sem tocar no host

A ideia central: `net-skupper-a` e `net-skupper-b` são redes Docker
diferentes e **nunca são conectadas entre si**. O Docker já isola redes
diferentes por padrão. O único caminho entre elas é indireto, via o host:
o kind publica as portas de A no host (`-p hostPort:containerPort`, gerado
a partir de `extraPortMappings`), e qualquer container em `net-skupper-b`
já enxerga o host através do **gateway da própria rede** (`net-skupper-b`
tem, por padrão do Docker, uma interface do host atuando como gateway —
é o mesmo endereço que containers dessa rede usam para sair para a
internet real). Isso simula muito bem um "IP público" de A: B só conhece
esse gateway + porta publicada, nunca o IP interno real do site A.

```mermaid
flowchart TB
    subgraph HOST["Host local — Docker Engine (nenhuma config de rede alterada)"]
        direction LR
        PORT1["porta publicada :30671<br/>(inter-router / link-access)"]
        PORT2["porta publicada :30672<br/>(grant-server / bootstrap do token)"]
    end

    subgraph NETA["docker network: net-skupper-a (isolada)"]
        NODEA["container skupper-a-control-plane<br/>(kind node, 1 control-plane)"]
    end

    subgraph NETB["docker network: net-skupper-b (isolada)"]
        NODEB["container skupper-b-control-plane<br/>(kind node, 1 control-plane)"]
    end

    NODEA -- "extraPortMappings do kind<br/>(docker -p 30671:30671, -p 30672:30672)" --> PORT1
    NODEA --> PORT2

    PORT1 -- "alcançável via gateway<br/>de net-skupper-b<br/>(ex.: 172.24.0.1)" --> NODEB
    PORT2 -- "idem" --> NODEB

    NETA -.->|"SEM rota direta —<br/>isolamento padrão do Docker,<br/>nada precisa ser configurado"| NETB

    style NETA fill:#1f3b57,color:#fff
    style NETB fill:#4a1f1f,color:#fff
    style HOST fill:#2d2d2d,color:#fff
```

Pontos-chave:

- **A nunca disca para fora.** O único caminho de entrada de A é a porta
  publicada no host. Fora dela, `net-skupper-a` continua isolada.
- **B só conhece o "endereço público" de A** (gateway + porta publicada),
  nunca a rede interna real de `net-skupper-a` — exatamente como aconteceria
  se A estivesse atrás de um NAT/roteador na internet real.
- Uma vez que o link TCP/TLS é estabelecido (B → A), a conexão resultante é
  **bidirecional**: A consegue expor `svc-a` para B e consumir `svc-b` de B
  pela mesma ligação, sem nunca precisar de rota de saída própria.

## 3. Componentes dentro de cada cluster

```mermaid
flowchart LR
    subgraph clusterA["cluster skupper-a — CNI: Calico"]
        subgraph nsSkupperA["namespace: skupper"]
            ctrlA["deployment/skupper-controller<br/>(helm chart 2.2.1)"]
            grantA["Service skupper-grant-server<br/>nodePort 30672 (fixo)"]
        end
        subgraph nsAppA["namespace: app"]
            siteA["site-a<br/>--enable-link-access<br/>--link-access-type loadbalancer"]
            routerA["deployment/skupper-router<br/>Service type=LoadBalancer<br/>(pending; nodePort 30671 fixo;<br/>status.loadBalancer.ingress<br/>resolvido manualmente)"]
            echoA["deployment/echo-a<br/>hashicorp/http-echo<br/>'hello from A'"]
            connA["connector svc-a → echo-a:8080"]
            listA["listener svc-b<br/>(consome echo-b de B)"]
            npA["NetworkPolicy<br/>skupper-a-deny-egress<br/>(defesa em profundidade)"]
        end
    end

    subgraph clusterB["cluster skupper-b — CNI: kindnet (padrão)"]
        subgraph nsSkupperB["namespace: skupper"]
            ctrlB["deployment/skupper-controller<br/>(helm chart 2.2.1)"]
        end
        subgraph nsAppB["namespace: app"]
            siteB["site-b<br/>(sem exposição)"]
            routerB["deployment/skupper-router"]
            echoB["deployment/echo-b<br/>hashicorp/http-echo<br/>'hello from B'"]
            connB["connector svc-b → echo-b:8080"]
            listB["listener svc-a<br/>(consome echo-a de A)"]
            linkObj["recurso Link<br/>site-a-...<br/>(só existe em B —<br/>B é quem iniciou)"]
        end
    end

    linkObj == "link inter-router mTLS<br/>iniciado por B, via :30671" ==> routerA
    listB -. "chamada de app<br/>A ← svc-a" .-> connA
    listA -. "chamada de app<br/>B → svc-b" .-> connB
```

## 4. Sequência de bootstrap do link (grant → token → redeem)

```mermaid
sequenceDiagram
    participant Ops as make up (scripts 05→07)
    participant A as cluster skupper-a
    participant Host as Host (portas publicadas)
    participant B as cluster skupper-b

    Ops->>A: skupper site create site-a --enable-link-access
    Ops->>A: kubectl patch svc/skupper-router (nodePort=30671)
    Ops->>A: kubectl patch svc/skupper-grant-server (nodePort=30672)
    Ops->>A: patch status.loadBalancer.ingress = gateway de net-skupper-b
    Note over A: site-a fica "Ready" só depois<br/>desses 2 patches (kind não tem<br/>LoadBalancer real)

    Ops->>A: skupper token issue site-a-token.yaml
    A-->>Ops: token (spec.url = https://<gw>:9090/<grant-id>)
    Ops->>Ops: sed: porta 9090 → 30672<br/>(porta real do grant-server publicada)

    Ops->>B: skupper token redeem site-a-token.yaml
    B->>Host: HTTPS bootstrap em :30672
    Host->>A: encaminha para skupper-grant-server
    A-->>B: certificados de mTLS emitidos<br/>+ recurso Link criado em B

    Ops->>B: kubectl patch link<br/>(inter-router→30671, edge→porta dinâmica)
    Ops->>B: kubectl rollout restart deployment/skupper-router
    Note over B: router de B só relê a config<br/>corrigida depois de reiniciar

    B->>Host: conexão inter-router TLS persistente em :30671
    Host->>A: encaminha para skupper-router
    A-->>B: link status = Ready, Operational=True
```

## 5. Tráfego de aplicação bidirecional sobre o link único

```mermaid
sequenceDiagram
    participant EchoA as echo-a (cluster A)
    participant RouterA as skupper-router (A)
    participant LinkTLS as link inter-router (mTLS)<br/>iniciado por B
    participant RouterB as skupper-router (B)
    participant EchoB as echo-b (cluster B)

    Note over RouterA,RouterB: uma única conexão TCP/TLS,<br/>estabelecida por B → A,<br/>mas bidirecional depois do handshake

    RouterB->>LinkTLS: pedido para "svc-a" (listener svc-a em B)
    LinkTLS->>RouterA: encaminha via o link já estabelecido
    RouterA->>EchoA: connector svc-a → echo-a:8080
    EchoA-->>RouterA: "hello from A"
    RouterA-->>LinkTLS: resposta
    LinkTLS-->>RouterB: resposta
    RouterB-->>RouterB: listener svc-a entrega ao chamador em B

    RouterA->>LinkTLS: pedido para "svc-b" (listener svc-b em A)
    LinkTLS->>RouterB: encaminha via o MESMO link
    RouterB->>EchoB: connector svc-b → echo-b:8080
    EchoB-->>RouterB: "hello from B"
    RouterB-->>LinkTLS: resposta
    LinkTLS-->>RouterA: resposta
```

Routing-keys diferentes (`svc-a`, `svc-b`) evitam colisão, já que os dois
lados têm **connector e listener ao mesmo tempo** — é isso que dá acesso
bidirecional a serviço sobre uma ligação de rede unidirecional.

## 6. Segurança da conexão — mTLS

```mermaid
flowchart LR
    ca["Secret skupper-site-ca<br/>(kubernetes.io/tls, gerado em A<br/>no site create)"]
    certRouter["cert do skupper-router A<br/>CN=skupper-router"]
    certClient["cert de cliente emitido a B<br/>durante o token redeem"]
    handshake["handshake TLS 1.3<br/>(validado com openssl s_client)"]
    negControl["controle negativo:<br/>conexão sem cert de cliente"]
    rejected["rejeitada: 'certificate required'<br/>(alert TLS)"]

    ca -->|assina| certRouter
    ca -->|assina| certClient
    certRouter -->|apresentado em :30671| handshake
    certClient -->|exigido pelo mTLS| handshake
    negControl --> rejected

    style handshake fill:#1f3b57,color:#fff
    style rejected fill:#4a1f1f,color:#fff
```

`scripts/10-validate-tls.sh` prova isso de duas formas: (1) inspeciona os
Secrets `kubernetes.io/tls` no namespace `app` de A (CA própria do site,
não é texto plano); (2) faz um handshake TLS bruto contra
`<gateway>:30671`, confirma `Peer certificate: CN=skupper-router`, e depois
confirma que a mesma conexão **sem** certificado de cliente é rejeitada
pelo mTLS (`tlsv1.3 alert certificate required`) — controle negativo que
prova autenticação mútua, não só criptografia de um lado.

## 7. Unidirecionalidade em profundidade (NetworkPolicy + Calico)

O isolamento de rede Docker já garante que A não tem rota de saída própria
(seção 2). `networkpolicy/skupper-a-deny-egress.yaml` adiciona uma segunda
camada, **dentro** do cluster A, aplicada pelo Calico (o CNI padrão,
kindnet, não aplica `NetworkPolicy` — por isso A precisa de Calico e B não):

```mermaid
flowchart TB
    subgraph A["cluster skupper-a — namespace app"]
        pods["pods (echo-a, skupper-router, ...)"]
        policy["NetworkPolicy skupper-a-deny-egress<br/>egress liberado só para:<br/>• DNS (kube-system:53 UDP/TCP)<br/>• CIDR 192.168.0.0/16 (intra-cluster)"]
    end
    established["conexão já estabelecida<br/>(link B→A, retorno via conntrack)"]
    external["IP externo novo<br/>(ex.: 1.1.1.1)"]

    pods -- "tráfego de retorno de<br/>conexão já existente: permitido" --> established
    pods -- "NOVA conexão de saída: bloqueada" --x external
    policy -. aplicada por .-> pods
```

`scripts/11-validate-unidirectional.sh` prova as duas metades: com a
policy aplicada, o tráfego bidirecional **já estabelecido** continua
funcionando (egress-deny do Calico só afeta conexões *novas*, o retorno de
uma conexão existente segue via conntrack); e uma tentativa de **nova**
conexão de dentro de A para `1.1.1.1` falha — controle negativo que prova
que a policy é real (Calico), não um NetworkPolicy inerte.

## 8. Ordem de execução via Makefile

```mermaid
flowchart LR
    preflight["make preflight<br/>(check-tools.sh:<br/>docker/kind/kubectl/<br/>helm/skupper/jq)"]
    preflight -.->|"pré-requisito de<br/>TODO alvo abaixo"| up["make up<br/>(00-preflight + scripts 01→09)"]
    up --> validate["make validate<br/>(09 + 10 + 11)"]
    validate --> metrics["make metrics<br/>(12, link ainda ativo)"]
    metrics --> drop["make test-network-drop<br/>(13 — não-destrutivo,<br/>termina com link Ready)"]
    drop --> revoke["make test-revocation<br/>(14 — DESTRUTIVO,<br/>termina com link removido)"]
    revoke -.->|"opcional: restaura o link"| relink["make relink<br/>(reexecuta script 07)"]
    relink --> validate
    validate --> down["make down<br/>(99 — teardown completo)"]
    revoke --> down

    style revoke fill:#4a1f1f,color:#fff
    style up fill:#1f3b57,color:#fff
    style preflight fill:#2d2d2d,color:#fff
```

`test-network-drop` roda antes de `test-revocation` de propósito: o
primeiro termina com o link ativo de novo (reconexão automática após
`docker network disconnect`/`connect` no node de B); o segundo é
destrutivo por definição (`skupper link delete`) e por isso roda por
último. `make relink` existe justamente para religar os clusters depois de
`test-revocation` sem precisar recriar nada do zero.

Todo alvo do Makefile (`up`, `validate`, `test-tls`,
`test-unidirectional`, `metrics`, `test-network-drop`, `test-revocation`,
`relink`, `down`) declara `preflight` como pré-requisito — `make` roda
`scripts/check-tools.sh` antes de qualquer outro comando. Esse script
varre `docker`, `kind`, `kubectl`, `helm`, `skupper` e `jq`, reporta
**todas** as ferramentas ausentes de uma vez (não só a primeira) com uma
sugestão de instalação para cada uma, e só deixa o alvo pedido prosseguir
se todas estiverem presentes. `00-preflight.sh` (chamado só por `make up`)
reaproveita o mesmo `check-tools.sh` e, depois, confere também a ausência
de colisão de nomes de cluster/rede/porta antes de criar qualquer coisa.

## 9. Cenários de falha simulados

| Cenário | Script | Mecanismo | Resultado esperado |
|---|---|---|---|
| Queda de rede de B | `13-simulate-network-drop.sh` | `docker network disconnect/connect net-skupper-b skupper-b-control-plane` | Link volta a `Operational=True` sozinho; tráfego bidirecional se recupera (com retry curto) |
| Revogação do link | `14-test-link-revocation.sh` | `skupper link delete <nome>` (a partir de B, quem o criou) | Tráfego falha **nos dois sentidos** — prova que não há caminho alternativo |

Ambos os cenários usam só operações padrão do Docker/Skupper sobre
containers e recursos da própria PoC — nenhuma mudança na rede do host.
