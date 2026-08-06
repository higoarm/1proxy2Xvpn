# 1proxy2Xvpn

**🌐 Idioma / Language:** [English](README.md) · Português

[![CI](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/ci.yml/badge.svg)](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/ci.yml)
[![Security](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/security.yml/badge.svg)](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Infraestrutura de proxy HTTP/SOCKS5 distribuída** — um container isolado por túnel OpenVPN, com Kill Switch endurecido, balanceamento de carga inteligente e observabilidade completa. Construída para pesquisa de segurança autorizada e operações de Bug Bounty em escala.

```
Cliente → smart_router → HAProxy :9999 → tinyproxy :3128 → tun0 (OpenVPN) → IP da VPN → Internet
             (retry)      (load balance)   (proxy HTTP)    (Kill Switch)
```

---

## Por que este projeto existe

Profissionais de segurança que executam avaliações autorizadas em larga escala precisam de:

- **Diversidade de IPs** para contornar limites de taxa por IP sem violar as políticas do programa
- **Distribuição geográfica** para validação de alvos com restrição geográfica
- **Isolamento** para que um único proxy comprometido não vaze credenciais dos outros
- **Confiabilidade** na escala de centenas de conexões simultâneas
- **Observabilidade** para saber exatamente quais IPs foram queimados, quando e por quê

O `1proxy2Xvpn` fornece tudo isso com padrões endurecidos, um fluxo de trabalho via CLI e uma camada de operações pronta para produção.

---

## ⚠️ Uso ético

Esta ferramenta destina-se **exclusivamente a testes de segurança autorizados**: programas de Bug Bounty (HackerOne, Intigriti, Bugcrowd), Programas de Divulgação de Vulnerabilidades (VDP), testes de penetração autorizados e pesquisa acadêmica com o devido consentimento.

**Nunca teste sistemas que você não possui ou não tenha permissão explícita por escrito para avaliar.** O uso não autorizado pode violar leis de crimes informáticos na sua jurisdição.

---

## Recursos

### Arquitetura
- **Um container por endpoint de VPN** — isolamento total entre túneis
- **Containers endurecidos** — sem `--privileged`, capacidades mínimas do Linux
- **Kill Switch no boot** — regra `iptables` de negação por padrão aplicada antes de qualquer serviço iniciar
- **Prevenção de vazamento de DNS** — hostnames pré-resolvidos, sem caminho de DNS de bootstrap
- **HTTP + SOCKS5** — ambos os protocolos disponíveis por container (tinyproxy + dante-server)
- **Anti-fingerprint** — páginas de erro higienizadas, cabeçalhos identificadores removidos

### Operações
- **CLI unificada** — um único comando `1proxy2xvpn` para todas as operações
- **Autodescoberta** — a configuração do HAProxy é regerada a partir dos containers em execução
- **Pools regionais** — agrupamento automático por código de país no nome do arquivo
- **API de blacklist** — desabilite IPs queimados sem reiniciar a infraestrutura
- **Middleware de retry inteligente** — rotação automática de IP em 403/429/451

### Observabilidade
- **Métricas Prometheus** — por container, HAProxy, host
- **Dashboards Grafana** — visão geral pronta com throughput, latência e saúde
- **Agregação de logs Loki** — logs centralizados dos containers (stack completa)
- **Alertmanager** — alertas críticos para Discord/Slack/e-mail (stack completa)
- **cAdvisor** — métricas de host e containers

> A stack padrão (lite) executa Prometheus + Grafana + cAdvisor. Para logs
> centralizados e alertas, use a stack completa: `./1proxy2xvpn observability up full`.

### DevSecOps
- **Pipelines de CI** — shellcheck, hadolint, yamllint, ruff
- **Varreduras de segurança** — Trivy (CVEs), Gitleaks (segredos) a cada push
- **Builds multi-arquitetura** — amd64 + arm64 via GitHub Actions
- **Pre-commit hooks** — captura problemas antes que cheguem ao git

---

## Requisitos

| Componente | Mínimo | Recomendado |
|-----------|---------|-------------|
| SO | Kernel Linux 5.x | Kernel Linux 6.x |
| CPU | 4 núcleos | 16 núcleos |
| RAM | 8 GB | 32 GB |
| Disco | 40 GB SSD | 100 GB SSD |
| Rede | 100 Mbps | 1 Gbps |
| Docker | 20.10 | 24.x |
| HAProxy | 2.4 | 2.8+ |

Para 300+ containers, veja as [configurações de host recomendadas](https://github.com/higoarm/1proxy2Xvpn/blob/main/docs/PERFORMANCE.md#recommended-host-configurations) em `docs/PERFORMANCE.md`.

---

## Início rápido

```bash
# 1. Clone e entre no diretório
git clone https://github.com/higoarm/1proxy2Xvpn.git
cd 1proxy2Xvpn

# 2. (Opcional) Instale a CLI globalmente para chamá-la como `1proxy2xvpn`
#    de qualquer lugar. Se pular esta etapa, execute como `./1proxy2xvpn` a
#    partir do diretório do projeto (como mostrado em todos os exemplos abaixo).
sudo ln -sf "$(pwd)/1proxy2xvpn" /usr/local/bin/1proxy2xvpn

# 3. Execute o setup (instala Docker, HAProxy, ajusta o kernel)
sudo ./1proxy2xvpn setup

# 4. Adicione seus arquivos .ovpn
cp /caminho/para/seus/*.ovpn ovpns/

# 5. Construa a imagem
./1proxy2xvpn build

# 6. Suba todos os containers
./1proxy2xvpn up

# 7. Aguarde ~60s para as VPNs conectarem, depois configure o HAProxy
sudo ./1proxy2xvpn haproxy --only-up

# 8. Teste — 10 requisições devem mostrar IPs de saída rotacionando
for i in {1..10}; do curl -s -x http://localhost:9999 https://api.ipify.org; echo; done
```

---

## Referência da CLI

> Execute a CLI como `./1proxy2xvpn` a partir do diretório do projeto. Se você
> a instalou globalmente (etapa 2 do Início rápido), pode omitir o `./` e chamar
> `1proxy2xvpn` de qualquer lugar.

```
./1proxy2xvpn setup                    Instala dependências, ajusta o kernel, prepara o host
./1proxy2xvpn build [--no-cache]       Constrói a imagem Docker
./1proxy2xvpn up                       Sobe os containers (um por .ovpn)
./1proxy2xvpn down                     Para e remove todos os containers
./1proxy2xvpn destroy [--purge]        Desmonta tudo (--purge também remove a imagem)

./1proxy2xvpn haproxy [--dry-run] [--only-up] [--public-stats]
                                     Gera o haproxy.cfg a partir dos containers em execução

./1proxy2xvpn status [--json|--csv]    Mostra o status de todos os containers
./1proxy2xvpn logs [container|all]     Exibe os logs
./1proxy2xvpn rotate [container|--burned]  Força rotação de IP

./1proxy2xvpn blacklist add <nome|ip>  Desabilita o container na rotação do HAProxy
./1proxy2xvpn blacklist remove <nome|ip>  Restaura o container
./1proxy2xvpn blacklist list           Lista os containers em blacklist
./1proxy2xvpn blacklist clear          Restaura todos

./1proxy2xvpn observability up         Sobe Prometheus + Grafana + cAdvisor (use `full` para logs)
./1proxy2xvpn observability down       Para a stack de observabilidade
```

---

## Arquitetura

```
                                    MÁQUINA HOST
 ┌────────────────────────────────────────────────────────────────────────────┐
 │                                                                            │
 │   Cliente ──► smart_router :9888 ──► HAProxy :9999 / :9998 (SOCKS5)       │
 │              (retry em 403/429)      │                                     │
 │                                      │  balance roundrobin + health check  │
 │            ┌──────────────┬──────────┴──────────┬──────────────┐          │
 │            │              │                     │              │          │
 │         :3100/3101    :3102/3103            :3104/3105     :310N          │
 │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐          │
 │  │ tinyproxy  │  │ tinyproxy  │  │ tinyproxy  │  │ tinyproxy  │          │
 │  │  dante     │  │  dante     │  │  dante     │  │  dante     │          │
 │  │────────────│  │────────────│  │────────────│  │────────────│          │
 │  │   tun0     │  │   tun0     │  │   tun0     │  │   tun0     │          │
 │  │  OpenVPN   │  │  OpenVPN   │  │  OpenVPN   │  │  OpenVPN   │          │
 │  │────────────│  │────────────│  │────────────│  │────────────│          │
 │  │ Kill Switch│  │ Kill Switch│  │ Kill Switch│  │ Kill Switch│          │
 │  │  iptables  │  │  iptables  │  │  iptables  │  │  iptables  │          │
 │  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘          │
 └─────────┼───────────────┼───────────────┼───────────────┼─────────────────┘
           │               │               │               │
        IP VPN 1        IP VPN 2        IP VPN 3        IP VPN N
        US               BR              DE              JP
           │               │               │               │
 ┌─────────┴───────────────┴───────────────┴───────────────┴─────────────────┐
 │                              INTERNET                                      │
 └────────────────────────────────────────────────────────────────────────────┘

 Sidecar de observabilidade (opcional):
    Prometheus → Grafana (dashboards)
    Loki ← Promtail (logs dos containers)      [stack completa]
    Alertmanager → Discord/Slack/e-mail        [stack completa]
```

Veja `docs/ARCHITECTURE.md` para detalhes técnicos aprofundados.

---

## Casos de uso

| Caso de uso | Descrição |
|---|---|
| Rotação distribuída de IPs | Contornar limites de taxa sem violar o escopo do programa |
| Testes de força bruta | Teste autorizado de credenciais dentro do escopo do programa |
| Enumeração de usuários e recursos | Enumeração de IDs/endpoints em larga escala |
| Descoberta de IDOR | Testar padrões de referência de objetos de muitas origens |
| Validação de restrição geográfica | Verificar controles de acesso por região |
| Pesquisa de evasão de WAF | Medir limiares de detecção e padrões de bypass |
| Testes de abuso de lógica de negócio | Condições de corrida, reuso de cupom, etc. |
| Crawling distribuído | Reconhecimento sem estrangulamento por IP |
| Validação de limite de taxa de API | Quantificar controles defensivos |
| Análise defensiva | Mapear padrões de detecção de WAFs de produção |

---

## Observabilidade

Suba a stack:

```bash
./1proxy2xvpn observability up
```

Acesse:

- **Grafana**: <http://localhost:3000> (credenciais padrão em `.env.example`)
- **Prometheus**: <http://localhost:9090>

O dashboard pronto mostra:

- Percentual de saúde do pool de VPNs
- Contagem de containers ativos
- Requisições por segundo
- Latência no percentil 95
- CPU e memória por container
- Throughput de rede (TX/RX)
- Estado dos backends de VPN ao longo do tempo

> Alertas (via Alertmanager) estão disponíveis na stack completa
> (`./1proxy2xvpn observability up full`): HAProxy fora do ar, mais de 50% dos
> backends indisponíveis, latência alta, RAM baixa no host, esgotamento de
> descritores de arquivo e loops de reinício de containers.

---

## Integração com ferramentas de segurança

### Nuclei (varredura HTTP)

```bash
# Templates HTTP via proxy (com rotação)
nuclei -u target.com -proxy http://localhost:9999 \
  -type http \
  -exclude-tags proxy,fingerprint \
  -exclude-id tinyproxy-detect,squid-detect

# DNS/SSL/WHOIS — direto (sem proxy)
nuclei -u target.com -type dns,ssl,whois
```

### Burp Suite / Caido

```
User options → Connections → Upstream Proxy Servers
  Destination host: *
  Proxy host: 127.0.0.1
  Proxy port: 9999 (HTTP) ou 9998 (SOCKS5)
```

### ffuf

```bash
ffuf -u "https://target.com/FUZZ" \
     -w wordlist.txt \
     -x http://localhost:9999
```

### sqlmap (injeção de SQL)

```bash
# Roteia todo o tráfego do sqlmap pelo proxy HTTP — cada requisição rotaciona
# o IP, o que ajuda a evitar limites de taxa de WAF durante os testes de injeção.
sqlmap -u "https://target.com/item?id=1" \
       --proxy="http://localhost:9999" \
       -p id --batch --level 3 --risk 2

# Para SOCKS5 (ative primeiro com ENABLE_SOCKS5=true no `up`):
sqlmap -u "https://target.com/item?id=1" \
       --proxy="socks5://localhost:9998" \
       -p id --batch
```

### nmap (varredura de portas/serviços)

O nmap não suporta proxies HTTP, mas consegue tunelar varreduras TCP connect
pelo endpoint SOCKS5. Ative o SOCKS5 primeiro (`ENABLE_SOCKS5=true ./1proxy2xvpn up`):

```bash
# Varredura TCP connect através do pool SOCKS5 com rotação
nmap -sT -Pn -p 80,443,8080,8443 \
     --proxies socks5://localhost:9998 \
     target.com

# Detecção de serviço/versão através do proxy
nmap -sT -Pn -sV -p 443 \
     --proxies socks5://localhost:9998 \
     target.com
```

> Nota: `--proxies` funciona apenas com varreduras TCP connect (`-sT`).
> Varreduras SYN (`-sS`), UDP e detecção de SO ignoram o proxy e não são
> roteadas pelo pool de VPNs.

### Smart router (retry automático em 403/429)

```bash
# Em um terminal separado:
pip install -r middleware/requirements.txt
python middleware/smart_router.py

# Depois aponte as ferramentas para a porta 9888 em vez da 9999
nuclei -u target.com -proxy http://localhost:9888 ...
```

Veja `docs/INTEGRATIONS.md` para exemplos completos por ferramenta.

---

## Documentação

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Arquitetura técnica aprofundada
- [`docs/PROVIDERS.md`](docs/PROVIDERS.md) — Configuração por provedor de VPN (ExpressVPN, PIA, NordVPN, Mullvad)
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — Ajuste para 10 / 100 / 500 / 1000 containers
- [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) — Exemplos ferramenta por ferramenta
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — Catálogo completo de erros
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — Como contribuir

> Os documentos técnicos acima estão em inglês. Esta tradução cobre o README
> principal; contribuições para traduzir os demais documentos são bem-vindas.

---

## Implantação em produção

Para implantações de longa duração, use as units do systemd incluídas:

```bash
sudo cp -r . /opt/1proxy2xvpn
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now 1proxy2xvpn.service
sudo systemctl enable --now 1proxy2xvpn-router.service
```

---

## Licença

MIT — veja [LICENSE](LICENSE).

---

## Divulgação de segurança

Para relatar uma vulnerabilidade de segurança de forma privada, abra um
[GitHub security advisory](https://github.com/higoarm/1proxy2Xvpn/security/advisories/new)
ou entre em contato diretamente com o mantenedor, em vez de abrir uma issue
pública. Por favor, não divulgue os detalhes publicamente até que uma correção
esteja disponível.
