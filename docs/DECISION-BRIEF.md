# Decision Brief

> Append-only ADRs (Architecture Decision Records) do projeto.
> Gerenciado pela capability `decision-brief`.
> Veja `~/.cursor/skills/capabilities/decision-brief/decision-brief.md` para regras.

---

## Decision #ARCH-001 — Fila de jobs em Redis compartilhado

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, engenheiro-devops
- **Supersedes**: —

### Context

A API REST consumidora precisa invocar operações longas (`create`, `backup`, `remove`, lifecycle de usuários e apps) sem manter SSH/HTTP bloqueado por minutos. O servidor já possui `shared-redis` e a v12.0 deve evitar novo runtime.

### Alternatives considered

#### Redis lista + hashes no `shared-redis`
- **Pros**: reaproveita infraestrutura existente; `BRPOP` resolve pickup bloqueante; TTL/AOF cobrem retenção e durabilidade.
- **Cons**: compartilha capacidade com cache Nextcloud; operador precisa entender Redis em incidentes.

#### RabbitMQ/NATS dedicado
- **Pros**: semântica de fila mais rica; isolamento operacional.
- **Cons**: novo serviço crítico; NATS existente é parte do Talk/signaling e acoplar a fila de gestão aumentaria blast radius.

#### Status quo síncrono via SSH
- **Pros**: menor mudança.
- **Cons**: viola a meta de resposta <2s para API consumidora.

### Decision

Usar Redis DB 16 com `nc:jobs:queue`, `nc:jobs:<id>` e prefixos dedicados para fila, estado e idempotência.

### Rationale

O throughput esperado é baixo e a pilha atual já inclui Redis. A decisão prioriza operação simples e baixo acoplamento de stack, aceitando contenção mitigada por health checks e AOF.

### Consequences

`setup-shared.sh` habilita AOF; `manage.sh` e `worker.sh` dependem de `redis-cli`; troubleshooting de fila passa a ser parte do runbook v12.0.

---

## Decision #ARCH-002 — Worker systemd único e sequencial

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, engenheiro-devops
- **Supersedes**: —

### Context

Operações de provisionamento alteram arquivos e recursos globais (`signaling.conf`, allowlist Collabora, dbindex Redis, MariaDB) que não são transacionais.

### Alternatives considered

#### Um worker systemd com concorrência 1
- **Pros**: reduz race conditions; usa watchdog/restart do host; fácil de auditar em journald.
- **Cons**: limita throughput e cria fila visível em picos.

#### Pool de workers
- **Pros**: maior paralelismo.
- **Cons**: exigiria locking distribuído em todas as mutações globais.

#### Cron polling
- **Pros**: simples.
- **Cons**: latência alta e menos controle de lifecycle.

### Decision

Executar `scripts/worker.sh` como `nextcloud-saas-worker.service`, com `WORKER_CONCURRENCY=1`, `flock` e lock Redis.

### Rationale

Consistência é mais importante que paralelismo no v12.0. O gargalo aceitável é documentado e pode ser revisto se volume superar a hipótese de ~10 jobs longos/h.

### Consequences

O worker é ponto operacional central; health, logs e systemd unit precisam permanecer cobertos por testes e runbooks.

---

## Decision #ARCH-003 — Gateway SSH dedicado em vez de novo HTTP server

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, engenheiro-devops, security
- **Supersedes**: —

### Context

A API consumidora precisa disparar comandos privilegiados no servidor sem shell interativo e sem abrir nova superfície HTTP.

### Alternatives considered

#### Usuário `ncsaas-api` com ForceCommand e sudoers restrito
- **Pros**: usa OpenSSH já presente; limita comando; permite audit log por chave.
- **Cons**: chave comprometida ainda é risco alto, mitigado por allowlist e rotação.

#### Serviço HTTP local
- **Pros**: contrato REST direto.
- **Cons**: novo TLS/auth/rate-limit; mais superfície pública.

#### Acesso SSH de operador existente
- **Pros**: zero setup.
- **Cons**: privilégio amplo e sem separação de auditoria.

### Decision

Criar usuário `ncsaas-api` sem shell, `authorized_keys` com command fixo, `sshd_config.d` restritivo e sudoers para apenas `/usr/local/bin/nextcloud-manage`.

### Rationale

SSH já resolve autenticação, criptografia e transporte. O shim limita a gramática do comando e torna auditoria independente do usuário humano.

### Consequences

Operação v12.0 inclui rotação de chave, validação de sudoers/sshd e logs `ncsaas-api-ssh`.

---

## Decision #ARCH-004 — Callback HTTPS com HMAC e fallback polling

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, security
- **Supersedes**: —

### Context

Jobs assíncronos precisam notificar conclusão à API consumidora, mas a API pode estar temporariamente indisponível.

### Alternatives considered

#### Webhook HTTPS com HMAC-SHA256
- **Pros**: simples em Bash via `curl`/`openssl`; bom UX; autenticidade verificável.
- **Cons**: exige secret operacional e política de retry.

#### Apenas polling
- **Pros**: menos configuração.
- **Cons**: aumenta latência e número de conexões SSH.

#### Canal persistente WebSocket/SSE
- **Pros**: tempo real.
- **Cons**: fora da pilha Bash e sem necessidade para jobs longos.

### Decision

Enviar callback HTTPS assinado com `X-Signature: sha256=<hex>`, retry 5/30/300s e manter `job status --json` como fallback.

### Rationale

Webhook cobre o caminho feliz sem tornar o worker dependente da disponibilidade permanente da API.

### Consequences

Ausência de secret é fail-closed; falha de callback não muda o estado real do job e fica consultável no Redis.

---

## Decision #ARCH-005 — Idempotência por chave UUID em Redis

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto
- **Supersedes**: —

### Context

Retries da API podem reenviar operações destrutivas ou caras. O sistema precisa distinguir retry legítimo de nova intenção.

### Alternatives considered

#### `--idempotency-key` + `args_hash`
- **Pros**: explícito para consumidor; conflito detectável; TTL limita lixo.
- **Cons**: consumidor deve gerar UUID e preservar a chave por operação.

#### Hash automático do comando
- **Pros**: não exige chave externa.
- **Cons**: impediria backups legítimos repetidos com mesmos argumentos.

#### Janela temporal heurística
- **Pros**: simples.
- **Cons**: frágil e surpreendente.

### Decision

Persistir `nc:idem:<key> = <job_id>:<args_hash>` com TTL 24h; mesmo hash retorna job anterior, hash diferente retorna conflito.

### Rationale

A chave explícita preserva intenção do consumidor e evita inferência perigosa no servidor.

### Consequences

Contratos e exemplos da API devem incentivar idempotency-key para todos os comandos async.

---

## Decision #ARCH-006 — JSON versionado via `--json`

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto
- **Supersedes**: —

### Context

Saídas humanas do CLI possuem cores, múltiplas linhas e texto localizado. A API precisa de payloads estáveis.

### Alternatives considered

#### JSON em todos os comandos via `--json`
- **Pros**: contrato parseável; schema versionado; compatível com CLI humana.
- **Cons**: duplica superfície de teste.

#### Parser de texto na API
- **Pros**: menos mudança no CLI.
- **Cons**: quebradiço e acoplado à apresentação.

#### CLI apenas máquina
- **Pros**: reduz variações.
- **Cons**: prejudica operação manual DevOps.

### Decision

Centralizar emissão JSON com `jq` e incluir `schema_version="1"` nos payloads de máquina.

### Rationale

`jq` evita concatenação insegura em Bash e mantém saída humana existente para operadores.

### Consequences

Alterações incompatíveis exigem novo `schema_version`; workflows validam schemas extraídos de `CONTRACTS.md`.

---

## Decision #ARCH-007 — Docker socket via socket-proxy para HaRP

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, security
- **Supersedes**: —

### Context

HaRP/AppAPI precisa criar containers de ExApps, mas montar `/var/run/docker.sock` diretamente entrega privilégio root efetivo ao container.

### Alternatives considered

#### `tecnativa/docker-socket-proxy`
- **Pros**: reduz endpoints expostos; mantém compatibilidade com HaRP; baixo custo operacional.
- **Cons**: ainda permite subconjunto de operações sensíveis.

#### Socket direto
- **Pros**: comportamento já conhecido.
- **Cons**: superfície de ataque inaceitável para v12.0.

#### Reescrever integração AppAPI
- **Pros**: controle máximo.
- **Cons**: fora do controle do projeto e fora de escopo.

### Decision

Interpor `shared-socket-proxy` na rede `shared`, com allowlist mínima e `DOCKER_HOST=tcp://shared-socket-proxy:2375` para HaRP.

### Rationale

É a menor mudança que reduz o risco principal sem quebrar ExApps.

### Consequences

Clientes existentes precisam de `upgrade-harp`; CI e auditorias verificam que endpoints perigosos permanecem desabilitados.

---

## Decision #ARCH-008 — Secrets em arquivos `*_FILE`

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, engenheiro-devops, security
- **Supersedes**: —

### Context

`shared-services/.env` carregava segredos compartilhados em texto puro, aumentando vazamento por backup, inspeção ou logs.

### Alternatives considered

#### `/opt/shared-services/secrets/*` com modo 0600
- **Pros**: reduz exposição persistente; funciona sem Vault; claro para restore.
- **Cons**: algumas imagens exigem env literal em runtime.

#### Vault/SOPS
- **Pros**: melhor governança de segredo.
- **Cons**: fora de orçamento e adiciona stack.

#### Status quo
- **Pros**: mais simples.
- **Cons**: não atende hardening v12.0.

### Decision

Gerar secrets em arquivos root-only e referenciar `*_FILE` quando suportado; imagens sem suporte recebem export em runtime por `setup-shared.sh`.

### Rationale

O projeto preserva simplicidade operacional enquanto remove segredos persistidos no `.env` versionável/legível.

### Consequences

Restore passa a exigir cópia off-line dos secrets; docs operacionais destacam essa responsabilidade.

---

## Decision #ARCH-009 — SCP staging para anexos binários

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, security
- **Supersedes**: —

### Context

Branding e anexos podem exceder o tamanho seguro para inline base64 via SSH argv/stdin. A API também precisa enviar arquivos sem expor shell.

### Alternatives considered

#### SFTP jail em `/opt/nextcloud-customers/inbox/<staging-id>`
- **Pros**: separa binários do comando; permite limites/GC; reusa SSH.
- **Cons**: exige metadata Redis e limpeza de órfãos.

#### Base64 inline sempre
- **Pros**: único canal lógico.
- **Cons**: payload grande, logs difíceis e risco de vazamento.

#### Upload HTTP dedicado
- **Pros**: fluxo familiar para API.
- **Cons**: novo serviço e nova autenticação.

### Decision

Usar staging por SCP/SFTP jail com UUID v4, metadata `nc:inbox:<staging-id>` e GC de órfãos em 24h.

### Rationale

O canal SSH já existe e o jail restringe a superfície a arquivos pré-staged, sem criar API HTTP adicional.

### Consequences

Comandos que consomem anexos aceitam `--staging-id`; arquivos são movidos para o diretório do job antes da execução.

---

## Decision #ARCH-010 — OCC passthrough por allowlist fechada

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto, security
- **Supersedes**: —

### Context

A API consumidora precisa expor endpoints `/occ/*`, mas `php occ` possui comandos destrutivos demais para passthrough livre.

### Alternatives considered

#### Allowlist canônica em contrato e código
- **Pros**: superfície auditável; drift bloqueável em CI; cobre endpoints necessários.
- **Cons**: novos subcommands exigem mudança explícita.

#### Passthrough livre com blacklist
- **Pros**: maior flexibilidade.
- **Cons**: blacklist é incompleta por natureza.

#### Sem OCC público
- **Pros**: menor risco.
- **Cons**: não atende Feature P.

### Decision

Permitir apenas subcommands listados em `CONTRACTS.md §3.10.1`, bloquear patterns perigosos e executar argv-array dentro de `<cliente>-app`.

### Rationale

Allowlist fechada reduz risco de bypass e torna auditoria comparável entre contrato e implementação.

### Consequences

`occ-exec` é síncrono, não aceita `--async`, e comandos mutáveis passam pelo client-lock.

---

## Decision #ARCH-011 — Tradução vocabular API↔CLI como contrato explícito

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: arquiteto
- **Supersedes**: —

### Context

A API consumidora usa vocabulários e formatos próprios (`status`, `job_type`, IDs numéricos), enquanto este projeto usa `state`, `cmd` e UUIDs.

### Alternatives considered

#### Matriz de tradução em `CONTRACTS.md`
- **Pros**: evita adivinhação por implementação; additive-only em v12.x; facilita testes.
- **Cons**: exige manutenção quando a API muda.

#### Adotar vocabulário da API internamente
- **Pros**: menos tradução no consumidor.
- **Cons**: acopla Bash/Redis ao outro repositório.

#### Deixar tradução implícita
- **Pros**: menos documentação.
- **Cons**: fonte recorrente de bugs e divergências.

### Decision

Documentar tradução `state↔status`, `cmd↔job_type`, IDs e campos de payload em seção dedicada de contratos.

### Rationale

O servidor preserva sua semântica operacional enquanto oferece mapa estável para integração.

### Consequences

Mudanças de enum existentes são breaking; adições são toleradas conforme política v12.x.

---

## Decision #ARCH-012 — Slug de cliente até 64 caracteres com normalização `_` para `-`

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: analista, arquiteto
- **Supersedes**: —

### Context

O layout da API consumidora admite identificadores mais longos e pode gerar underscores, mas Docker, DNS e nomes de containers exigem slug previsível.

### Alternatives considered

#### Slug 3-64 lowercase com normalização `_` para `-`
- **Pros**: compatível com nomes de container/DNS; preserva margem para clientes reais; integração clara.
- **Cons**: API precisa normalizar antes de SSH ou aceitar retorno canônico.

#### Limite antigo curto
- **Pros**: menor chance de nomes grandes.
- **Cons**: incompatível com clientes/layouts identificados na análise.

#### Aceitar qualquer string e escapar internamente
- **Pros**: flexível.
- **Cons**: perigoso para paths, container names e comandos.

### Decision

Definir slug canônico lowercase, hífen, 3-64 chars; `_` é normalizado para `-` na fronteira API↔SSH.

### Rationale

Contrato explícito evita variações de path/container e reduz risco de command injection por identificadores.

### Consequences

Validações de `validators.sh`, docs e exemplos devem rejeitar/normalizar entradas fora do padrão.

---

## Decision #ARCH-013 — Drift gate entre OCC contract e implementação

- **Status**: accepted
- **Date**: 2026-05-08
- **Related skills**: engenheiro-devops, arquiteto
- **Supersedes**: —

### Context

A allowlist OCC é uma barreira de segurança. Divergência entre `CONTRACTS.md` e `scripts/lib/occ_bridge.sh` poderia liberar ou bloquear comandos sem revisão.

### Alternatives considered

#### Gate CI de drift
- **Pros**: falha cedo em PR; mantém contrato como fonte canônica; simples de auditar.
- **Cons**: exige parser robusto para markdown/Bash.

#### Revisão manual apenas
- **Pros**: sem automação.
- **Cons**: fácil perder divergência em mudanças pequenas.

#### Gerar código a partir do contrato
- **Pros**: elimina drift.
- **Cons**: adiciona geração e risco de churn em Bash.

### Decision

Manter `contracts-check.yml` comparando a allowlist canônica do contrato com `OCC_ALLOWLIST` em `occ_bridge.sh`.

### Rationale

Um gate simples já captura o risco principal sem introduzir geração de código.

### Consequences

Mudanças na allowlist devem alterar contrato e implementação juntas; PRs com drift falham antes de merge.

---
