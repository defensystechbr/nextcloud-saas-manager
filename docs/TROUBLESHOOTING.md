# Guia de Troubleshooting — Nextcloud SaaS Manager

Este documento cobre os problemas mais comuns que podem ocorrer durante a operação da plataforma e como resolvê-los.

---

## Problema: Certificado SSL não é emitido

**Sintomas:** O site não carrega em HTTPS, o navegador mostra erro de certificado, ou o arquivo `/opt/traefik/acme.json` está vazio.

**Causas e Soluções:**

### 1. DNS não propagado

Esta é a causa mais comum. O Let's Encrypt precisa acessar o domínio via HTTP (porta 80) para validar a propriedade. Se o registro DNS não estiver apontando para o IP do servidor, a validação falhará.

```bash
# Verificar se o DNS está resolvendo corretamente
dig +short nextcloud.acme.com.br
dig +short collabora-nextcloud.acme.com.br
```

Ambos devem retornar o IP do servidor. Se não retornarem, aguarde a propagação ou corrija os registros DNS.

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

O domínio do Collabora (com prefixo `collabora-`) deve resolver para o IP do servidor:

```bash
dig +short collabora-nextcloud.acme.com.br
```

### 2. Container do Collabora não está rodando

```bash
docker ps --filter name=acme-collabora
docker logs acme-collabora --tail 50
```

### 3. Configuração WOPI incorreta

O script `manage.sh` configura isso automaticamente durante o `create`. Se precisar verificar ou corrigir manualmente:

```bash
# Verificar a configuração atual
docker exec -u www-data acme-app php occ config:app:get richdocuments wopi_url

# Deve retornar: https://collabora-nextcloud.acme.com.br
# Se estiver errado, corrigir:
docker exec -u www-data acme-app php occ config:app:set richdocuments wopi_url --value="https://collabora-nextcloud.acme.com.br"
docker exec -u www-data acme-app php occ config:app:set richdocuments public_wopi_url --value="https://collabora-nextcloud.acme.com.br"
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

### 1. Verificar o TURN server

```bash
docker ps --filter name=acme-turn
docker logs acme-turn --tail 20
```

### 2. Verificar a porta TURN

A porta TURN (padrão 3478) deve estar acessível externamente:

```bash
# Verificar qual porta a instância usa
grep TURN_PORT /opt/nextcloud-customers/acme/.env

# Verificar se a porta está aberta
sudo ss -tlnp | grep 3478
```

### 3. Verificar a configuração no Nextcloud

```bash
docker exec -u www-data acme-app php occ config:app:get spreed turn_servers
docker exec -u www-data acme-app php occ config:app:get spreed stun_servers
```

---

## Comandos Úteis para Diagnóstico

```bash
# Ver todos os containers de uma instância
docker ps --filter name=acme

# Ver logs de qualquer container
docker logs acme-app --tail 100
docker logs acme-db --tail 100
docker logs acme-collabora --tail 100

# Ver uso de disco das instâncias
du -sh /opt/nextcloud-customers/*/

# Ver uso de disco dos volumes Docker
docker system df -v

# Reiniciar o Traefik
cd /opt/traefik && docker compose restart

# Verificar routers ativos no Traefik
docker exec traefik wget -qO- http://localhost:8080/api/http/routers 2>/dev/null | python3 -m json.tool
```
