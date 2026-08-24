# Notas de release

Cada arquivo aqui é o texto de **uma release do GitHub**, versionado para ser revisado em PR
como qualquer outra mudança — em vez de ser escrito direto na interface do GitHub, onde
ninguém revisa e nada fica no histórico.

**Toda promoção `dev`→`master` gera uma release** (regra do dono, ago/2026 —
`CLAUDE.md` §Versioning e item 11 do checklist em [`../../supabase/README.md`](../../supabase/README.md)).
A razão é simples: a release é o **único lugar onde a pessoa que USA o app lê o que mudou na
versão que acabou de receber**. O changelog do `README.md` é documentação de desenvolvimento
e o número na tela, sozinho, não conta nada. Promoções de patch também têm release, mesmo
que o texto tenha três linhas.

## Formato do arquivo

`docs/releases/<tag>.md`, onde `<tag>` é exatamente a tag da versão (`v1.7.8.md` → tag
`v1.7.8`).

```
# v1.7.8 — Título curto do que a versão entrega     ← 1ª linha: TÍTULO da release
                                                     ← linha em branco
Parágrafo de abertura: o que esta versão é.          ← daqui para baixo: CORPO

### Destaques
- **Nome do recurso (F-44)**: o que mudou para quem usa o app…

### Banco de dados
(só quando houve migrations)

**Full Changelog**: https://github.com/irineus/entrelares-app/compare/<anterior>...<esta>
```

Como escrever: **PT-BR, para quem usa o app** — o que passou a ser possível, não quais
arquivos mudaram. Os IDs de backlog vão entre parênteses, como link de volta para o registro,
nunca como explicação ("**Mensagem do solicitante (F-44)**", não "Entrega do F-44"). O
material de origem são as linhas do changelog do `README.md` que a promoção carrega,
reescritas para alguém que não conhece os IDs.

## Como publicar

**Pelo workflow** (só funciona depois que `publish-release.yml` estiver no `master` — o
`workflow_dispatch` só é registrado a partir do branch padrão): Actions →
**Publicar release no GitHub** → *Run workflow* → `tag` = `vX.Y.Z`; deixe `target` vazio se a
tag já existe, ou informe `master` (ou o SHA da promoção) para o workflow criá-la. O workflow lê
este diretório, usa a 1ª linha como título e recusa sobrescrever uma release já publicada.

O terceiro campo, **`latest`**, decide se a release recebe o rótulo *Latest*. Numa promoção
normal deixe marcado (é o padrão). **Ao publicar uma versão ANTIGA — um backfill, como o das
`v1.5.0`…`v1.7.1` em ago/2026 — desmarque**: a API do GitHub marca como *Latest* toda release
recém-criada, então publicar uma versão velha com o padrão tiraria o rótulo da versão que está
em produção. Por isso o workflow passa `--latest` sempre explícito, nunca por omissão.

**Manualmente** (sempre válido, e o único caminho enquanto o workflow não estiver no
`master`): abra `https://github.com/irineus/entrelares-app/releases/new?tag=vX.Y.Z`,
cole a 1ª linha (sem o `# `) em *Release title* e o restante do arquivo no corpo, deixe *Set
as a pre-release* desmarcado e clique **Publish release**. Se a tag ainda não existir, a
página oferece um seletor *Target* — escolha `master`, e a tag é criada ao publicar.

Publique em **ordem crescente de versão** quando forem várias — a lista do GitHub fica na
ordem em que as releases foram criadas, e o rótulo *Latest* é controlado pelo campo `latest`
acima, não pela ordem.

## Estado

| Tag | Notas | Release publicada |
|---|---|---|
| `v1.4.0` | — (escrita direto no GitHub, antes desta convenção) | ✅ |
| `v1.5.0` | [`v1.5.0.md`](v1.5.0.md) | ✅ **publicada em 08/08/2026** (backfill, `latest` = `false`) |
| `v1.6.0` | [`v1.6.0.md`](v1.6.0.md) | ✅ **publicada em 08/08/2026** (backfill, `latest` = `false`) |
| `v1.7.0` | [`v1.7.0.md`](v1.7.0.md) | ✅ **publicada em 08/08/2026** (backfill, `latest` = `false`) |
| `v1.7.1` | [`v1.7.1.md`](v1.7.1.md) | ✅ **publicada em 08/08/2026** (backfill, `latest` = `false`). A tag não existia e foi criada pela mesma execução, com *Target* = **`b1522a8`** — o commit em que o deploy de produção de 03/08 realmente rodou, e **não** o head do `master`, que a essa altura já era a `v1.8.0` |
| `v1.7.15` | [`v1.7.15.md`](v1.7.15.md) | ✅ **publicada com a promoção de 05/08/2026** (a primeira pelo workflow `Publicar release no GitHub`, que esta promoção levou ao `master`). Cobre tudo entre a `v1.7.1` e a `v1.7.15` (F-44, T-45, F-45, T-35, o acerto de vocabulário Observação do dia × Mensagem, U-20/U-07, F-47, o F-48 completo e a preparação da Google Play do T-38); o deploy do landing `main` (L-14) saiu acoplado — os dois lados anunciam o mesmo preço. O arquivo foi renomeado de `v1.7.8.md` → … → `v1.7.15.md` à medida que entregas subiram o build |
| `v1.8.0` | [`v1.8.0.md`](v1.8.0.md) | ✅ **publicada com a promoção de 07/08/2026**, e é a que carrega o rótulo *Latest* — é o arquivo acumulador, renomeado `v1.7.16` → … → `v1.7.33` → `v1.8.0` conforme as entregas subiram o build. Cobre tudo entre a `v1.7.15` e a `v1.8.0`: o U-13 inteiro, o U-24, o U-23 e a rodada de QA pré-produção de 07/08 (e-mails do GoTrue no idioma de quem lê, primeiros passos sem espremer o calendário, redefinição de senha funcionando de ponta a ponta) |
| `v1.8.1` | [`v1.8.1.md`](v1.8.1.md) | ✅ **publicada com a promoção de 10/08/2026** (pelo workflow `Publicar release no GitHub`). Uma versão de um item só, promovida sozinha de propósito: o rollout do closed-alpha da Google Play esperava por ela — as impressões reais no `assetlinks.json` (o app Android sem a barra de navegador) e a ficha da Play em pt-BR + en-US |
| `v1.8.4` | [`v1.8.4.md`](v1.8.4.md) | ✅ **publicada com a promoção de 12/08/2026** (pelo workflow `Publicar release no GitHub`, com *Target* explícito = `52a8193`, porque o push da tag pelo cliente falhava com `send-pack: unexpected disconnect`). Cobre o rebrand Entrelares inteiro (F-54: nome, domínio e pacote na `1.8.2`, rename interno na `1.8.3`, identidade visual na `1.8.4`) |
| `v1.8.7` | [`v1.8.7.md`](v1.8.7.md) | ✅ **publicada em 18/08/2026**, referente à promoção de 13/08 — o arquivo acumulador do ciclo, renomeado `v1.8.5` → `v1.8.6` → `v1.8.7` conforme as entregas subiram o build. Cobre a metade Android do rebrand (o `assetlinks.json` completo, a casca com splash e versão corretas) e o fecho do cutover de remetente. **A release ficou 5 dias para trás da promoção** — a promoção foi executada e a publicação não; é exatamente o passivo que esta tabela existe para tornar visível, e a lição é que o passo 11 do checklist do runbook não pode ser "depois" |
| `v1.8.13` | [`v1.8.13.md`](v1.8.13.md) | ⏳ **aguarda a próxima promoção** — é o arquivo acumulador do ciclo atual, renomeado conforme as entregas sobem o build. **O rename ficou uma entrega para trás**: o T-48 subiu o build para `1.8.13` e o arquivo continuou `v1.8.12.md`, o que faria o workflow parar com "notas não encontradas" na tag `v1.8.13`. Foi corrigido na preparação da promoção — a lição é que o rename pertence ao MESMO PR que mexe no `csproj`, não à promoção |

As quatro do meio eram o passivo encontrado em ago/2026, quando se notou que só a `v1.4.0`
tinha release enquanto quatro versões já estavam em produção. **Foram publicadas em
08/08/2026** e a tabela não tem mais pendências: toda versão que chegou à produção tem
release. Duas coisas que esse backfill ensinou, e que valem para qualquer outro:

- **O rótulo *Latest* não segue a versão, segue o padrão da API** — que é marcar como *Latest*
  toda release recém-criada. Publicar uma versão velha sem `latest` = `false` tiraria o rótulo
  da versão que o usuário de fato recebeu.
- **A tag de uma promoção antiga não vai no head do `master`.** Para saber onde ela vai, olhe
  o histórico de execuções do `deploy.yml` **no branch `master`**: o `head_sha` da execução
  daquela data é, por definição, o commit que foi para produção. O commit de documentação que
  diz "estado de producao na X.Y.Z" costuma ser POSTERIOR e viver no `dev` — usá-lo como
  *Target* colocaria a tag num commit que aquela versão nunca teve.

## Quando a versão a promover não for a que está escrita

O ciclo recomeçou com o U-13 (PR 1), em `v1.7.16.md`, renomeado até `v1.8.0.md` conforme as
entregas seguintes subiram o build — o arquivo
acumula os destaques e é **renomeado para a versão que subir** a cada nova entrega
(`v1.7.16` → `v1.7.22` → `v1.7.25` → `v1.7.28` → `v1.7.33` → `v1.8.0`), até a promoção seguinte publicá-lo.
**A promoção de 12/08/2026 publicou o `v1.8.4`; a de 13/08 subiu a `v1.8.7` (release publicada em 18/08); o ciclo atual acumula em `v1.8.13.md` (aberto com o F-58 PR 1, renomeado na rodada de QA e de novo com a metade servidor do T-48).** O
workflow falha com "notas não encontradas" se o nome não bater com a tag, o que é proposital:
melhor parar do que publicar uma release descrevendo outra versão.

**Renomear o arquivo não renomeia o TÍTULO dentro dele** (encontrado no U-13 PR 4b, ago/2026):
a 1ª linha ficou em `# v1.7.22 —` enquanto o arquivo já era `v1.7.25.md`, e é essa linha que
vira o título da release — publicar assim anunciaria uma versão que não é a da tag, justamente
o erro que a checagem de nome existe para evitar. Ao renomear, ajuste a 1ª linha e o link
`compare/` do rodapé junto.
