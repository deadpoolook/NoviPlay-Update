# NoviPlay - Atualização automática

Este reposório roda sozinho nos servidores do GitHub, de hora em hora,
24 horas por dia. Ele atualiza o catálogo do NoviPlay (filmes, séries e
canais ao vivo), testa se os links abrem, conserta os que caíram e publica
o resultado no Gist — que é de onde a TV e o aplicativo do celular leem.

**O computador não precisa estar ligado.** Se o PC estiver desligado, a
nuvem assume sozinha.

## O que fica aqui dentro

| Arquivo | Para que serve |
|---|---|
| `Atualizar_Filmes.ps1` | O programa que faz a atualização (é o mesmo do PC) |
| `Sincronizacao.ps1` | O quadro que avisa quem atualizou por último |
| `baixar_dados.ps1` | Busca o catálogo guardado no Gist |
| `salvar_dados.ps1` | Devolve o catálogo atualizado para o Gist |
| `gravar_status.ps1` | Registra no quadro que a nuvem atualizou |

## O que NÃO fica aqui (e por quê)

Nada de senha, endereço ou link é publicado neste repositório. Esses
valores ficam guardados em **Segredos** do GitHub e no **Gist secreto**:

- O token do GitHub
- Os endereços das APIs
- O login do canal de TV

Os arquivos com o seu catálogo (`channels.np` e companhia) também ficam
fora: eles moram no Gist secreto, que só é acessível por link.

O código-fonte é público e mostra **como** a atualização funciona, mas sem
nenhuma chave para usá-la.

## Como oRodar manualmente

Na aba **Actions** deste repositório, clique em *"Atualizar NoviPlay"* →
**Run workflow**. É o mesmo que roda sozinho de hora em hora.

## Onde o resultado aparece

- No aplicativo e na TV, pelo Gist (o link nunca muda).
- No painel do PC, na aba de status.