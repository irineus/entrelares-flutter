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
| **3** ✅ | flutter | **Banco e ops** (24/08/2026): `supabase/` inteiro (70 migrations, 12 functions, o runbook de 1.442 linhas), o deploy PR→dev / `main`→prod na ordem migrations → functions → app, mais `backup.yml` e `keepalive-dev.yml`. Tudo **auto-desarmante**: entra sem os secrets e só passa a valer quando o owner os define |
| **4a** ✅ | flutter | **A memória, parte mecânica** (24/08/2026): `backlog/` inteiro (6 + 8 de `archive/`), `docs/`, `database/`, `GitHelp.md`, e o changelog do README do app como `docs/changelog-blazor.md` (138 versões). O espelho passou a ler os registros daqui, e a regra do backlog foi revogada no `CLAUDE.md` — ela era consequência direta desta mudança, não do 4b |
| **4b** ✅ | flutter | **A memória, parte de julgamento** (24/08/2026): sete seções triadas das 900 linhas do `CLAUDE.md` do app — convenções, working agreement, modelo de domínio, invariantes, seção legal, board/esforço e 13 *gotchas* de banco e plataforma. Ficaram para trás os que morrem com o cliente (escopos do Blazor, `RetryHelper`, gotrue-csharp, Realtime em WASM, versionamento por `csproj`, todos os de Playwright). Mais a frase do esforço, que virou falsa, e o parágrafo do roadmap que ainda chamava a 1.8.13 de produção |
| **5** ✅ | flutter | **Gate de fluxo — entregue** (24/08/2026): os MESMOS arquivos `integration_test/` rodam num Chrome headless via `flutter drive` + chromedriver. Medido antes de confiar, porque na web o `flutter drive` imprime "All tests passed" tenha ou não executado algo: uma sonda com um teste que falha de propósito deixou o job **vermelho** nomeando o teste, e o pacote completo custa ~6 s mais que o `p0`. **144 s para os dois packs (5 testes)** contra 10–15 min do emulador. Roda em push/PR e **bloqueia a publicação web** desde 24/08/2026 (decisão do owner, sobre cinco runs verdes e uma vermelha proposital); não substitui o emulador para o que exige aparelho |
| **4c** ✅ | flutter | **A presença de loja** (24/08/2026): `store/` — a cópia das listagens (PT-BR + en-US), os dois masters da marca, `brand-icons.py` (reapontado para os sete arquivos que este repo consome, e **verificado**: reproduz os sete byte a byte), o gráfico de destaque com seu gerador e um `README.md` triado. Ficou para trás o pacote TWA (`twa-manifest.json`, Bubblewrap, o `store/.gitignore` que só listava saída de build). Devia ter vindo no 4a e não veio — o item estava escrito e foi esquecido; é o achado que fez o PR F conferir o repositório inteiro em vez de conferir a lista |
| **6…16** | flutter | **O port do gate para Dart**, suíte por suíte — o fatiamento detalhado está na seção seguinte. O PR 6 leva a fundação (contratos erguidos, clientes por identidade, fixture) e uma suíte real como prova; o 16 apaga `db-gate/` e o lane `dotnet` |
| **F** ✅ | app | **O esvaziamento, num toque só** (24/08/2026, [`entrelares-app` #309](https://github.com/irineus/entrelares-app/pull/309)): 242 arquivos, −46.941 linhas. Sobra o cliente Blazor, sua suíte unitária e um `deploy.yml` reduzido à metade que publica — o deploy de QA que seguiu o merge fechou **verde em 1 min 39 s**, contra os ~15 min do gate antigo. Saíram também, por decisão do owner, as DUAS suítes C# e o `dependabot.yml`; o que ficou para trás e por quê está no registro do T-56. Não arquiva ainda |
| **∅** | app | **No dia do desligamento** (condição da decisão 7, sem código novo): tira domínio e projeto Pages, apaga a metade Blazor do `deploy.yml`, apaga `E2ETests` + `IntegrationTests`, arquiva |

## O port do gate para Dart (PRs 6 a 16)

### A autorização de merge, com data e escopo

O `CLAUDE.md` diz, e continua dizendo: *"PR + squash-merge só com o OK explícito do dono —
nunca automático"*. **Em 24/08/2026 o owner abriu uma exceção com escopo EXCLUSIVO aos PRs 6
a 16 deste port**: cada um vai a PR, espera o CI e é mergeado por quem o abriu **se fechar
verde**. Está registrado aqui para que nenhuma sessão futura leia esses merges como violação
da regra — e para que o escopo fique estreito: a exceção morre com o PR 16, não se estende a
nenhum outro trabalho neste repo.

Três condições vieram junto com ela, e são o que a torna segura:

- **Só se mergeia o seguinte quando o anterior fechou verde.** Enquanto o CI de um roda, o
  próximo pode ser escrito, nunca mergeado.
- **CI vermelho é prioridade máxima** — conserta-se antes de seguir, LENDO o erro. Reexecutar
  até passar é proibido: o último vermelho do gate parecia vazamento de RLS e era
  `statement timeout`.
- **Para-se e pergunta-se ao owner quando a decisão for dele** — com ou sem vermelho.

### As três medições que desenharam o port

1. **Os contratos já existiam em Dart.** Os 12 modelos de tabela em
   `apps/entrelares_app/lib/models/` (816 linhas) eram Dart puro, importando só `dart:convert`
   e `entrelares_core`. Erguê-los para `packages/entrelares_db_contracts` é a simetria exata
   do que `Entrelares.DbContracts` fez em C# — e é o que permite ao gate ler o MESMO contrato
   que o app lê, de modo que uma coluna renomeada não pode ficar verde de um lado e vermelha
   do outro.
2. **41 das 43 classes C# compartilham UMA família** via `[Collection("e2e-family")]`. No
   `dart test` cada ARQUIVO roda em isolate próprio e `setUpAll` é por arquivo, então um port
   ingênuo criaria 41 famílias por execução e martelaria o projeto de QA. A saída é um
   **entrypoint agregador** (`test/db_gate_test.dart`): as suítes são bibliotecas que
   REGISTRAM seus grupos contra uma fixture recebida, e só esse arquivo tem `setUpAll`.
3. **O pacote é o `supabase` puro, NUNCA `supabase_flutter`.** O gate precisa de vários
   clientes autenticados vivos no mesmo processo — é assim que RLS se testa — e o
   `supabase_flutter` inicializa um singleton por processo (lição 8 do piloto), então
   caberia exatamente uma identidade nele.

### O fatiamento, e a aritmética que o verifica

| PR | Grupo | Linhas C# de origem |
|---|---|---|
| 6 ✅ | **Fundação**: `entrelares_db_contracts`, `entrelares_db_gate`, clientes por identidade, fixture completa + `FamilyIsolationTests` como prova | 856 |
| 7 | RLS, adversarial e consentimento | 752 |
| 8 | Regras de dia (proteção, transição T-27, horizonte, concorrência) | 647 |
| 9 | Workflow de troca (auto-aprovação, mensagens, reversão, log) | 618 |
| 10 | Conta e exclusão (conta, família, perfil, idioma) | 812 |
| 11 | Convites e multi-cuidador | 628 |
| 12 | Operador de plataforma + RPCs de admin | 698 |
| 13 | Sudo, papéis customizados, settings, auth de functions | 997 |
| 14 | Billing do rail web | 1.064 |
| 15 | Billing de loja e webhook | 436 |
| 16 | Apaga `db-gate/` e a lane `dotnet` do workflow | — |

**Cada PR apaga as classes C# que acabou de traduzir**, no mesmo commit. É isso que impede o
gate de ficar descoberto: uma suíte só sai de um lado quando já existe do outro. E a
verificação é uma soma — **`testes C# + testes Dart` tem que continuar 225**. O lado C# é
contado por `python3 tool/count_csharp_tests.py` (que sabe que um `[Theory]` vale um caso por
`[InlineData]`, e não um por método); o lado Dart sai do relatório do `dart test`. O
`verify.yml` imprime a soma no summary de cada run, e o corpo de cada PR a repete.

Os dois lados rodam **como passos do mesmo job**, não como dois jobs: cada um inventa sua
própria família `E2E-<runId>` e as duas varreduras de órfãos poupam o que tem menos de 2 h,
então eles não colidem em FAMÍLIAS — mas colidiriam nas seeds de billing do T-39, que usam
ids externos FIXOS. Um job só, sob o `concurrency: db-gate` que já existia, resolve isso por
construção.

### O que o PR 6 mexeu fora do gate

Ele é o único do port que **podia quebrar o aplicativo**: mover os 12 modelos para
`packages/entrelares_db_contracts` reescreveu 148 imports em 46 arquivos do app. A verificação
foi mecânica (`flutter analyze` + `flutter test`, ambos limpos), e o app não muda mais do PR 7
em diante. Uma única mudança de comportamento veio junto: `Member` ganhou `familyId`,
opcional, porque o app nunca precisa dele (RLS já estreita toda leitura) e o gate precisa —
provar que RLS vale é justamente nomear a família que uma linha declara.

## O que o owner precisa fazer para o PR 3 valer

O código entrou desarmado: sem os secrets, cada passo **pula com nota no summary** em vez de
pintar o `main` de vermelho. Enquanto estiver assim, quem aplica migrations continua sendo o
`entrelares-app`, e **schema e app não viajam juntos**.

| Secret | Para quê |
|---|---|
| `SUPABASE_ACCESS_TOKEN_DEV`, `SUPABASE_DB_PASSWORD_DEV`, `SUPABASE_PROJECT_REF_DEV` | O PR aplicar schema/functions no projeto de QA **antes** do gate rodar |
| `SUPABASE_ACCESS_TOKEN_PROD`, `SUPABASE_DB_PASSWORD_PROD`, `SUPABASE_PROJECT_REF_PROD` | O `main` aplicar em **produção** (job `db-prod`) |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `BACKUP_PASSPHRASE` | O backup semanal cifrado |

**E, no mesmo momento, desligar as cópias antigas** — sem tocar em código nem gastar promoção:

```
gh workflow disable backup.yml -R irineus/entrelares-app
gh workflow disable keepalive-dev.yml -R irineus/entrelares-app
```

Não basta apagar os secrets lá: o `backup.yml` daquele repo **falha** com secrets ausentes,
por decisão de projeto, então apagar só trocaria "dois backups por semana" por "um vermelho
por semana". `gh workflow disable` desarma na fonte.

O `keepalive-dev.yml` daqui **não precisa de secret nenhum novo**: a URL do dev é pública
(a mesma do `env.dart`) e a `SUPABASE_SERVICE_ROLE_DEV` já existe neste repo — ele passa a
valer no merge.

## Pontas soltas registradas

- ~~**Este trabalho não tem ID de backlog.**~~ **Resolvido em 24/08/2026: é o T-56**
  ([linha no board](https://app.notion.com/p/3c62f3f4b9b2810fb092ce9aef103ac0)), aberto
  depois que os três primeiros PRs já tinham entrado — o item foi proposto pelo primeiro
  deles. Do quarto em diante os commits levam `Backlog: T-56` e se creditam sozinhos; os
  três anteriores entraram na tabela `HAND_REVIEWED` do espelho. O **registro versionado**
  nasce em `backlog/technical.md` no PR 4a, quando o backlog muda de casa; até lá o corpo
  da página no Notion é provisório.
- ~~**O select `Repo` do board não tem opção `flutter`**.~~ **Resolvido em 24/08/2026:** a opção existe (roxa, ao lado de `app` e `landing`) e o T-56 é o primeiro item marcado com ela. Conferido que os IDs das opções antigas não mudaram — as 182 linhas mantiveram seu valor. **O backfill histórico NÃO foi feito**: T-53, T-54, T-55, U-27 e U-28 foram entregues no repo Flutter mas continuam marcados como `app`, porque eram itens do app quando foram executados. Reescrever isso é decisão de outra natureza — diz respeito ao que a coluna significa (onde o código vive HOJE, ou onde o item foi feito), e fica com o owner.
- **O modelo de esforço mudou de sinal.** Com as entregas cross-repo, o T-53 passou de
  10,4 h (3 commits creditados) para **28,0 h** (41), contra ~14 h de trabalho real
  relatado pelo owner. Não é defeito do espelho: o modelo mede tempo DECORRIDO entre
  merges, e um item densamente creditado passa a absorver as folgas entre eles. Corrigir
  exige retunar `SESSION_GAP`/`SESSION_START`/`MIN_COST`, o que **move o esforço de todos
  os 180 itens do board** — decisão própria, deliberadamente não tomada aqui.
- **`tool/port_catalogs.py` para de ter função.** Quando os catálogos Dart viraram a fonte,
  ele deixou de sincronizar e passou a ser só o registro de como o port foi feito — que é o
  que o próprio cabeçalho dele já diz. Fica, com nota, no PR 4a.
- ~~**`store/` se parte**: textos de listagem e assets de marca são presença de loja viva e
  vêm no PR 4a.~~ **O 4a não o levou** — a ponta ficou escrita e não foi executada, e o repo
  Flutter passou o dia inteiro com o `pubspec.yaml` dizendo, num comentário, que não sabia
  regerar o próprio ícone de launcher e que a arte estava "no outro repositório". **Resolvido no
  PR 4c (24/08/2026)**: vieram as listagens, os dois masters, o `brand-icons.py` reapontado, o
  gráfico de destaque e um `README.md` triado. O projeto TWA (Bubblewrap, `twa-manifest.json`) é
  o pacote morto e fica para trás com o **T-52**, que segue item próprio. **A lição de método:**
  uma lista de "o que vem" escrita antes da execução não é conferência — o que confere é olhar o
  repositório de origem inteiro no fim, que é o que o PR F faz.
- **O esvaziamento abriu uma lacuna, e ela é do port.** Quatro testes unitários saíram junto com
  o `supabase/` que eles liam — os espelhos C#↔Deno (`RoleCatalogMirrorTests`,
  `EmailDateFormatMirrorTests`, `AuthMailMirrorTests`) e o `NotificationParamsCoverageTests`.
  As funções e as migrations que eles guardavam moram aqui; **os espelhos não, e ainda não têm
  equivalente em Dart**. Nada está quebrado — o que falta é o alarme, que é exatamente o modo de
  falha que esses testes existem para descrever: um espelho que ninguém confere apodrece calado.
- **O `git push` não autenticou na sessão que entregou o PR F** (leitura autorizada, escrita
  não: o proxy repassa o push cru e quem recusa é o GitHub). O esvaziamento foi entregue pela
  API — 234 deleções, uma chamada por arquivo, colapsadas pelo squash — e o conteúdo conferido
  byte a byte contra a árvore validada localmente. Fica registrado porque muda o custo de uma
  entrega: **binário não atravessa uma API que recebe conteúdo como string**, então um PR com
  assets depende de push de verdade.
