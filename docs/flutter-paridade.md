# T-53 — Estágio 2: mapa de paridade Flutter

Inventário feature-a-feature da reescrita, gerado da tabela `## Features` do
[`README.md`](../README.md) (fonte declarada pelo registro do T-53) mais os itens que vivem
só na seção de testes (U-13/U-24, T-38). Cada linha carrega um veredito e uma estratégia de
teste — é isto que transforma "rewrite" numa lista finita e agendável. Registro do item em
[`backlog/technical.md`](../backlog/technical.md) (T-53); colheita e veredito do estágio 1
em [`flutter-migracao.md`](flutter-migracao.md).

**Data:** 19/08/2026 · **Fonte:** README em `dev` (pós-F-48) · **Status da aposta:** GO do
estágio 1; reversível até o estágio 3.

## Como ler o mapa

**O princípio que encolhe o trabalho:** *o cliente espelha, o banco garante.* Schema, RLS,
triggers, RPCs, Edge Functions e todos os e-mails transacionais sobrevivem à reescrita
intocados — o mapa só marca o que o CLIENTE precisa fazer. Por isso a maior parte das
linhas é `port`: a regra já existe e já tem teste; o que se reescreve é apresentação.

| Veredito | Significado |
|---|---|
| **port** | A feature existe igual; a UI é reescrita em Flutter, a regra do servidor não muda |
| **redesign** | A feature muda de mecanismo no stack nativo (ex.: print do browser → PDF nativo) |
| **drop** | Não existe no app nativo — ou é web-only, ou o Flutter a torna desnecessária |
| **intocado** | Não tem metade de cliente relevante; nada a fazer na reescrita |

Coluna **Testes** — onde a cobertura da linha mora no stack novo:
`core` = espelho puro em `packages/entrelares_core` (`dart test`, mesma filosofia dos
mirror tests C#); `widget` = widget test com data source falso; `patrol` = E2E
Patrol/`integration_test`; `—` = a cobertura fica nas suítes de servidor atuais (ver
[Estratégia de testes](#estratégia-de-testes--a-história-e2e)).

---

## Lote 0 — o que o estágio 1 já entregou

Base viva no repo `irineus/entrelares-flutter` (50 testes core + 10 widget):

- Sessão: login e-mail/senha, portão de `refreshSession()` antes de rotear,
  `onAuthStateChange`, Sair com fallback local, `42501` → "sessão expirada".
- Calendário do mês sob RLS: cores por slot (F-27/S-11), iniciais em 3 camadas (F-28),
  dia trocado, contorno em hoje, legenda, swipe entre meses, pull-to-refresh.
- Sheet do dia nativo (leitura) + escrita do responsável com eco T-33/T-35 de linha
  inteira e conflitos traduzidos.
- **Realtime nativo** — o redesign da F-29 está FEITO neste stack (a ponte JS morre).

As linhas correspondentes abaixo aparecem com "(estágio 1 cobriu X)" e listam só o que falta.

## Lote 1 — fundação e casco

O que tudo depende; inclui os dois itens que o piloto NÃO validou e por isso devem ser
provados primeiro (U-13/U-24 e deep links).

| Feature | Veredito | O que o cliente faz | Testes |
|---|---|---|---|
| Authentication (login, recovery, throttling, timeout) | port | Estágio 1 cobriu login+portão. Falta: "Esqueci minha senha" + `/update-password` (vira deep link para o app), throttling progressivo client-side, timeout de inatividade de 30 min | core (throttling/timeout) + patrol |
| **U-13/U-24 — i18n bilíngue por leitor** | port | ⚠️ NÃO validado pelo piloto (console é PT-only) — provar no primeiro lote. Portar os catálogos PT/EN e o `LanguageResolver`; DISPLAY por idioma do leitor, TRANSPORT sempre ISO `yyyy-MM-dd` (o invariante U-24 não pode se mover). O renderizador de notificações (`type` + `params`) vem junto | core (paridade de catálogos, formatos, renderer byte-a-byte — port dos testes atuais) |
| Casco de navegação (bottom tab bar / nav desktop) | port | `NavigationBar` + rotas; deep links + `assetlinks.json` (⚠️ não validado — provar aqui, o convite e o recovery dependem) | widget + patrol |
| Today at a Glance (responsável de hoje, dias até a troca) | port | Card da home; cálculo do próximo handoff é regra pura | core + widget |
| T-41 — espelho das configurações públicas | port | Port do seam de parse/fallback do `SettingsService`; enforcement continua 100% no servidor | core |
| F-32 — espelho de entitlement (`EntitlementService`) | port | Mesmo espelho fail-closed lendo `is_premium()`/plan/trial | core |
| UX Feedback (toasts, barra de progresso, banners) | port | `SnackBar`/overlay nativos; banners âmbar de dia bloqueado | widget |
| Environment Tag (`[Dev]`) | port | Prefixo por flavor (dev/prod) — cai naturalmente do modelo de flavors | core (trivial) |
| Families & family-scoped security | intocado | RLS + stamping por trigger; o cliente não participa | — |
| Security Headers (HSTS/CSP/X-Frame…) | **drop** | Web-only; no app o papel é da assinatura (keystore T-55) e do TLS | — |

## Lote 2 — calendário completo

| Feature | Veredito | O que o cliente faz | Testes |
|---|---|---|---|
| Monthly Calendar | port | Estágio 1 cobriu grade, cores, iniciais, trocado, legenda, swipe. Falta: clamp de paginação ao horizonte F-39 | core (clamp) + widget |
| Custody Swap (flag visual + contagem) | port | Estágio 1 cobriu a flag; contagem é dos relatórios (lote 6) | core |
| Handoff Time | port | Campo de horário no sheet; exibição no card de hoje | widget |
| Schedule Editing (sheet completo + multi-seleção) | port | Estágio 1 cobriu responsável+observação. Falta: responsável planejado×efetivo, long-press (500 ms) para multi-seleção, marca de canto, guard de navegação | core (regras de seleção) + widget + patrol |
| Bulk Edit | port | A maior tela do lote: barra de ação, pre-fill de campos comuns, checkboxes "Limpar", skip de inválidos, contador `Salvando 2/3…`, resumo. As regras de elegibilidade/skip são puras → core | core (elegibilidade, resumo) + widget + patrol |
| Rotation Wizard | port | Pattern builder (ciclo de blocos), presets 7/7 etc., horário só em transição, só dias futuros não atribuídos — tudo regra pura já espelhada em C# | core + patrol |
| Day Protection (espelho no cliente) | port | Espelhos: dia passado imutável, dia congelado, planejado travado, alcance retroativo por tier (F-40) — o banco continua sendo quem garante | core |
| Admin mode | port | Toggle 🛡️, banner explícito, relaxamento tier-aware do editor | widget + patrol |

## Lote 3 — workflow de troca e notificações

| Feature | Veredito | O que o cliente faz | Testes |
|---|---|---|---|
| Swap Approval Workflow | port | Solicitação em vez de escrita direta, 🔔/⏳ nos dias congelados, aprovar/rejeitar/cancelar, mensagem F-44 (200 chars), resolução em massa (`🔔 Resolver`) | core (elegibilidade dos subsets) + widget + patrol (fluxo 2 usuários) |
| Revert Confirmation | port | Pedido de reversão + restauração exata é do servidor; cliente apresenta e pergunta da observação (F-47) | core (NotesDifferForRevert) + patrol |
| Urgency Alerts (⚠️/⏰ dinâmicos) | port | Tags de prioridade computadas no cliente — espelho já existe e foi parcialmente portado no estágio 1 | core |
| Auto-approval (F-24) | intocado | Cron server-side; cliente só exibe `🤖 Automático` | widget (exibição) |
| Notifications (página 3 abas + badge) | port | Badge em tempo real via Realtime nativo; refresh nos mesmos gatilhos | widget + patrol |
| Real-time Push (F-29) | **redesign (FEITO)** | Ponte supabase-js morre; `postgres_changes` nativo (estágio 1). Decisão pendente do registro: manter um poll de segurança estilo F-23 até o socket provar-se sob carga real | patrol (a atualização cruzada) |
| Email Notifications | intocado | Edge Functions + Resend não mudam; o app não envia e-mail | — |

## Lote 4 — conta, família e legal

| Feature | Veredito | O que o cliente faz | Testes |
|---|---|---|---|
| Self-service Sign-up | port | `/register` nativo: nome, família, e-mail, senha, papel (grade de chips); criação atômica é do trigger; declaração de consentimento S-15 por ramo (fundador × convidado) | core (ConsentDeclarations) + patrol |
| Family Invitations | port | Convite por e-mail com papel; o link `/register?invite=<token>` vira **deep link** do app (assetlinks do lote 1); fallback copiável continua | patrol |
| Família Page | port | Roster de membros com badge 🛡️, convites (criar/reenviar/revogar/copiar/compartilhar), rename, toggle admin. ⚠️ **Correção 19/08/2026, na construção do lote 4:** promote/demote e troca de papel NÃO ficam aqui — F-16 moveu toda edição de membro para a página de perfil (`FamilyPage.razor:62` documenta a decisão), e a página é read-only | widget + patrol |
| **Página de Perfil (`/profile`, `/profile/{id}`)** | port | ⚠️ **Linha ausente do mapa até 19/08/2026** — descoberta na construção do lote 4 e obrigatória: nome, papel, flag de admin (sudo), e-mail, senha, export LGPD e a saída da família vivem todos aqui | widget + patrol |
| Caregiver Role Catalog (21 papéis) | port | Espelho do catálogo já existe em C# → port direto | core |
| F-41 — papéis customizados | port | Página `/custom-roles`, picker de emoji curado, regras de formulário (espelho `CustomRoleRules`) | core + widget |
| Sudo S-10 | port | `runWithSudo` provado no piloto: sheet 🔐, janela de 5 min, `ELEVATION_REQUIRED:` nos dois transportes | core (detecção do marker) + patrol |
| Leave the Family (S-11) | port | Saída sudo-gated, tela `/leaving` de restauração (deep link), aviso de migração cross-family | patrol |
| Delete the Whole Family (S-11 PR2) | port | Banner persistente de estado, consentimento/recusa, execução antecipada sudo | patrol |
| Data Export & LGPD (F-17/S-13) | port | Export JSON — melhoria nativa: share sheet do sistema em vez de download do browser. Gate de re-consentimento S-15 (`/policy-update`) com espelho `PolicyVersions.Evaluate` | core + patrol |
| Páginas legais (`/privacy`, `/terms`) | port | Conteúdo estático; acessíveis também sem loja (link externo aceito pelas lojas) | widget |
| First-run onboarding (U-23) | port | Checklist por estado real + sheet "Como funciona a troca"; o tour de 4 paradas é **redesign leve** (spotlight nativo em vez de overlay DOM) | widget + patrol |

## Lote 5 — premium e billing

**ENTREGUE em 20/08/2026** (5 PRs, `entrelares-flutter` #31–#35 + o PR pareado de
servidor aqui — detalhe no registro do [plano de cutover](flutter-cutover.md#registro-das-entregas-do-estágio)).
O lote onde mora o único redesign grande da migração.

| Feature | Veredito | O que o cliente faz | Testes |
|---|---|---|---|
| Freemium & Premium (F-32) | port | Espelho de entitlement (lote 1) + seção premium/waitlist da Família | core + widget |
| Gate — cuidadores extras (F-37) | port | Hint de upsell no cap; enforcement é do `create_invitation` | widget |
| Gate — horizonte de planejamento (F-39) | port | Clamp do calendário e do wizard ao horizonte da família | core |
| Gate — Gestor × Administrador (F-40) | port | Alcance retroativo tier-aware no espelho de proteção de dia (lote 2) | core |
| Gate — papéis customizados (F-41) | port | Create/edit gated, delete livre — espelho no formulário | core |
| Quota de e-mail (F-38) | intocado | Contador e fail-open no servidor; avisos chegam como notificações normais | — |
| **Subscription & billing (T-39) + T-48** | **redesign** | **O redesenho T-48 entra aqui** (detalhe abaixo): canal loja usa Play Billing; o checkout Asaas continua no rail web. O cliente Flutter ganha a tela de assinatura por canal | core (regras de canal/estado) + patrol (fluxo de teste da Play) |
| Payment history (F-43) | port | Expansão lazy da timeline sanitizada (`get_billing_history`) | widget |
| Store shell (T-38) | **drop** | A casca TWA morre — o app Flutter É o canal loja. A detecção de canal deixa de ler referrer: o flavor/instalador declara `channel=store` por construção | core (mapeamento de canal) |

### T-48 redesenhado — Play Billing de verdade

A Digital Goods API era um mecanismo de Chrome/TWA; num app nativo a Play **exige Play
Billing** para assinatura digital vendida dentro do app. O desenho que preserva tudo o que
T-39 já construiu:

- **Dois rails, um dono da verdade.** O rail web (Asaas: recorrente + Pix avulso F-48)
  continua servindo o PWA/landing enquanto existirem; o rail loja usa Play Billing
  (produto de assinatura mensal/anual). Ambos convergem no banco: um novo webhook de RTDN
  (Real-Time Developer Notifications, via Pub/Sub → Edge Function) aplica efeitos pelo
  MESMO `set_family_plan` e grava no MESMO ledger `billing_events` — idempotente por
  event id, como o webhook Asaas.
- **Nada de preço divergente silencioso**: o preço da loja carrega a taxa do Google
  (15% no tier de assinaturas até US$ 1M) — decisão de preço por rail é do owner e fica
  aberta no mapa; o piso Asaas (R$ 5,00) não vale para a Play.
- **O que NÃO muda**: `subscriptions`, `billing_events`, `set_family_plan`,
  grace window (`billing.grace_days`), aviso B-3, cancelamento honrando período pago,
  renovação aditiva, master switch `billing.enabled`.
- Sequenciamento: é o último lote funcional ANTES do cutover (estágio 3) — o app pode
  entrar em teste fechado com billing apontando para o rail web via waitlist (como o
  F-32 já faz com `billing.enabled=false` no canal), destravando os lotes 1–4 primeiro.

**Como foi construído (20/08/2026).** O trilho da loja tem **interruptor próprio**,
`billing.store_enabled` (público, começa `false`), independente do `billing.enabled` que
rege o rail web — os dois vão ao ar em momentos diferentes, e enquanto o da loja estiver
desligado o Android continua na nota neutra T-38. Essa nota também é o padrão de FALHA:
sem loja no aparelho, com a consulta de produtos estourando ou sem produto publicado, o
ramo de loja cai nela, porque oferta que a loja não honra é pior do que oferta nenhuma.
**O preço do canal loja é o da Play**, formatado pela loja para o país do comprador; o
`app_settings` continua regendo só o rail web (decisão do owner, 20/08/2026). E **o
cliente não concede nada**: a compra é alegação, o token vai ao `billing-store-verify`,
que pergunta à Play Developer API se ela é real e até quando paga — o acknowledge só
acontece depois que o servidor aceita, porque a Play estorna compra não reconhecida em
três dias e reconhecer uma que o servidor recusou deixaria a família paga e sem direito.
O que ficou **de fora do código e é trabalho de console do owner**: criar os dois produtos
de assinatura, publicar a faixa fechada, ligar as RTDN via Pub/Sub e criar a service
account com acesso à Play Developer API. O interruptor só vai a `true` depois disso.

## Lote 6 — relatórios, analytics e plataforma

**ENTREGUE em 19/08/2026** (5 PRs, `entrelares-flutter` #26–#30 — detalhe no registro do
[plano de cutover](flutter-cutover.md#registro-das-entregas-do-estágio)). O F-45 adiado
pelo lote 3 chegou aqui, com o espelho de auditoria, como estava combinado.

| Feature | Veredito | O que o cliente faz | Testes |
|---|---|---|---|
| Reports — Summary | port | Cards planejado × efetivo por membro; contagens são regra pura | core + widget |
| Reports — Audit | port | Timeline com before/after + "carregar mais" incremental; frase de origem F-45 é espelho | core (origem) + widget |
| Reports — History PDF (F-33) | **redesign** | O `print()` do browser não existe: gerar PDF nativo (packages `pdf`/`printing`) e entregar pelo share sheet. A montagem do relatório (período, tabela por cuidador, timeline, opção U-20/U-07 de saldo projetado) é regra pura já espelhada. A copy honesta pós-S-15/C-7 vem verbatim | core (montagem, U-20/U-07) + widget |
| Product analytics (T-37) | port | Umami é HTTP puro — o app envia os mesmos eventos; sanitização de path (sem query/GUID) é espelho | core (sanitização/no-PII) |
| PWA & Offline | **redesign** | O service worker não porta. Instalação vem da loja (banner de install morre); splash é nativo. Persistência offline REAL vira o **T-18** com o benchmark Drift+SQLCipher do desmalha — fora do escopo de paridade (o PWA atual também só faz cache de casco). **Feito no lote 6:** o que a tensão 1 exige do canal — target web habilitado e `flutter build web` no `verify.yml`, com o peso gzip do first-load impresso a cada run | — (T-18 terá os seus) |
| Backup & ops (R2, keep-alive, cron) | intocado | Infraestrutura de servidor; nada de cliente | — |

## Itens em voo durante a transição

A triagem do T-53 mandava construir a metade servidor de F-56 (modo solo), F-55 (entidade
filho), F-52 (aviso) e F-51 (RPC) enquanto os estágios corriam — **ela deixou de valer em
19/08/2026 com o freeze imediato** (tensão 3), mas a metade servidor desses itens continua
livre pela própria política. **As telas desses itens nascem direto em Flutter no
estágio 3** — nenhuma ganha UI Blazor.

## Resumo numérico

**52** linhas ao todo (F-32 e F-41 aparecem duas vezes de propósito — espelho/página e gate
são trabalhos distintos). Eram 51 até 19/08/2026, quando a construção do lote 4 encontrou a
página de Perfil ausente do inventário — a única linha que o mapa deixou passar em seis lotes:

| Veredito | Linhas | Leitura |
|---|---|---|
| port | 41 | UI reescrita, regra intocada — o grosso, e o mais barato por linha |
| redesign | 4 | Realtime (FEITO no estágio 1), billing T-39/T-48 (o único grande), PDF F-33, PWA/offline |
| drop | 2 | Security headers, store shell T-38 |
| intocado | 5 | E-mail, quota F-38, auto-approval, RLS/stamping, backup/ops |

---

## Estratégia de testes — a história E2E

A pirâmide atual tem três camadas; o destino de cada uma é diferente:

| Camada atual | Destino | Racional |
|---|---|---|
| `Entrelares.Tests` (23 classes, xUnit) | **Porta para `entrelares_core`** (`dart test`) | São espelhos de regra de cliente — precisam viver na linguagem do cliente. O estágio 1 já portou os 50 casos de `CalendarHelpersTests`; o mapa acima marca `core` em cada linha com regra pura |
| `Entrelares.IntegrationTests` (39 classes) | **FICA em C#** | Testa o BANCO via PostgREST/RPC — não depende de nenhuma linha de Blazor. Continua sendo o gate das regras de DB no CI atual, inclusive depois do cutover (só precisa do SDK .NET no runner, não do app). Portar seria custo alto para cobertura idêntica |
| `Entrelares.E2ETests` (Playwright) | **Substituída por Patrol/`integration_test`** | A UI testada deixa de existir. Patrol dirige o app real no emulador Android, com o mesmo padrão de família descartável (`E2E-<runId>`, membros `@resend.dev`, `purge_e2e_family` revalidando a assinatura no banco) |

Decisões que o estágio 3 herda daqui:

1. **A lane E2E roda no CI do repo Flutter** — ABERTA em 19/08/2026 com o lote 3 (o
   primeiro fluxo de 2 usuários, o workflow de troca), em `integration_test` em vez de
   Patrol: o pacote oficial cobre o fluxo sem dependência extra. Filtro de pack mantido
   (`E2E_PACK=p0` de fumaça · `full` antes de promover), mas a **cadência mudou na
   entrega**: agendada (06:10 UTC) + `workflow_dispatch`, nunca por push — um run de
   emulador custa ~10-15 min da cota de 2000 min/mês compartilhada com os repos do
   produto, a mesma aritmética que manteve o build de APK fora do gate.
2. **Widget tests com data source falso** cobrem o que os testes de componente cobrem
   hoje — rápidos, sem emulador, rodáveis em sessão de nuvem.
3. **Nenhuma regra nova sem espelho**: a disciplina "todo espelho tem teste na camada
   core" é a mesma dos helpers C# — o mapa marca onde cada uma cai.

## As três tensões — DECIDIDAS pelo owner (19/08/2026)

O registro do T-53 exigia resposta antes do estágio 3. As recomendações deste mapa eram
mais conservadoras em 1 e 3; o owner decidiu com elas na mesa e **reafirmou as opções
abaixo** — que são a palavra final:

1. **Web — Flutter Web SUBSTITUI o PWA** (recomendação apresentada era congelar o PWA e
   medir antes de escolher). Consequências operacionais: o repo `entrelares-flutter`
   ganha o target **web** e o `verify.yml` passa a cobri-lo — **feito no lote 6,
   19/08/2026**, com o peso gzip do first-load impresso em cada run; o **first-load em
   Android mediano/4G vira critério de ACEITE do canal web dentro do estágio 3** —
   aceite de canal, não reabertura da decisão, e a medição no aparelho segue pendente; o PWA Blazor só desliga no cutover (estágio 4),
   nunca antes — o canal web não fica sem app; a promessa da landing (*"Sem loja de
   apps"*) segue verdadeira, com o web como canal de primeira classe.
2. **Billing — Play Billing JÁ no estágio 3**, no caminho crítico (lote 5, o desenho
   T-48 acima): Play Billing no canal loja, Asaas no rail web, os dois webhooks
   convergindo em `set_family_plan` + ledger. Até o card ficar pronto, o build da Play
   usa o paywall neutro (padrão T-38) — nunca link externo de checkout no build da loja.
3. **Duas stacks — freeze IMEDIATO do Blazor** (recomendação apresentada era formalizar
   na abertura do estágio 3). A política abaixo vige desde 19/08/2026; a triagem do
   T-53 deixou de valer nessa data. Cada lote vira PR com checklist de aceitação por
   tela; o rollback do registro (válido até o último usuário migrar) referencia esses
   checklists; **cutover único e datado** no estágio 4.

### Política de freeze do Blazor (vigente desde 19/08/2026, decisão do owner)

1. **Nenhuma feature nova em Blazor.** Feature nova de cliente nasce em Flutter, na
   ordem dos lotes deste mapa.
2. **O que ainda entra no Blazor:** correção crítica (defeito afetando usuários reais em
   produção), segurança, obrigação legal (LGPD/re-consent/S-15) e ajustes exigidos pelo
   próprio cutover.
3. **A metade servidor continua livre** — banco, RLS, RPCs, Edge Functions e e-mails
   servem as duas stacks e sobrevivem à reescrita por definição.
4. **QA e monitoramento do canal web continuam até o cutover** — congelado ≠ abandonado;
   produção carrega assinaturas reais.
5. Exceção só com decisão explícita do owner registrada no board.

## O que este mapa deixa explícito como ainda não provado

Push/APNs (F-09), deep links + assetlinks num casco Flutter (lote 1 prova), offline real
(T-18), Realtime sob carga real (rede de segurança do lote 3), iOS de ponta a ponta (lane
Codemagic do benchmark desmalha; o veredito de publicabilidade T-47 morreu com o GO — o
build iOS é nativo).
