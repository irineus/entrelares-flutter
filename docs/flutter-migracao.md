# T-53 — Migração Flutter/Dart: colheita, spike e veredito

Leitura do lado do APP da aposta de plataforma (T-53). O registro vivo do piloto continua
em [`entrelares-console/docs/migracao-flutter.md`](https://github.com/irineus/entrelares-console/blob/main/docs/migracao-flutter.md);
o registro completo do item, em [`backlog/technical.md`](../backlog/technical.md) (T-53).
Este documento existe para que a colheita e o veredito morem no repositório do produto.

## Estágio 0 — colheita do benchmark (FEITO, 19/08/2026)

Resumo do que está detalhado no registro do T-53 em `backlog/technical.md`:

- **Provado pelo piloto** (`entrelares-console`, cliente Flutter DESTE backend em uso
  contra produção): `supabase_flutter` com as chaves S-16; **Realtime nativo** (aposenta a
  ponte F-29 e o `supabase.js` vendorizado); o contrato de sudo S-10 sobrevive aos dois
  transportes; regras puras em Dart testáveis sem emulador; functions com `verify_jwt` ON
  funcionam com a sessão normal; sessão de nuvem desenvolve, testa E builda APK.
  ⭐ **O pacote da Play `com.entrelares.app` aceita build Flutter** (mesma applicationId +
  mesma assinatura de upload) — o closed test não reinicia.
- **Oito lições pagas com defeito real** — hoje um checklist no `CLAUDE.md` do repo do
  spike: portão de `refreshSession()` antes de rotear; `42501` = sessão expirada;
  `signOut()` com fallback local navegando sempre; renovar antes de operação sensível;
  `INTERNET` ausente do manifest de release; keystore de debug é por máquina;
  `--split-per-abi`; singleton do Supabase → ambientes por flavor.
- **Não validado pelo piloto** (a migração prova): i18n bilíngue por leitor (U-13/U-24),
  push/APNs (F-09), deep links/assetlinks, persistência offline (T-18), Realtime sob
  carga real, iOS.

## Estágio 1 — spike de fatia vertical (19/08/2026)

Repositório: **`irineus/entrelares-flutter`** (novo, molde `desmalha`: monorepo
`apps/entrelares_app` + `packages/entrelares_core`, FVM 3.44.7, JDK 17, minSdk 26).
Decisão de CI em mente: fora deste repo para a esteira de produção nunca ver o
experimento; reversível por construção. `applicationId` do spike:
`com.entrelares.flutter`, para coexistir com o app da Play no aparelho do owner
(a troca para `com.entrelares.app` é do estágio 3).

**A fatia** — contra o projeto dev real (`buroanotfjcgvbfmacuh`), sem nenhum segredo:

| Camada | O que existe |
|---|---|
| Sessão | Login e-mail/senha; portão de `refreshSession()` ANTES de rotear; aviso "Sua sessão anterior expirou"; listener de `onAuthStateChange`; Sair com fallback local navegando sempre |
| Leitura sob RLS | `profiles` + `care_schedules` do mês visível |
| Calendário | Grade domingo-first, cores por `color_slot` (F-27/S-11), iniciais acessíveis em 3 camadas (F-28), dia trocado, contorno em hoje, legenda |
| Sheet do dia | Bottom sheet nativo: responsável efetivo, dia de transição (T-27) + horário de troca, observação; dias passados imutáveis (espelho do trigger) |
| Escrita | Definir o responsável do dia: INSERT sem id/tokens (trigger deriva `family_id`) e UPDATE de **linha inteira** ecoando `revision`/`submitted_token` (T-33/T-35); conflitos traduzidos (`salvou este dia primeiro`) |
| Realtime | **Nativo** — assinatura de `postgres_changes` em `care_schedules` recarrega o mês; o poll F-23 não existe neste stack |
| Melhorias nativas (diretriz do owner 18/08) | Swipe entre meses (PageView), bottom sheet, pull-to-refresh, haptics |

**Espelhos com teste** (`packages/entrelares_core`, 50 testes `dart test` — mesmos casos
da suíte C# `CalendarHelpersTests`): transição, trocado, slots, iniciais, rótulos
relativos PT-BR, tradução de erros de gravação, sessão expirada. Mais 10 testes de widget
no app (incluindo o eco T-35 sobrevivendo à edição e o conflito 23505 virando mensagem).

### Ergonomia (critério (c), observação qualitativa)

- A fatia inteira — fundação, port das regras com 60 testes, telas, Realtime — coube em
  **uma sessão de desenvolvimento**, na máquina Windows do produto, sem emulador para os
  testes de regra e com widget tests rodando em segundos. O ciclo `dart test` do core é
  o mesmo dos mirror tests C#; nada da disciplina atual se perde.
- A história de E2E fica para o estágio 2 (Patrol/integration_test no lugar do
  Playwright); os widget tests contra data source falso já cobrem o que os testes de
  componente cobrem hoje.

### Veredito do estágio 1

| Métrica | Critério | Emulador (piso de sanidade)¹ | Aparelho do owner² |
|---|---|---|---|
| Cold start até interativo | Não pior que o PWA | **~1,5 s** (mediana de 3: 2415/1509/1445 ms, `am start -W`, APK release) | 1,5s |
| Primeira interação (abrir um dia) | Não pior que o PWA | — (exige login; roteiro do owner) | Imediato, não percebo loading |
| Realtime (mudança de outro membro) | — (o PWA usa poll F-23) | — (exige login; roteiro do owner) | Imediato, ou menos de 1s de espera |
| APK | — | x86_64 18,7 MB | arm64 **17,3 MB** (universal seria ~52 MB) |

¹ Emulador x86_64 nesta máquina de dev — número com ressalva explícita.
² Roteiro em `entrelares-flutter/docs/medicao-estagio-1.md`; o número que decide é este.

**Go/no-go: GO — Flutter escolhido (owner, 19/08/2026).** Os três critérios atendidos no
aparelho físico: cold start igual ao piso do emulador (1,5 s), primeira interação sem
loading perceptível, Realtime refletindo a mudança de outro membro em ≤1 s — contra um
PWA que espera o intervalo do poll F-23. A aposta segue **reversível até o estágio 3**;
o que o GO mudou foi o sequenciamento abaixo e o passo seguinte: **estágio 2 (mapa de
paridade — executado, seção adiante)**.

## Sequenciamento (consequências do GO)

- **T-47 (US$ 99 + semanas) e T-40 NÃO executam** — existiam só para passar uma casca
  WebView pela Apple; o build iOS do Flutter é nativo. Ficam no board como descartáveis
  condicionais até o ponto sem volta (estágio 3), quando saem de vez.
- **T-48 obsoleto na forma atual** (Digital Goods API é mecanismo de Chrome/TWA); a
  versão Flutter precisa de Play Billing de verdade — redesenho entra no mapa do estágio 2.
- A triagem do que era seguro construir em Blazor valeu durante os estágios 0–2 e
  **deixou de valer em 19/08/2026** — o freeze imediato decidido nas tensões
  (política em [`flutter-paridade.md`](flutter-paridade.md)).

## Estágio 2 — mapa de paridade (FEITO, 19/08/2026)

O inventário completo vive em [`flutter-paridade.md`](flutter-paridade.md): 51 linhas na abertura, 52 desde a correção do lote 4
(a tabela `## Features` do README + U-13/U-24 e T-38 da seção de testes), cada uma com
veredito e estratégia de teste, agrupadas em 6 lotes de construção ordenados por
dependência — fundação/casco → calendário → workflow → conta/legal → premium/billing →
relatórios/plataforma. Números: **40 port · 4 redesign · 2 drop · 5 intocado**. O mapa
carrega ainda o desenho do T-48 redesenhado (Play Billing no canal loja, Asaas no rail
web, os dois webhooks convergindo em `set_family_plan`), a história de testes (unit
mirrors portam para `entrelares_core`, a suíte de integração C# FICA como gate do banco,
Playwright → Patrol) e as três tensões de produto — **decididas pelo owner em
19/08/2026** (Flutter Web substitui o PWA; Play Billing no estágio 3; freeze imediato,
com a política escrita no mapa).
