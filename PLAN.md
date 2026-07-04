# PoC: conectar 2 clusters via Skupper (link unidirecional, acesso bidirecional a serviços)

> **Revisão 3** — remove qualquer alteração na configuração de rede da
> **máquina local** (nada de `sudo iptables`, nada de regra de firewall no
> host). A simulação de "clusters conectados via internet" passa a usar
> só mecanismos que o Docker/kind já gerenciam automaticamente (bridges
> isoladas por padrão + publicação de porta via `-p`/`extraPortMappings`),
> mais um ajuste no arquivo de token (edição de um YAML, não do host). O que
> mudou em relação à revisão 2 está marcado com **[REV3]**.
>
> Requisitos consolidados (revisão 2, mantidos): (1) execução tudo via
> `Makefile`; (2) cada cluster expõe um serviço consumido pelo outro
> (bidirecional a nível de aplicação); (3) só um cluster fica
> exposto/alcançável (unidirecional a nível de conexão); (4) conexão segura
> (TLS/mTLS, validado explicitamente); (5) simular os dois clusters
> conectados via internet, não apenas na mesma rede local — **sem tocar na
> configuração de rede da máquina local** [REV3].

## Contexto

Partimos de um roteiro de 10 passos para uma PoC de conectividade
cross-cluster via Skupper. Os requisitos consolidados são:

- Conectar **2 clusters Kubernetes distintos**, provisionados localmente com
  **kind**.
- **Cada cluster expõe um Service** que é consumido pelo **outro** cluster —
  acesso a serviço é bidirecional (A chama serviço de B, B chama serviço de A).
- **Somente 1 dos clusters fica exposto/alcançável pela rede** — a ligação
  (quem inicia a conexão / quem precisa estar acessível) é unidirecional,
  mesmo que o tráfego de aplicação depois flua nos dois sentidos sobre essa
  única ligação.
- A conexão entre os clusters deve ser **segura** (autenticada e
  criptografada), não texto plano.
- A PoC deve **simular os dois clusters conectados via internet** — sem
  compartilhar a mesma rede local/L2 "por acidente" — **e sem alterar a
  configuração de rede da própria máquina local** [REV3]: nada de
  `sudo iptables`, nada de regra de firewall manual no host. Só operações
  padrão do Docker/kind (criar rede docker, publicar porta) e do
  Kubernetes (Service, NetworkPolicy dentro do cluster).
- Execução via **`Makefile`** (`make up`, `make validate`, `make test-tls`,
  `make test-unidirectional`, `make metrics`, `make test-network-drop`,
  `make test-revocation`, `make relink`, `make down`), não comandos soltos
  digitados à mão.

Ao investigar o ambiente (diretório `/arquivos/git/outros/poc-skupper` vazio,
ainda não é repositório git), descobrimos que:

- O CLI `skupper` já instalado nesta máquina é a **v2.1.1** (controller
  2.1.1, router 3.4.0). O roteiro original que serviu de ponto de partida
  usa sintaxe **v1** (`skupper init`, `skupper token create`, `skupper link
  create <file>`, anotações `skupper.io/proxy`/`skupper.io/port`) — nenhum
  desses comandos/anotações existe no v2. Confirmado via `skupper --help` e
  `--help` de cada subcomando.
- `kind` (v0.31.0) é o provisionador de cluster local a usar — não há `k3d`
  disponível.
- Por padrão, **todo cluster kind entra na mesma rede docker `kind`**
  (subnet `172.18.0.0/16`), o que faz os dois clusters se enxergarem
  diretamente como se estivessem na mesma LAN — isso não simula "conectados
  via internet". Para simular de verdade a separação, cada cluster vai para
  a sua **própria rede docker isolada** (`net-skupper-a`, `net-skupper-b`),
  criada com `docker network create` (operação padrão do Docker, o mesmo
  mecanismo que já cria a rede `kind` compartilhada hoje — não é uma
  alteração na configuração de rede do host, é só mais uma rede virtual
  gerenciada pelo Docker). Cada cluster é preso à sua rede via a variável
  `KIND_EXPERIMENTAL_DOCKER_NETWORK` (confirmada como real e configurável
  por invocação — `KIND_EXPERIMENTAL_DOCKER_NETWORK=net-skupper-a kind
  create cluster ...`). Por padrão, o Docker **já isola** redes diferentes
  entre si — não é preciso nenhuma regra extra para obter esse isolamento,
  só para *não* remover o padrão.
- `kind` não implementa `Service type=LoadBalancer` nativamente (fica
  `<pending>`). **[REV3]** Em vez de instalar MetalLB (que exigiria uma rede
  L2 compartilhada e tornaria a simulação de "internet" mais frágil), o
  cluster A expõe seu endpoint via **`extraPortMappings`** do kind — o
  mesmo mecanismo declarativo que o kind já usa para publicar a porta da
  API do Kubernetes no host (`docker run -p hostPort:containerPort`, gerido
  inteiramente pelo Docker, sem `sudo iptables` da nossa parte). Como o
  Service fica `<pending>` mas ainda aloca um `NodePort` (comportamento
  padrão de `type=LoadBalancer` no Kubernetes), fixamos esse NodePort num
  valor conhecido (`kubectl patch`) e o publicamos no host através de uma
  porta reservada de antemão no `kind/skupper-a.kind.yaml`.
- O CNI padrão do kind (`kindnet`) **não aplica NetworkPolicy**. Para a
  prova de unidirecionalidade em profundidade (`11-validate-unidirectional.sh`)
  ser significativa, o cluster A precisa trocar para **Calico** como CNI —
  isso é 100% dentro do cluster (CNI dos pods), não mexe na rede do host.
- Skupper já criptografa e autentica os links por padrão via **mTLS**
  (certificados gerados e trocados automaticamente no `token issue`/`token
  redeem`) — isso atende ao requisito de "conexão segura" sem configuração
  extra. O plano inclui um passo explícito para *provar* isso.

O objetivo final é montar, em `/arquivos/git/outros/poc-skupper`, um
repositório reproduzível (scripts + manifests + README), tudo orquestrado
por um `Makefile`, que qualquer um consiga rodar do zero para reproduzir a
PoC — sem exigir privilégios de root nem tocar na configuração de rede da
máquina.

## Mapeamento v1 → v2 (referência para os scripts)

| Conceito do roteiro original | v1 (colado) | v2 (real, instalado) |
|---|---|---|
| Instalar controller | *(implícito no CLI)* | `helm install skupper oci://quay.io/skupper/helm/skupper --version 2.1.1 -n skupper --create-namespace` (novo passo, 1x por cluster) |
| Inicializar site expondo endpoint | `skupper init --ingress loadbalancer` | `skupper site create <nome> --enable-link-access --link-access-type loadbalancer` + NodePort fixado e publicado via `extraPortMappings` do kind (sem MetalLB) |
| Inicializar site "cliente" | `skupper init` | `skupper site create <nome>` |
| Gerar token | `skupper token create` | `skupper token issue <file>` + reescrita do host/porta embutido no arquivo antes de copiá-lo para B **[REV3]** |
| Consumir token / criar link | `skupper link create <file>` | `skupper token redeem <file>` (não existe `skupper link create` no v2) |
| Status do link | `skupper link status` | `skupper link status` (igual) |
| Expor serviço (1 sentido) | `kubectl annotate service ... skupper.io/proxy=http skupper.io/port=...` | `skupper connector create <nome> <porta> --workload deployment/<nome>` (lado que possui o workload) + `skupper listener create <nome> <porta>` (lado consumidor) |
| Expor serviço (os dois sentidos) | *(não coberto no roteiro original)* | Repetir o par connector/listener acima **nos dois clusters, com routing-keys diferentes** (`svc-a` e `svc-b`) |
| Revogar link | `skupper link delete <nome>` | `skupper link delete <nome>` (igual, nome via `link status -o yaml`) |
| Segurança da conexão | *(nenhuma menção)* | Skupper já usa mTLS por padrão; validação explícita via Secret + `openssl s_client` |
| Simular clusters "via internet" **[REV3]** | *(clusters assumidos já roteáveis entre si)* | Duas redes docker isoladas + `extraPortMappings` do kind publicando só a porta do site A no host — nenhum comando de firewall/iptables manual |
| Simular queda de rede **[REV3]** | *(não coberto)* | `docker network disconnect/connect` no container do node de B (operação padrão do Docker CLI sobre um container da própria PoC, não uma mudança na rede do host) |

## Arquitetura de rede (simulação "via internet", sem tocar no host)

```
 net-skupper-a (isolada)                    net-skupper-b (isolada)
 ┌───────────────────────────────┐          ┌───────────────────────────────┐
 │  cluster skupper-a             │          │  cluster skupper-b             │
 │  - Calico (NetworkPolicy real) │          │  - kindnet (padrão)             │
 │  - site-a --enable-link-access │          │  - site-b (sem exposição)      │
 │    Service LoadBalancer        │          │                                 │
 │    (pending, mas com NodePort  │          │  - connector svc-b (echo-b)    │
 │    fixo publicado no host)     │          │  - listener  svc-a             │
 │  - connector svc-a (echo-a)    │          │                                 │
 │  - listener  svc-b             │          │                                 │
 └───────────────┬────────────────┘          └────────────────┬───────────────┘
                 │ extraPortMappings do kind                   │
                 │ (hostPort fixo, ex.: 30671)                 │
                 │ publicado via docker -p (automático)        │
                 └───────────────────► HOST ◄───────────────────┘
                            (qualquer container em net-skupper-b já
                             alcança portas publicadas no host — é
                             comportamento padrão do Docker, nenhuma
                             regra extra necessária)
```

- Cluster A nunca disca para fora: só recebe. O único caminho de entrada é a
  porta publicada no host pelo `extraPortMappings`; fora dela, as duas redes
  continuam isoladas pelo comportamento padrão do Docker (nada precisa ser
  configurado para obter esse isolamento — só não se conecta as duas redes
  manualmente).
- Cluster B só conhece o endereço publicado no host (equivalente ao "IP
  público" de A), nunca a rede interna real de A.
- Como o token gerado por `skupper token issue` embutiria por padrão o
  endereço interno do Service (não roteável a partir de `net-skupper-b`),
  o script de link reescreve esse campo no arquivo YAML do token para
  apontar para `<gateway-de-net-skupper-b>:<hostPort>` antes do `redeem` em
  B — o exato campo a editar será confirmado inspecionando um token real
  gerado na implementação (ver "Riscos" abaixo).
- Uma vez que o link é estabelecido (B discou para A), a conexão TCP/TLS
  resultante é bidirecional — por isso A consegue expor `svc-a` para B e
  também consumir `svc-b` de B pela mesma ligação, sem nunca precisar de
  rota de saída própria.

## Layout do repositório

```
poc-skupper/
├── PLAN.md                            # este arquivo
├── README.md                          # narrativa completa, diagrama, ordem de execução, cleanup
├── .gitignore                         # tokens, .tmp/, metrics/results-*.csv
├── Makefile                           # up / validate / test-tls / test-unidirectional / metrics / test-network-drop / test-revocation / relink / down
├── kind/
│   ├── skupper-a.kind.yaml            # 1 control-plane, disableDefaultCNI: true, podSubnet 192.168.0.0/16, extraPortMappings (hostPort fixo)
│   └── skupper-b.kind.yaml            # 1 control-plane, kindnet padrão
├── networkpolicy/
│   └── skupper-a-deny-egress.yaml     # egress-deny no namespace do router/controller, cluster A (defesa em profundidade)
├── workload/
│   ├── echo-a.deployment.yaml         # hashicorp/http-echo em A, -text="hello from A"
│   └── echo-b.deployment.yaml         # hashicorp/http-echo em B, -text="hello from B"
├── scripts/
│   ├── lib.sh                         # helpers (contexto, wait-for, log)
│   ├── 00-preflight.sh                # versões, colisão de nomes de cluster/rede
│   ├── 01-create-networks.sh          # cria net-skupper-a e net-skupper-b (docker network create, isoladas por padrão)
│   ├── 02-create-clusters.sh          # kind create cluster x2, cada um preso à sua rede via KIND_EXPERIMENTAL_DOCKER_NETWORK
│   ├── 03-install-calico.sh           # Calico só em skupper-a
│   ├── 04-install-skupper-controller.sh  # helm install nos dois clusters, versão 2.1.1 fixada
│   ├── 05-create-sites.sh             # cria namespace app nos dois; site create: A com --enable-link-access (--wait configured), B sem (--wait ready)
│   ├── 06-pin-site-nodeport.sh        # kubectl patch no Service de A: fixa o NodePort no valor reservado em extraPortMappings
│   ├── 07-link-clusters.sh            # token issue (A) -> reescreve endpoint no YAML -> token redeem (B) -> link status
│   ├── 08-deploy-workloads.sh         # deploy echo-a (A) e echo-b (B); connector+listener nos dois sentidos
│   ├── 09-validate-e2e.sh             # curl nos dois sentidos: B->svc-a e A->svc-b
│   ├── 10-validate-tls.sh             # confirma mTLS: inspeciona Secret de TLS + openssl s_client no endpoint publicado
│   ├── 11-validate-unidirectional.sh  # NetworkPolicy egress-deny em A (defesa em profundidade) + controle negativo
│   ├── 12-collect-metrics.sh          # metrics-server + latência p50/p99 (local vs cross-cluster) + CSV — roda com o link ainda ativo
│   ├── 13-simulate-network-drop.sh    # docker network disconnect/connect no node de skupper-b, mede reconexão — link termina ativo de novo
│   ├── 14-test-link-revocation.sh     # skupper link delete, confirma perda de rota nos dois sentidos — teste destrutivo, roda por último
│   └── 99-teardown.sh                 # helm uninstall, kind delete cluster x2, remove as redes docker
├── metrics/
│   └── .gitkeep
└── docs/
    └── v1-to-v2-mapping.md
```

## Sequência de execução (o que cada script faz)

1. **`01-create-networks.sh`** — `docker network create net-skupper-a` e `docker network create net-skupper-b`. Nenhuma delas conectada à outra nem à rede `kind` padrão — isolamento é o comportamento padrão do Docker para redes diferentes, não uma configuração extra.

2. **`02-create-clusters.sh`** — cada cluster preso à sua própria rede:
   `KIND_EXPERIMENTAL_DOCKER_NETWORK=net-skupper-a kind create cluster --name skupper-a --config kind/skupper-a.kind.yaml`
   (idem para B/net-skupper-b). `kind/skupper-a.kind.yaml` já reserva um `extraPortMappings` fixo (ex.: hostPort 30671) para o endpoint do Skupper.

3. **`03-install-calico.sh`** (só skupper-a) — Tigera operator + custom-resources (`v3.32.1`), pod CIDR `192.168.0.0/16` já casando com `kind/skupper-a.kind.yaml`.

4. **`04-install-skupper-controller.sh`** (ambos) — `helm install skupper oci://quay.io/skupper/helm/skupper --version 2.1.1 -n skupper --create-namespace --kube-context <ctx>`.

5. **`05-create-sites.sh`** — cria o namespace `app` nos dois clusters; `skupper site create site-a --enable-link-access --link-access-type loadbalancer --wait configured` em A (o Service fica `<pending>` mas já tem um `NodePort` alocado — usamos `--wait configured` em vez do padrão `--wait ready` porque "ready" pode nunca ser satisfeito sem um provedor de LoadBalancer real, e não queremos o script travando à espera de um IP externo que nunca vai aparecer); `skupper site create site-b --wait ready` em B (sem nenhuma flag de exposição — aqui "ready" é seguro pois não depende de nenhum endpoint externo).

6. **`06-pin-site-nodeport.sh`** — identifica o Service criado pelo Skupper em A (`kubectl get svc -n app`), faz `kubectl patch` para fixar o `nodePort` no mesmo valor já reservado no `extraPortMappings` do `kind/skupper-a.kind.yaml` (ex.: 30671). Isso não é uma mudança de rede do host, é um objeto Kubernetes dentro do próprio cluster A.

7. **`07-link-clusters.sh`** — `skupper token issue .tmp/site-a-token.yaml` em A; script lê o arquivo gerado e reescreve o host/porta do endpoint embutido para `<gateway de net-skupper-b>:30671` (endereço pelo qual containers em `net-skupper-b` alcançam portas publicadas no host); `skupper token redeem .tmp/site-a-token.yaml` em B; `skupper link status` nos dois lados confirmando `connected`.

8. **`08-deploy-workloads.sh`** — bidirecional:
   - Em A: `Deployment echo-a` (`hashicorp/http-echo -text="hello from A"`); `skupper connector create svc-a 8080 --workload deployment/echo-a`; `skupper listener create svc-b 8080`.
   - Em B: `Deployment echo-b` (`-text="hello from B"`); `skupper connector create svc-b 8080 --workload deployment/echo-b`; `skupper listener create svc-a 8080`.
   - Routing-keys diferentes (`svc-a`, `svc-b`) evitam colisão já que os dois lados têm connector *e* listener ao mesmo tempo.

9. **`09-validate-e2e.sh`** — dois curls:
   - de B: `curl http://svc-a:8080/` → espera `hello from A`
   - de A: `curl http://svc-b:8080/` → espera `hello from B`
   Prova o requisito "cada cluster expõe um serviço acessado pelo outro" com uma ligação estabelecida só num sentido. Cada verificação imprime `PASS:`/`FAIL:` e o script sai com código != 0 se qualquer uma falhar (é o que faz `make`/CI conseguirem detectar regressão, não só um humano lendo o log).

10. **`10-validate-tls.sh`** — prova que a conexão é autenticada/criptografada:
    - `kubectl --context kind-skupper-a -n skupper get secret` mostra o Secret de TLS gerado pelo `token issue` (emitido pela CA interna do site).
    - `openssl s_client -connect <gateway-net-skupper-b>:30671 -brief` a partir de um pod em `net-skupper-b`, confirmando handshake TLS e mostrando o certificado apresentado.
    - Controle negativo: repetir sem o certificado de cliente emitido pelo token e confirmar que a autenticação mútua rejeita a conexão.
    - Mesmo padrão `PASS:`/`FAIL:` + exit code do passo anterior.

11. **`11-validate-unidirectional.sh`** — (defesa em profundidade, além do isolamento de rede) aplica `networkpolicy/skupper-a-deny-egress.yaml` no namespace `skupper` de A; repete os dois curls do passo 9 (devem continuar OK); roda um curl de dentro do router de A para um IP público (ex. `1.1.1.1`) como controle negativo — deve falhar, provando que a policy é real (Calico, não kindnet). O link continua ativo depois deste passo. Mesmo padrão `PASS:`/`FAIL:` + exit code.

12. **`12-collect-metrics.sh`** — precisa do link ainda ativo, por isso roda **antes** dos testes destrutivos/disruptivos: `metrics-server` (com `--kubelet-insecure-tls`); loop de requisições medindo `curl -w '%{time_total}'` cross-cluster vs. uma instância local de echo dentro do mesmo cluster, p50/p99; `kubectl top pod` do `skupper-router` nos dois clusters; tudo em `metrics/results-<timestamp>.csv`.

13. **`13-simulate-network-drop.sh`** — `docker network disconnect net-skupper-b skupper-b-control-plane`, aguarda e observa `skupper link status` reportar a queda (via `kubectl`/`skupper` no contexto A, que continua acessível já que só a rede de B foi desconectada); depois `docker network connect net-skupper-b skupper-b-control-plane` e mede o tempo até `connected` de novo. Efeito colateral aceito: durante a queda, `kubectl`/`skupper` no contexto B também ficam inacessíveis (a única interface de rede do node de B foi removida) — documentado no README como a limitação esperada dessa abordagem "sem tocar no host". Termina com o link ativo de novo.

14. **`14-test-link-revocation.sh`** — **último teste, é destrutivo**: `skupper link delete <nome>` (nome via `link status -o yaml`), confirma que os dois Services (`svc-a` em B e `svc-b` em A) perdem endpoints e ambos os curls passam a falhar. Roda por último de propósito — nada depois dele (além do teardown) precisa do link.

15. **`99-teardown.sh`** — `helm uninstall` nos dois clusters, `kind delete cluster` nos dois, `docker network rm net-skupper-a net-skupper-b`.

## Validação — targets do `Makefile`

Sim, tem validação explícita, com comando `make` para cada uma. Não é só
"rodar e olhar o log" — cada script de validação imprime `PASS:`/`FAIL:` por
verificação e termina com exit code != 0 se algo falhar, então `make`
também falha visivelmente (útil para rodar em CI depois, se quiser).

| Comando | Roda | O que prova |
|---|---|---|
| `make up` | scripts `00`→`09` | Clusters no ar, link Skupper `connected`, e o requisito central: **cada cluster expõe um serviço que o outro consegue chamar** (curl nos dois sentidos) |
| `make validate` | `09` + `10` + `11` de novo, sem recriar nada | Revalidação rápida e não-destrutiva: e2e bidirecional, mTLS, e unidirecionalidade (NetworkPolicy) — para rodar quantas vezes quiser depois do `make up` |
| `make test-tls` | só `10` | Conexão é segura: mTLS de verdade (rejeita conexão sem certificado de cliente) |
| `make test-unidirectional` | só `11` | Unidirecionalidade em profundidade: mesmo com egress bloqueado por NetworkPolicy em A, o tráfego dos dois sentidos continua OK (conexão já estabelecida), e A não consegue iniciar conexão nova para fora |
| `make metrics` | só `12` | Gera `metrics/results-<timestamp>.csv` com latência p50/p99 e uso de CPU/mem do router |
| `make test-network-drop` | só `13` | Reconexão automática depois de uma queda de rede simulada — não é destrutivo, termina com o link ativo de novo |
| `make test-revocation` | só `14` | Revogação limpa do link — **destrutivo**, deixa o ambiente sem link no final |
| `make relink` | reexecuta só `07` | Restabelece o link depois de um `make test-revocation`, sem recriar clusters/sites — útil para voltar a testar sem rodar `make up` do zero |
| `make down` | `99` | Remove os 2 clusters e as 2 redes docker |

`make up` sozinho já é a prova de ponta a ponta do requisito principal. Os
demais targets são validações adicionais e independentes, na ordem em que
fazem sentido rodar (a razão de `test-network-drop` vir antes de
`test-revocation` está documentada nos Riscos abaixo).

## Riscos conhecidos (verificar durante a implementação)

- **Campo a editar no token**: ainda não inspecionamos um `skupper token issue` real. Precisamos gerar um token de teste cedo (logo após o passo 7) para confirmar o(s) campo(s) exato(s) (host/porta) a reescrever antes do `redeem`. Se o formato não permitir edição direta e simples, pode ser necessário um passo intermediário (ex.: usar `yq`).
- **`KIND_EXPERIMENTAL_DOCKER_NETWORK`** é rotulado "experimental" pelo projeto kind — confirmado que existe e é configurável por invocação, mas sem garantia formal de suporte contínuo. Fallback caso se comporte mal: `docker network disconnect kind <container> && docker network connect net-skupper-x <container>` manualmente após o `kind create cluster`.
- **NodePort fixo via `kubectl patch`**: o Service criado pelo `skupper site create --link-access-type loadbalancer` pode ter mais de uma porta (ex.: inter-router + edge). O patch precisa mirar a porta certa por nome, não sobrescrever o array inteiro — confirmar a estrutura real do Service na implementação. Além disso, como esse Service é gerenciado pelo controller do Skupper, é possível que uma reconciliação futura reverta o `nodePort` manual — se isso acontecer, o script precisa reaplicar o patch de forma idempotente (retry/loop) ou, em último caso, recriar o Service via `kubectl replace` logo após a criação do site.
- **Teste de TLS** (`10-validate-tls.sh`): o handshake e a rejeição sem certificado de cliente devem funcionar em princípio (é assim que o Skupper opera), mas a asserção exata via `openssl s_client` pode precisar de ajuste fino uma vez executado de verdade.
- **`kubectl run --rm -it`** em script não-interativo precisa virar `--rm -i --restart=Never` (detalhe de implementação, não de arquitetura).
- **Ordem dos testes finais**: métricas (`12`) e queda de rede (`13`) precisam do link ativo, então rodam antes da revogação (`14`), que é destrutiva e termina a PoC funcional — só o teardown (`99`) vem depois dela. Essa ordem já foi corrigida nesta revisão (antes a revogação vinha no meio, quebrando as duas etapas seguintes).
- Nenhum passo deste plano requer `sudo` ou root no host.

## Checklist

### Scaffolding do repositório

- [ ] Criar estrutura de diretórios (`kind/`, `networkpolicy/`, `workload/`, `scripts/`, `metrics/`, `docs/`)
- [ ] `.gitignore` (tokens, `.tmp/`, `metrics/results-*.csv`)
- [ ] `kind/skupper-a.kind.yaml` (Calico habilitado, podSubnet 192.168.0.0/16, extraPortMappings com hostPort fixo)
- [ ] `kind/skupper-b.kind.yaml` (config padrão, kindnet)
- [ ] `scripts/lib.sh`
- [ ] `scripts/00-preflight.sh`
- [ ] `scripts/01-create-networks.sh`
- [ ] `scripts/02-create-clusters.sh` (com `KIND_EXPERIMENTAL_DOCKER_NETWORK` por cluster)
- [ ] `scripts/03-install-calico.sh`
- [ ] `scripts/04-install-skupper-controller.sh`
- [ ] `scripts/05-create-sites.sh`
- [ ] `scripts/06-pin-site-nodeport.sh`
- [ ] `scripts/07-link-clusters.sh` (token issue + reescrita do endpoint + redeem)
- [ ] `workload/echo-a.deployment.yaml`, `workload/echo-b.deployment.yaml`
- [ ] `scripts/08-deploy-workloads.sh` (bidirecional: connector+listener nos dois clusters)
- [ ] `scripts/09-validate-e2e.sh` (curl nos dois sentidos)
- [ ] `scripts/10-validate-tls.sh`
- [ ] `networkpolicy/skupper-a-deny-egress.yaml`
- [ ] `scripts/11-validate-unidirectional.sh`
- [ ] `scripts/12-collect-metrics.sh`
- [ ] `scripts/13-simulate-network-drop.sh` (docker network disconnect/connect)
- [ ] `scripts/14-test-link-revocation.sh` (teste destrutivo, roda por último)
- [ ] `scripts/99-teardown.sh`
- [ ] `Makefile` (up / validate / test-tls / test-unidirectional / metrics / test-network-drop / test-revocation / relink / down)
- [ ] `docs/v1-to-v2-mapping.md`
- [ ] `README.md`

### Execução da PoC

- [ ] `make up` (scripts 00→09) — link "connected" + curl nos dois sentidos retornando o texto certo
- [ ] `10-validate-tls.sh` — confirma mTLS (handshake + rejeição sem cert de cliente)
- [ ] `11-validate-unidirectional.sh` — NetworkPolicy em profundidade + controle negativo
- [ ] `12-collect-metrics.sh` — CSV gerado (link ainda ativo)
- [ ] `13-simulate-network-drop.sh` — tempo de reconexão registrado (link ainda ativo depois)
- [ ] `14-test-link-revocation.sh` — revogação limpa nos dois sentidos (por último, destrutivo)
- [ ] `99-teardown.sh` — clusters e redes docker removidos
