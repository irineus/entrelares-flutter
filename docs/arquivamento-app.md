# Arquivamento do `entrelares-app`

**Aberto em 24/08/2026.** Objetivo: tornar o repositório `entrelares-app` **arquivado** —
sem precisar ser atualizado e, principalmente, **sem precisar ser consultado**. Tudo que diz
respeito ao aplicativo Entrelares passa a viver aqui, no `entrelares-flutter`. O
`entrelares-site` continua existindo e responde por tudo do site.

> **Este documento REVOGA uma decisão escrita.** O plano de cutover
> (`entrelares-app/docs/flutter-cutover.md`, § *"Onde o rollback morre"*, 23/08/2026) diz:
> *"o repo `entrelares-app` **NÃO** é aposentado: ele continua sendo o repo do banco, das
> Edge Functions, do backlog e do gate de integração"*. Essa frase valia enquanto o repo
> Flutter era a aposta e o Blazor era o produto. O cutover inverteu os dois papéis no dia
> seguinte, e manter a memória, o banco e o gate num repositório que ninguém mais abre é o
> caminho mais curto para perdê-los. A decisão nova é do owner, de 24/08/2026, e substitui
> aquela.

## O que foi medido antes de decidir

Três medições, feitas e não estimadas, porque as três decisões mais caras dependiam delas:

1. **Destacar o gate de banco do Blazor é quase de graça.** Os 52 arquivos / 7.489 linhas da
   suíte de integração dependem do projeto Blazor por apenas `Entrelares.Models` (767 linhas
   de POCOs cuja única dependência é o pacote NuGet `Supabase`) e três helpers estáticos
   puros. Recortado num projeto de contratos, o conjunto compila em **6,6 s, zero avisos,
   221 testes descobertos, nenhuma linha de teste reescrita**.
2. **O gate de fluxo é o problema difícil, não o de banco.** Playwright são **62 testes em
   14 classes**, em todo push (`p0` em `dev`, completo em `master`). A lane
   `integration_test` daqui são **5 `testWidgets` em 2 packs**, agendada, em emulador.
3. **Este repo não tem estágio de homologação.** Ele tem só `main`, e todo push em `main`
   publica produção. A promoção em dois estágios que o `entrelares-app` mantém já morreu
   para o app no dia do cutover.

## As oito decisões (owner, 24/08/2026)

| # | Decisão | Consequência que ela aceita |
|---|---|---|
| 1 | **Faseado**: esvaziar agora, arquivar no dia do desligamento do Blazor | O `archive` de fato vira um passo de um parágrafo, não um projeto |
| 2 | **O gate de banco é PORTADO para Dart** | O caminho mais caro dos avaliados; mitigado pela ordem de execução (abaixo) |
| 3 | **Gate de fluxo:** `flutter drive` + chromedriver rodando `integration_test` no Chrome headless, por push | Depende de um spike: plugins nativos (Play Billing, share sheet) não sobem no web |
| 4 | **A memória (backlog, archive, docs) vem para cá**, e a regra "este repo nunca carrega backlog próprio" é revogada com data e motivo | A regra nasceu quando este repo era spike; a premissa expirou em 23/08 |
| 5 | **O deploy do banco vem para cá**: PR aplica no projeto dev, merge em `main` aplica em prod | Preserva o invariante T-29 (schema e app viajam no mesmo push) e assume o mesmo risco que o app já assume: `main` é produção, sem janela |
| 6 | **`backup.yml` e `keepalive-dev.yml` vêm junto; `publish-release.yml` morre** | Arquivar um repo desliga seus workflows agendados — o backup semanal cifrado de PRODUÇÃO morreria com ele |
| 7 | **O desligamento do Blazor tem condição medida**: N dias consecutivos sem acesso a `legado.entrelares.app` | Troca "quando o owner constatar" por um gatilho verificável; sem isso o passo final não chega |
| 8 | **Os commits presos em `dev` são promovidos** assim que o E2E fechar | É a última promoção do Blazor |

## O princípio que ordena a execução

**Tocar o `entrelares-app` o menos possível.** Cada toque custa uma promoção `dev`→`master`
por um gate hoje vermelho. E há um acoplamento que impede limpeza precoce:
`Entrelares.E2ETests` referencia `Entrelares.IntegrationTests` por `ProjectReference` (reusa
o `E2EFamilyFixture`), então **a suíte de banco não pode sair de lá enquanto o Playwright
viver lá**.

Consequência: durante a travessia **nada se remove** do `entrelares-app` — tudo se **copia**
para cá, e este repo passa a ser a autoridade por declaração. A duplicação é temporária e
barata (o histórico git fica preservado dos dois lados), e o esvaziamento acontece num
**único PR tardio**.

A mesma lógica é o que torna a decisão 2 segura: a suíte C# viaja **primeiro como está**, e
cada PR de port apaga a classe C# que acabou de ganhar equivalente em Dart — o gate nunca
fica descoberto durante a travessia.

## O fatiamento

| # | Repo | O que entrega |
|---|---|---|
| **1** ✅ | flutter | **Ferramental de sessão** (PR #57, 24/08/2026): `tool/notion_mirror.py` enxerga os três repos e agrega entregas cross-repo; a skill `next-item` muda de casa e de rota; este documento |
| **2** ✅ | flutter | **O gate de banco muda de casa, ainda em C#** (24/08/2026): `db-gate/` — `Entrelares.DbContracts` (15 modelos + 2 helpers, 1.010 linhas) e a suíte intacta (52 arquivos, 7.419 linhas, 221 testes, 42 classes), mais o job `db-gate` no `verify.yml` bloqueando o `deploy-web` |
| **3** | flutter | **Banco e ops**: `supabase/` inteiro (70 migrations, 13 functions, o runbook), o deploy PR→dev / main→prod na ordem migrations → functions → app, mais `backup.yml` e `keepalive-dev.yml`. Owner: 6 secrets novos (3 de produção) + `R2_*` + `BACKUP_PASSPHRASE` |
| **4a** | flutter | **A memória, parte mecânica**: `backlog/` inteiro, `docs/`, `database/`, `GitHelp.md`, e o changelog do README do app como história congelada |
| **4b** | flutter | **A memória, parte de julgamento**: triagem do `CLAUDE.md` do app (invariantes de produto vêm; *gotchas* do Blazor ficam), revogação datada da regra do backlog, e o mirror passando a ler os registros daqui |
| **5** | flutter | **Spike do gate de fluxo**: veredito com número sobre `flutter drive` + chromedriver — o que sobe no navegador, o que falha por plugin nativo, quantos minutos custa |
| **6…N** | flutter | **O port do gate para Dart**, suíte por suíte. O primeiro PR leva o `E2EFamilyFixture` (385 linhas, ~30% do risco) e uma suíte pequena como prova; o último apaga `db-gate/` e o lane `dotnet`. Estimativa: 6–9 PRs |
| **F** | app | **O esvaziamento, num toque só**: remove o que migrou, README curto apontando para cá, `deploy.yml` reduzido à metade que publica o `legado.`. Não arquiva ainda |
| **∅** | app | **No dia do desligamento** (condição da decisão 7, sem código novo): tira domínio e projeto Pages, apaga a metade Blazor do `deploy.yml`, apaga `E2ETests` + `IntegrationTests`, arquiva |

## Pontas soltas registradas

- **Este trabalho não tem ID de backlog.** Ele produz ~15 PRs e a convenção do trailer
  precisa de um. Proposta: abrir **T-56** no board e passar a assinar os PRs seguintes com
  `Backlog: T-56`. Enquanto a linha não existir, os PRs vão sem trailer (um trailer
  apontando para linha inexistente é pior que nenhum).
- **O modelo de esforço mudou de sinal.** Com as entregas cross-repo, o T-53 passou de
  10,4 h (3 commits creditados) para **28,0 h** (41), contra ~14 h de trabalho real
  relatado pelo owner. Não é defeito do espelho: o modelo mede tempo DECORRIDO entre
  merges, e um item densamente creditado passa a absorver as folgas entre eles. Corrigir
  exige retunar `SESSION_GAP`/`SESSION_START`/`MIN_COST`, o que **move o esforço de todos
  os 180 itens do board** — decisão própria, deliberadamente não tomada aqui.
- **`tool/port_catalogs.py` para de ter função.** Quando os catálogos Dart viraram a fonte,
  ele deixou de sincronizar e passou a ser só o registro de como o port foi feito — que é o
  que o próprio cabeçalho dele já diz. Fica, com nota, no PR 4a.
- **`store/` se parte**: textos de listagem e assets de marca são presença de loja viva e
  vêm no PR 4a; o projeto TWA (Bubblewrap) é o pacote morto e fica para trás com o **T-52**,
  que segue item próprio.
