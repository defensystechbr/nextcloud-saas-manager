# Guia de Troubleshooting — Nextcloud SaaS Manager

Este documento cobre os problemas mais comuns que podem ocorrer durante a operação da plataforma e como resolvê-los.

---

## Problema: Certificado SSL não é emitido

**Sintomas:** O site não carrega em HTTPS, o navegador mostra erro de certificado, ou o arquivo `/opt/traefik/acme.json` está vazio.

**Causas e Soluções:**

### 1. DNS não propagado

Esta é a causa mais comum. O Let's Encrypt precisa acessar o domínio via HTTP (porta 80) para validar a propriedade. Se o registro DNS não estiver apontando para o IP do servidor, a validação falhará.

Cada instância requer **1 registro DNS** para o domínio principal:

```bash
# Verificar se o DNS está resolvendo corretamente
dig +short nextcloud.acme.com.br
```

Deve retornar o IP do servidor. Se não retornar, aguarde a propagação ou corrija o registro DNS.

Os domínios compartilhados do Collabora e Signaling também devem resolver:
```bash
dig +short collabora-01.defensys.seg.br
dig +short signaling-01.defensys.seg.br
```

### 2. Porta 80 bloqueada

O Traefik precisa estar acessível na porta 80 para o `httpChallenge` do Let's Encrypt.

```bash
# Verificar se a porta 80 está aberta
sudo ss -tlnp | grep :80
```

### 3. Versão do Traefik incompatível com Docker

Se nos logs do Traefik aparecer `client version 1.41 is too old. Minimum supported API version is 1.44`, significa que a versão do Traefik é antiga demais para o Docker instalado.

```bash
# Verificar a versão do Traefik
docker logs traefik 2>&1 | head -20

# Solução: usar traefik:latest (v3.x+)
cd /opt/traefik
# Editar docker-compose.yml e trocar a imagem para traefik:latest
docker compose down && docker compose up -d
```

O script `deploy-server.sh` já usa `traefik:latest` automaticamente. Este problema só ocorre se o Traefik foi configurado manualmente com uma versão antiga (v2.x).

### 4. Verificar logs do Traefik

```bash
docker logs traefik --tail 100 2>&1 | grep -i "acme\|error\|letsencrypt"
```

---

## Problema: Erro 502 Bad Gateway

**Sintomas:** O navegador exibe "502 Bad Gateway" ao acessar o Nextcloud.

### 1. Container não está rodando

```bash
# Verificar status da instância
sudo nextcloud-manage acme _ status

# Se o container app não estiver rodando, ver os logs
docker logs acme-app --tail 50
```

### 2. Problema de rede Docker

O Traefik e os containers da instância devem estar na mesma rede `proxy`.

```bash
# Verificar containers conectados à rede proxy
docker network inspect proxy --format '{{range .Containers}}{{.Name}} {{end}}'
```

### 3. Reiniciar a instância

```bash
sudo nextcloud-manage acme _ stop
sudo nextcloud-manage acme _ start
```

---

## Problema: Collabora Online não abre documentos

**Sintomas:** Ao tentar abrir um documento, a página carrega indefinidamente ou mostra erro.

### 1. DNS do Collabora incorreto

O domínio do Collabora compartilhado deve resolver para o IP do servidor:

```bash
dig +short collabora-01.defensys.seg.br
```

### 2. Container do Collabora não está rodando

```bash
docker ps --filter name=shared-collabora
docker logs shared-collabora --tail 50
```

### 3. Domínio não está na allowlist

O script `manage.sh` atualiza a allowlist do Collabora compartilhado automaticamente durante o `create`. Se o domínio não estiver lá, o Collabora recusará a conexão.

```bash
# Verificar a allowlist atual
grep COLLABORA_ALLOWLIST /opt/shared-services/.env
```

### 4. Configuração WOPI incorreta no Nextcloud

```bash
# Verificar a configuração atual
docker exec -u www-data acme-app php occ config:app:get richdocuments wopi_url

# Deve retornar: https://collabora-01.defensys.seg.br
# Se estiver errado, corrigir:
docker exec -u www-data acme-app php occ config:app:set richdocuments wopi_url --value="https://collabora-01.defensys.seg.br"
docker exec -u www-data acme-app php occ config:app:set richdocuments public_wopi_url --value="https://collabora-01.defensys.seg.br"
```

---

## Problema: Nextcloud em modo de manutenção

**Sintomas:** O Nextcloud exibe "This Nextcloud instance is currently in maintenance mode".

```bash
# Desativar o modo de manutenção
docker exec -u www-data acme-app php occ maintenance:mode --off
```

---

## Problema: Background jobs não estão rodando

**Sintomas:** Avisos no Admin Overview sobre background jobs.

```bash
# Verificar se o container cron está rodando
docker ps --filter name=acme-cron

# Verificar os logs do cron
docker logs acme-cron --tail 20

# Executar manualmente se necessário
docker exec -u www-data acme-app php occ background:cron
```

---

## Problema: Talk (chamadas de vídeo) não funciona

**Sintomas:** Chamadas de vídeo/áudio não conectam.

### 1. Verificar o TURN server compartilhado

```bash
docker ps --filter name=shared-turn
docker logs shared-turn --tail 20
```

### 2. Verificar a porta TURN e Range UDP

A porta TURN (3478 TCP/UDP) e o range UDP (49152-65535) devem estar acessíveis externamente. O container agora usa `network_mode: host`.

```bash
# Verificar se a porta está aberta
sudo ss -tlnp | grep 3478
sudo ss -ulnp | grep 3478
```

### 3. Verificar a configuração no Nextcloud

```bash
docker exec -u www-data acme-app php occ config:app:get spreed turn_servers
docker exec -u www-data acme-app php occ config:app:get spreed stun_servers
```

### 4. Verificar o HPB Compartilhado (Signaling Server)

O HPB é composto por 3 containers compartilhados: NATS, Janus e Signaling.

```bash
# Verificar se os 3 containers HPB estão rodando
docker ps --filter name=shared-nats
docker ps --filter name=shared-janus
docker ps --filter name=shared-signaling

# Verificar logs do signaling
docker logs shared-signaling --tail 50

# Verificar se o signaling está registrado no Nextcloud
docker exec -u www-data acme-app php occ config:app:get spreed signaling_servers

# Verificar DNS do signaling
dig +short signaling-01.defensys.seg.br

# Testar HTTPS do signaling
curl -sI https://signaling-01.defensys.seg.br
```

### 5. Verificar Backend do Cliente no Signaling

O Signaling compartilhado gerencia múltiplos backends. Verifique se a instância está listada no `signaling.conf`:

```bash
cat /opt/shared-services/hpb/signaling.conf
```

---

## Problema: AppAPI / HaRP não funciona

**Sintomas:** Aviso no Admin Overview sobre AppAPI deploy daemon.

### 1. Verificar o container HaRP

```bash
docker ps --filter name=acme-harp
docker logs acme-harp --tail 50
```

### 2. Verificar o daemon registrado

```bash
docker exec -u www-data acme-app php occ app_api:daemon:list
```

### 3. Verificar saúde do HaRP

O container HaRP tem healthcheck integrado. Verifique se está "healthy":

```bash
docker inspect acme-harp --format '{{.State.Health.Status}}'
```

---

## Comandos Úteis para Diagnóstico

```bash
# Ver todos os containers de uma instância
docker ps --filter name=acme

# Ver logs dos containers do cliente
docker logs acme-app --tail 100
docker logs acme-cron --tail 100
docker logs acme-harp --tail 100

# Ver logs dos serviços compartilhados
docker logs shared-db --tail 100
docker logs shared-collabora --tail 100
docker logs shared-signaling --tail 100
docker logs shared-turn --tail 100

# Ver uso de disco das instâncias
du -sh /opt/nextcloud-customers/*/

# Ver uso de disco dos volumes Docker
docker system df -v

# Reiniciar o Traefik
cd /opt/traefik && docker compose restart

# Verificar routers ativos no Traefik
docker exec traefik wget -qO- http://localhost:8080/api/http/routers 2>/dev/null | python3 -m json.tool

# Limpar logs do Nextcloud
docker exec -u www-data acme-app php occ log:manage --level=warning
echo '[]' | docker exec -i acme-app tee /var/www/html/data/nextcloud.log > /dev/null

# Ver credenciais da instância
sudo nextcloud-manage acme _ credentials
# Ou diretamente:
sudo cat /opt/nextcloud-customers/acme/.credentials
```
