# Mapeamento Skupper v1 → v2

O roteiro original que serviu de ponto de partida para esta PoC foi escrito
para o Skupper v1. O CLI instalado nesta máquina é o **v2.1.1**
(controller 2.1.1, router 3.4.0), com uma sintaxe e um modelo operacional
bem diferentes (CRDs Kubernetes-nativas em vez de anotações + estado local).

| Conceito do roteiro original | v1 (colado) | v2 (real, instalado) |
|---|---|---|
| Instalar controller | *(implícito no CLI)* | `helm install skupper oci://quay.io/skupper/helm/skupper --version 2.1.1 -n skupper --create-namespace` (novo passo, 1x por cluster) |
| Inicializar site expondo endpoint | `skupper init --ingress loadbalancer` | `skupper site create <nome> --enable-link-access --link-access-type loadbalancer` + NodePort fixado e publicado via `extraPortMappings` do kind (sem MetalLB) |
| Inicializar site "cliente" | `skupper init` | `skupper site create <nome>` |
| Gerar token | `skupper token create` | `skupper token issue <file>` + reescrita do host/porta embutido no arquivo antes de copiá-lo para B |
| Consumir token / criar link | `skupper link create <file>` | `skupper token redeem <file>` (não existe `skupper link create` no v2) |
| Status do link | `skupper link status` | `skupper link status` (igual) |
| Expor serviço (1 sentido) | `kubectl annotate service ... skupper.io/proxy=http skupper.io/port=...` | `skupper connector create <nome> <porta> --workload deployment/<nome>` (lado que possui o workload) + `skupper listener create <nome> <porta>` (lado consumidor) |
| Expor serviço (os dois sentidos) | *(não coberto no roteiro original)* | Repetir o par connector/listener acima nos dois clusters, com routing-keys diferentes (`svc-a` e `svc-b`) |
| Revogar link | `skupper link delete <nome>` | `skupper link delete <nome>` (igual, nome via `link status -o yaml`) |
| Segurança da conexão | *(nenhuma menção)* | Skupper já usa mTLS por padrão; validação explícita via Secret + `openssl s_client` |
| Simular clusters "via internet" | *(clusters assumidos já roteáveis entre si)* | Duas redes docker isoladas + `extraPortMappings` do kind publicando só a porta do site A no host - nenhum comando de firewall/iptables manual |
| Simular queda de rede | *(não coberto)* | `docker network disconnect/connect` no container do node de B |

## Por que a mudança de modelo importa

No v1, o estado do Skupper vivia em objetos ad-hoc (ConfigMaps, anotações em
Services) manipulados diretamente pelo CLI. No v2, tudo é modelado como CRDs
Kubernetes (`Site`, `AccessToken`/`AccessGrant`, `Link`, `Connector`,
`Listener`) reconciliadas por um controller — o CLI é só um client fino que
cria/lê esses objetos. Isso muda a forma de:

- **Diagnosticar problemas**: em vez de logs do CLI, o caminho é
  `kubectl get site,link,connector,listener -n app -o yaml` e o `status`
  de cada CRD.
- **Automatizar**: os scripts desta PoC preferem `kubectl wait`/`kubectl get
  -o jsonpath` sobre logs do CLI sempre que possível, porque refletem o
  estado reconciliado de verdade.
