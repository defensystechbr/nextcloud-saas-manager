# Guia de Troubleshooting

Este documento cobre alguns dos problemas mais comuns que podem ocorrer e como resolvê-los.

## Problema: Certificado SSL não é emitido

**Sintomas:**
- O site não carrega em HTTPS.
- O navegador mostra um erro de certificado.
- O arquivo `/opt/traefik/acme.json` está vazio ou não contém o certificado para o seu domínio.

**Causas e Soluções:**

1.  **DNS não propagado:** Esta é a causa mais comum. O Let's Encrypt precisa acessar seu domínio via HTTP (porta 80) para validar que você é o proprietário. Se o registro DNS não estiver apontando para o IP do seu servidor, a validação falhará.
    -   **Solução:** Use uma ferramenta como `dig` ou `nslookup` para confirmar que o domínio resolve para o IP correto. Aguarde a propagação do DNS (pode levar de alguns minutos a várias horas).

2.  **Porta 80 bloqueada:** O Traefik precisa estar acessível na porta 80 para o `httpChallenge` do Let's Encrypt.
    -   **Solução:** Verifique se não há outro serviço rodando na porta 80 e que seu firewall (se houver) não está bloqueando a porta.

3.  **Logs do Traefik:** Os logs do Traefik são a melhor fonte de informação para diagnosticar problemas de ACME.
    -   **Comando:** `sudo docker logs traefik`
    -   **O que procurar:** Procure por mensagens de erro contendo `acme`, `letsencrypt` ou o nome do seu domínio. Erros como `timeout` ou `connection refused` geralmente indicam problemas de DNS ou firewall.

## Problema: Erro 502 Bad Gateway

**Sintomas:**
- O navegador exibe um erro "502 Bad Gateway" ao tentar acessar o Nextcloud.

**Causas e Soluções:**

1.  **Container do Nextcloud não está rodando:** O Traefik não consegue encontrar o container para encaminhar a requisição.
    -   **Solução:** Verifique o status da instância com `sudo nextcloud-manage <cliente> _ status`. Se o container `app` não estiver rodando, verifique seus logs com `sudo docker logs <nome-do-container-app>`.

2.  **Problema de rede Docker:** O Traefik e o container do Nextcloud podem não estar na mesma rede `proxy`.
    -   **Solução:** Verifique se o Traefik e os containers da instância estão ambos conectados à rede `proxy`. Use `docker network inspect proxy` para ver os containers conectados.

## Problema: Erro "API version is too old"

**Sintomas:**
- Nos logs do Traefik, você vê um erro como `client version 1.41 is too old. Minimum supported API version is 1.44`.

**Causas e Soluções:**

1.  **Incompatibilidade entre Traefik e Docker:** Você está usando uma versão do Traefik que não é compatível com a versão do seu Docker Engine.
    -   **Solução:** Use sempre a imagem `traefik:latest`, que corresponde à versão 3.x ou superior. O script `deploy-server.sh` já faz isso automaticamente. Se você configurou o Traefik manualmente, atualize a imagem no seu `docker-compose.yml` e reinicie o Traefik.

## Problema: O Collabora Online não abre documentos

**Sintomas:**
- Ao tentar abrir um documento do Office, a página carrega indefinidamente ou mostra um erro.

**Causas e Soluções:**

1.  **DNS do Collabora incorreto:** O domínio `collabora-nextcloud.dominio.com` não está resolvendo para o IP do servidor.
    -   **Solução:** Verifique o registro DNS do Collabora.

2.  **Configuração no Nextcloud:** O Nextcloud pode não estar configurado corretamente para se comunicar com o servidor Collabora.
    -   **Solução:** O script `manage.sh` configura isso automaticamente. Se houver problemas, vá para **Administração > Nextcloud Office** e verifique se a URL do servidor WOPI está correta (`https://collabora-nextcloud.dominio.com`).
