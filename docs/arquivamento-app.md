# Arquivamento do `entrelares-app`

**Aberto e FECHADO em 24/08/2026.** Objetivo: tornar o repositório `entrelares-app`
**arquivado** — sem precisar ser atualizado e, principalmente, **sem precisar ser consultado**.
Tudo que diz respeito ao aplicativo Entrelares passa a viver aqui, no `entrelares-flutter`. O
`entrelares-site` continua existindo e responde por tudo do site.

> **Estado em 24/08/2026, fim do dia:** as dezessete fatias entraram, incluindo a última — o
> **desligamento do cliente Blazor**, que o plano deixava sem data. Ele não chegou pela medição
> da decisão 7: o owner declarou a rota de rollback desnecessária, que é a decisão que a medição
> existia para provocar. O que resta são **ações de console do owner**, listadas em
> [§ O que falta, e é do owner](#o-que-falta-e-é-do-owner) — nenhuma delas é código, e nada está
> em risco enquanto esperam.

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
| 7 | ~~**O desligamento do Blazor tem condição medida**: N dias consecutivos sem acesso a `legado.entrelares.app`~~ **Ultrapassada em 24/08/2026** | Ela trocava "quando o owner constatar" por um gatilho verificável, para que o passo final não ficasse à deriva. Funcionou como pretendido e nunca precisou disparar: o owner constatou no mesmo dia. Uma condição medida é um seguro contra a decisão que não vem — não um requisito da decisão que vem |
| 8 | **Os commits presos em `dev` são promovidos** assim que o E2E fechar | É a última promoção do Blazor. **Bloqueada em 24/08/2026** por um ruleset que exige o status check `deploy` — o check da esteira que o desligamento remove; ver § O que falta |

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
| **6…16** ✅ | flutter | **O port do gate para Dart** (24/08/2026), suíte por suíte — o fatiamento detalhado está na seção seguinte. O PR 6 levou a fundação (contratos erguidos, clientes por identidade, fixture) e uma suíte real como prova; o 16 apagou `db-gate/` e o lane `dotnet`. As 225 asserções são todas Dart |
| **F** ✅ | app | **O esvaziamento, num toque só** (24/08/2026, [`entrelares-app` #309](https://github.com/irineus/entrelares-app/pull/309)): 242 arquivos, −46.941 linhas. Sobra o cliente Blazor, sua suíte unitária e um `deploy.yml` reduzido à metade que publica — o deploy de QA que seguiu o merge fechou **verde em 1 min 39 s**, contra os ~15 min do gate antigo. Saíram também, por decisão do owner, as DUAS suítes C# e o `dependabot.yml`; o que ficou para trás e por quê está no registro do T-56. Não arquiva ainda |
| **G** ✅ | app | **O desligamento** (24/08/2026, [`entrelares-app` #310](https://github.com/irineus/entrelares-app/pull/310)): sai o `deploy.yml` inteiro — a metade que publicava —, sai o modelo de PR que ainda instruía um fluxo sem deploy atrás dele, e os dois documentos passam a descrever um arquivo em vez de um cliente publicado. `E2ETests` e `IntegrationTests` já tinham saído no PR F. Com ele morrem o alias de QA `qa.entrelares.app` e a última esteira fora daqui que ainda alcançava produção |
| **∅** | app | **O que sobra é console do owner**: apagar o ruleset do `master`, promover `dev`→`master`, tirar domínio e projeto Pages no Cloudflare, arquivar. Ver § O que falta |

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
| 7 ✅ | RLS, adversarial e consentimento | 752 |
| 8 ✅ | Regras de dia (proteção, transição T-27, horizonte, concorrência) | 647 |
| 9 ✅ | Workflow de troca (auto-aprovação, mensagens, reversão, log) | 618 |
| 10 ✅ | Conta e exclusão (conta, família, perfil, idioma) | 812 |
| 11 ✅ | Convites e multi-cuidador | 628 |
| 12 ✅ | Operador de plataforma + RPCs de admin | 698 |
| 13 ✅ | Sudo, papéis customizados, settings, auth de functions | 997 |
| 14 ✅ | Billing do rail web | 1.064 |
| 15 ✅ | Billing de loja e webhook | 436 |
| 16 ✅ | Apaga `db-gate/` e a lane `dotnet` do workflow | — |

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

### O que a travessia encontrou (fechada em 24/08/2026)

Os onze PRs fecharam no mesmo dia em que abriram. A aritmética fechou: **225 no começo, 225 no
fim**, com a soma impressa no summary de cada run e repetida no corpo de cada PR. O que sobra
registrado não é o placar, são os quatro achados — três deles coisas que só aparecem quando o
gate roda contra o banco de verdade, e um sobre método.

- **Um defeito de produção, achado pelo PR 7.** `FamilyDeletionRequest.fromJson` lia
  `created_at`; a coluna chama `requested_at` e a tabela não tem a outra. O app parseia por essa
  MESMA fábrica e a tela de Família renderiza `requestedAt`, então **a tela quebrava para toda
  família com pedido de exclusão pendente** — em produção, desde o cutover. Nenhum teste de
  widget podia pegar: eles constroem o objeto em memória, e o nome da coluna é uma afirmação
  sobre uma tabela que ninguém estava perguntando. Isto é o argumento inteiro para um gate de
  banco, e vale mais do que os 225 verdes.
- **A varredura adversarial precisou de uma tradução INFIEL, de propósito.**
  `CrossFamilyAuditLog_IsNotReadable` lia `activity_logs` sem filtro e explodia o
  `statement_timeout` de 8 s conforme o projeto de QA acumulava linhas — o teste morria antes da
  asserção, parecendo vazamento de RLS. A versão Dart filtra pelo id da linha da outra família e
  afirma que veio vazio: mesma afirmação, custo constante. O cabeçalho da suíte diz isso, para
  que a divergência não se leia como descuido.
- **Uma armadilha de string, cara porque mentia sobre a causa.** O sufixo do `runId` era hex
  de caixa mista; o GoTrue guarda e-mail em MINÚSCULAS, então toda busca por endereço errava —
  e o sintoma era `Bad state: No element` num `.single`, que se lê como "a regra não disparou" e
  é "a string não bate". O `runId` é minúsculo desde o PR 7.
- **Analisar a árvore de trabalho não é analisar o commit.** Um PR foi vermelho porque um
  arquivo novo ficou fora do `git add`: o `analyze` local via os dois, o CI via um. Desde então a
  verificação é `git stash push --keep-index -u` → `analyze` → `git stash pop`, que mostra ao
  analisador exatamente o que está no índice.

Uma consequência de escopo, para não ficar implícita: **a autorização de merge desta seção morre
aqui**. Do próximo item em diante vale de novo a regra do `CLAUDE.md` — PR e squash-merge só com
o OK explícito do owner. (Os dois PRs que fecharam o item — o dos espelhos aqui e o do
desligamento lá — foram autorizados um a um, não por ela.)

~~O que a travessia **não** resolveu: os quatro espelhos C#↔Deno.~~ **Resolvido no mesmo dia**,
depois do desligamento — `packages/entrelares_core/test/mirrors/`. Ficaram no pacote CORE, e não
no app, porque não precisam de Flutter e o lane do core roda primeiro: um drift fica vermelho no
job mais barato do run.

**E o port de um deles achou uma metade faltando, que é o argumento inteiro para tê-los
reposto.** O `AuthMailMirrorTests` afirmava que o cliente escreve `?lang=` no `redirect_to` do
reset; o app Flutter nunca escreveu. Nada estava quebrado, e é exatamente por isso que
atravessou o cutover sem ninguém notar: a `send-auth-email` tem o `profiles.language_detected`
como terceiro sinal e o app escreve essa coluna, então quem já entrou uma vez continuava
recebendo o idioma certo. Mas o sinal 2 é o único que serve para quem **não consegue entrar** —
que é a definição de quem pede uma redefinição de senha — e estava sempre ausente. Reposto com
`DeepLinkUrls.updatePasswordFor(idioma)` e a chave compartilhada em `AuthMail.languageQueryParam`.
A pior hipótese foi conferida contra o CÓDIGO e não herdada do registro do Blazor: se a
allow-list de Redirect URLs não casar com query string, o GoTrue cai no Site URL — e o
`AuthChangeEvent.passwordRecovery` roteia para `/update-password` de onde o app estiver.

O espelho do reset é a única tradução que FORTALECE o original: o C# fixava um método pelo nome
e este app tem dois pontos de reset, então a versão Dart lê todos os call sites de
`resetPasswordForEmail` sob `lib/`. Os quatro foram medidos antes de merecerem confiança, com
cinco sondas vermelhas de propósito — mesma disciplina do gate de fluxo do PR 5.

## O armamento do PR 3 — FEITO (conferido em 24/08/2026)

O código do PR 3 entrou desarmado: sem os secrets, cada passo pulava com nota no summary em vez
de pintar o `main` de vermelho. **O owner armou tudo no mesmo dia**, e isto foi conferido contra
o CI, não contra a memória:

- o job **`db-prod` rodou verde** no push de `main` que fechou o PR 16 — logo os três secrets de
  produção existem e é este repo que aplica schema em produção;
- o **`backup.yml` daqui fechou verde** num `workflow_dispatch` — logo os quatro secrets do R2
  existem;
- as duas cópias antigas estão **`disabled_manually`** no `entrelares-app` desde 24/08 — o
  handover foi `gh workflow disable`, não apagar secrets, porque aquele `backup.yml` **falha**
  com secret ausente por decisão de projeto e apagá-los trocaria "dois backups por semana" por
  "um vermelho por semana".

O `keepalive-dev.yml` daqui não precisou de secret novo: a URL do dev é pública (a mesma do
`env.dart`) e a `SUPABASE_SERVICE_ROLE_DEV` já existia aqui.

## O que falta, e é do owner

Quatro ações de console, nenhuma delas código. **Nada está em risco enquanto esperam**: arquivar
torna o repositório somente-leitura, e o próprio ruleset já impede qualquer push naquele branch.

**1. Apagar o ruleset do `master` do `entrelares-app`.** A promoção da decisão 8 foi RECUSADA
por ele: exige o status check **`deploy`**, que é produzido pela esteira que o desligamento
remove. É um cadeado que sobreviveu à porta — ele protegia uma produção que o desligamento
acabou de aposentar, e satisfazê-lo significaria recolocar uma esteira num arquivo.
→ https://github.com/irineus/entrelares-app/settings/rules — abrir o ruleset que cobre
`refs/heads/master`, botão **Delete ruleset** (ou desmarcar *Require status checks to pass* e
salvar, se preferir manter o registro dele).
*Sucesso:* a tela de rules deixa de listar o ruleset ativo para `master`.

**2. Promover `dev`→`master`** (a última promoção do Blazor). Depois do passo 1:

```powershell
git -C <caminho>\entrelares-app fetch origin
git -C <caminho>\entrelares-app checkout master
git -C <caminho>\entrelares-app merge --ff-only origin/dev
git -C <caminho>\entrelares-app push origin master
```

*Sucesso:* `git log --oneline -1 origin/master` mostra
`chore: o cliente Blazor desliga — a rota de rollback deixa de existir (#310)`. Não haverá run
de Actions: o `deploy.yml` sai neste mesmo commit.
*Por que importa mesmo com o repo indo para o arquivo:* o `master` de hoje ainda carrega o
`deploy.yml` PRÉ-esvaziamento, com os passos *"Aplicar migrations e functions em PRODUÇÃO"*
apontando para um `supabase/` parado desde o PR 3. É o risco de dois escritores que a decisão 5
existe para impedir, e ele só morre quando aquele branch deixa de carregar aquele arquivo.

**3. Tirar o domínio e o projeto Pages no Cloudflare.**
→ https://dash.cloudflare.com → **Workers & Pages** → projeto **`entrelares-app`** →
**Settings → Domains & Routes**: remover **`legado.entrelares.app`** (e o alias de QA
**`qa.entrelares.app`**, que era alimentado pelo branch `dev`). Depois, no mesmo projeto,
**Settings → Delete project**.
*Sucesso:* `legado.entrelares.app` deixa de resolver para o projeto; o DNS do domínio pode ser
removido em seguida na zona `entrelares.app`.
*Atenção à ordem:* faça isto **depois** do passo 2, para que o commit que descreve o
desligamento já esteja no branch que servia a produção.

**4. Arquivar o repositório.**
→ https://github.com/irineus/entrelares-app/settings → rolar até **Danger Zone** →
**Archive this repository** → confirmar digitando `irineus/entrelares-app`.
*Sucesso:* o repositório passa a exibir a faixa *"This repository has been archived by the
owner"* e fica somente-leitura. Arquivar também desliga agendamentos — e é por isso que o
`backup.yml` e o `keepalive-dev.yml` vieram para cá no PR 3, meses antes de precisarem.
*Reversível:* desarquivar é um clique, se algum dia for preciso.

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
- ~~**O esvaziamento abriu uma lacuna, e ela é do port.**~~ **Fechada em 24/08/2026, no mesmo
  dia em que abriu.** Os quatro espelhos C#↔Deno viraram suítes Dart em
  `packages/entrelares_core/test/mirrors/`, e o port de um deles achou uma metade faltando no
  app (o `?lang=` do reset) — o detalhe está na seção do port. A lacuna durou horas, mas vale
  registrada: ela não apareceu na lista do que vinha, apareceu ao reler o repositório de origem
  inteiro. É a mesma lição de método do `store/`, cobrada duas vezes no mesmo dia.
- **O `git push` não autenticou na sessão que entregou o PR F** (leitura autorizada, escrita
  não: o proxy repassa o push cru e quem recusa é o GitHub). O esvaziamento foi entregue pela
  API — 234 deleções, uma chamada por arquivo, colapsadas pelo squash — e o conteúdo conferido
  byte a byte contra a árvore validada localmente. Fica registrado porque muda o custo de uma
  entrega: **binário não atravessa uma API que recebe conteúdo como string**, então um PR com
  assets depende de push de verdade.

- **O cancelamento do `verify.yml` era do WORKFLOW, e por isso alcançava o `db-gate`.** O achado
  ficou escrito no PR de documentação e deliberadamente não corrigido lá; foi corrigido em
  24/08/2026, junto com os espelhos. Um job **não consegue** se eximir de um cancelamento de
  nível de workflow, então o grupo serializado do `db-gate` — que existe justamente para duas
  suítes nunca se sobreporem — vinha sendo morto no meio assim mesmo, e um run morto antes do
  teardown deixa família órfã para a varredura recolher duas horas depois. O cancelamento desceu
  para os jobs que podem pagá-lo (`verify`, `apk`, `e2e`, `web-e2e`); o `db-gate` mantém o grupo
  de repo inteiro, e **`db-prod` e `deploy-web` passam a ENFILEIRAR** — essa última parte é mais
  larga que o achado e foi tomada de propósito: era o grupo de workflow que os protegia, e
  removê-lo sem repor deixaria um push concorrente capaz de interromper um deploy de produção
  pela metade.

- **Um required status check é uma dependência da EXISTÊNCIA de uma esteira.** A promoção da
  decisão 8 foi recusada por um ruleset que exige o check `deploy` — o check da esteira que o
  próprio desligamento remove. Não era ordem errada da entrega: qualquer ordem esbarraria nisso,
  porque o commit que apaga a esteira é o commit que precisa do check dela. A generalização vale
  para a próxima vez: **toda entrega que remove uma esteira deve perguntar o que ainda exige os
  checks dela** — branch protection, ruleset, badge, automação externa. O desbloqueio é do owner
  e está em § O que falta.
