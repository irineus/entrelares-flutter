# Entrelares — Flutter (T-53, aposta de plataforma)

A reescrita do [Entrelares](https://github.com/irineus/entrelares-app) (hoje Blazor WASM
PWA) em **Flutter/Dart**. Nasceu como spike do **estágio 1**; com o GO do owner
(19/08/2026) e o **estágio 3 aberto**, este repositório é o app de produto sendo
construído lote a lote pelo mapa de paridade (`entrelares-app/docs/flutter-paridade.md`,
ordem 1→2→3→4→6→5).

**Estado:** os **seis lotes estão entregues** (20/08/2026, com o lote 5 — premium/billing e
o redesenho T-48 de Play Billing). O estágio 3 está funcionalmente completo; o que vem é o
**cutover do estágio 4**. O Blazor segue congelado e em produção até lá — enquanto o cutover
não acontece, rollback é não fazer nada.

## Estrutura (molde `irineus/desmalha`)

```
.fvmrc                        # pin do Flutter (3.44.7) — só o .fvmrc é versionado, .fvm/ não
tool/setup_env.sh             # bootstrap idempotente de ambiente Linux (JDK 17, FVM, Android SDK)
packages/entrelares_core/     # Dart puro: espelhos-cliente das regras do servidor, testáveis com `dart test`
apps/entrelares_app/          # o app Flutter (só orquestra e apresenta)
```

## Comandos

```
fvm flutter --version                                  # 3.44.7 (pinado)
cd packages/entrelares_core && fvm dart test           # regras puras, sem emulador
cd apps/entrelares_app && fvm flutter analyze && fvm flutter test
cd apps/entrelares_app && fvm flutter build apk --debug --flavor dev --split-per-abi
# E2E (lote 3): app real em emulador contra o projeto dev — exige a service_role key
cd apps/entrelares_app && fvm flutter test integration_test/swap_workflow_test.dart \
  --flavor dev --dart-define=E2E_SUPABASE_SERVICE_ROLE_KEY=<chave dev>
```

**Flavors (estágio 3):** todo build Android exige `--flavor dev` ou `--flavor prod` —
ambientes são variantes de build (o singleton do Supabase inicializa uma vez por
processo), nunca um switcher de runtime. `dev` = `com.entrelares.flutter` contra o
projeto dev ("Entrelares Dev" no launcher, título com `[Dev]`); `prod` =
`com.entrelares.app` (o pacote da Play) contra produção. Builds release assinam por
flavor via `key.properties` (T-55 — ver "Assinatura (release)" abaixo). `fvm flutter
test` não tem flavor e cai em dev por construção.

**CI (T-54):** todo push/PR roda `.github/workflows/verify.yml` — analyze + `dart test`
no core e analyze + `flutter test` no app, com o Flutter lido do `.fvmrc`. O build de
APK fica FORA do gate (cota de 2000 min/mês da conta, compartilhada com os repos do
produto) — para gerar APK pela CI, use o `workflow_dispatch` com `build-apk`. O APK
da CI é **debug** (o runner não tem — e nunca terá — os keystores do T-55; release é
build local por construção).

**Lane E2E (aberta pelo lote 3 do T-53):** `integration_test/` dirige o app REAL em
emulador contra o projeto dev, no primeiro fluxo de 2 usuários (workflow de troca) —
o **banco é a asserção**, não a UI. Família descartável por execução no mesmo padrão
da suíte web (`E2E-<runId>`, e-mails `@resend.dev`, teardown sempre via
`purge_e2e_family`, cuja guarda de assinatura dupla vive no BANCO; varredura de
órfãs > 2h no início). Também fora do gate por custo de minutos: roda **agendada
(06:10 UTC diário)** e sob demanda pelo `workflow_dispatch` (`run-e2e`, com
`e2e-pack` = `p0` de fumaça ou `full`). A `service_role` do dev chega só pelo secret
`SUPABASE_SERVICE_ROLE_DEV` → `--dart-define`; nunca entra no repositório.

## Assinatura (release) — T-55

Builds **release** exigem `apps/entrelares_app/android/key.properties` (git-ignorado);
sem ele o build **falha com erro claro** — nunca sai APK release assinado com as chaves
de debug desta máquina (lição 2.2 do piloto: keystore de debug é por máquina, e um
aparelho que instalou um build debug-signed precisa DESINSTALAR — perdendo dados locais —
para aceitar build de outra origem). Builds debug não são afetados.

Os keystores vivem **FORA do repositório** e as senhas nunca entram no repo nem numa
sessão cloud (regra permanente 1). O `key.properties` tem entradas **por flavor**:

```properties
# dev — keystore dedicado de sideload (T-55), gerado em 19/08/2026. Para
# recriar do zero (PowerShell — a pasta primeiro, o keytool não a cria):
#   New-Item -ItemType Directory -Force "$env:USERPROFILE\keystores"
#   keytool -genkey -v -keystore "$env:USERPROFILE\keystores\entrelares-flutter.jks" -keyalg RSA -keysize 2048 -validity 10000 -alias entrelares
dev.storeFile=C:/Users/irineu/keystores/entrelares-flutter.jks
dev.storePassword=...
dev.keyAlias=entrelares
dev.keyPassword=...

# prod — o keystore de UPLOAD do produto (entrelares-app/store/android.keystore, F-54).
# O pacote da Play (com.entrelares.app) só aceita essa assinatura de upload (achado do
# estágio 0) — nunca aponte prod.* para outro keystore.
prod.storeFile=C:/Users/irineu/source/repos/entrelares-app/store/android.keystore
prod.storePassword=...
prod.keyAlias=android
prod.keyPassword=...
```

As entradas são separadas por construção para o upload da Play nunca sair assinado com a
chave de sideload por engano. O keystore deste card (`dev.*`) é só para distribuição
direta/sideload; ele NÃO cria uma segunda identidade na Play.

## i18n (U-13/U-24 — lote 1)

Bilíngue por leitor (PT-BR / EN), portado do app web:

- **Catálogos gerados, nunca editados à mão:** `packages/entrelares_core/lib/src/localization/`
  (`k.dart` + `strings_pt_br.dart` + `strings_en.dart`, 961 chaves) são espelhos mecânicos
  dos `K.cs`/`StringsPtBr.cs`/`StringsEn.cs` do repo `entrelares-app`, regenerados por
  `python tool/port_catalogs.py <caminho-do-entrelares-app>`. Strings que só existem
  neste cliente vivem em `k_app.dart` (prefixo `app.`), à mão.
- **Resolução** (`LanguageResolver`): escolha local > `profiles.language` > locale do
  aparelho > PT-BR. Idioma fixo no boot; a troca (picker no login e no calendário)
  reconstrói a árvore da raiz — o análogo do `forceLoad` do web. Adoção cross-device e
  gravação de `language_detected` seguem as mesmas regras puras do web
  (`Localization.shouldAdopt` / `shouldRecordDetected`).
- **Display por idioma, wire congelado** (U-24): EN = `05 Aug 2026` + relógio 12h; PT =
  `dd/MM/yyyy` + 24h. Transporte continua ISO `yyyy-MM-dd` (`CareSchedule.isoDate`) e
  nunca passa pelos formatadores de display. Tabelas de nomes hardcoded (sem `intl`/ICU),
  espelhando a decisão anti-drift do `_shared/i18n.ts`.
- **Renderer de notificações** (`NotificationRenderer`): `type` + `params` viram a frase
  no idioma do leitor; linhas legadas/payloads desconhecidos caem para o texto armazenado.
  PT-BR é byte-idêntico ao que os triggers gravam (tabela de ~35 casos em
  `notification_renderer_test.dart`).
- **Gate cobrado no fechamento do lote 6:** `catalog_call_sites_test.dart` prova que toda
  chave declarada ou tem call site, ou está classificada (web-only · o app tem frase própria
  em `k_app` · dívida anotada). As listas falham nos DOIS sentidos — uma chave órfã nova
  quebra o teste, e uma entrada que ganhou call site também. **O lote 5 fez a lista de
  billing zerar**: as 82 chaves ganharam call site e a lista foi REMOVIDA, que era
  exatamente o que o gate existia para forçar.

## Casco e deep links (lote 1 — PR2)

- **Navegação:** `go_router` com `StatefulShellRoute` — os mesmos 4 destinos do NavMenu
  web (Calendário, Família, Avisos, Relatórios); cada lote trocou um placeholder pelo
  miolo real, e com Relatórios (lote 6) não sobrou nenhum. Guard estilo S-02 no `redirect`: tudo é
  protegido exceto `/login`, `/reset-password` e `/update-password`.
- **Deep links (App Links):** host `web.entrelares.app` (a origem do PWA — o apex é a
  landing), path `/update-password`, `autoVerify`. O `assetlinks.json` de produção já
  listava o prod (`com.entrelares.app`, F-54); o statement do dev
  (`com.entrelares.flutter`, certificado de sideload T-55) entra por PR pareado no
  `entrelares-app`. Build DEBUG nunca verifica (certificado por máquina) — QA de deep
  link usa o release dev.
- **Recovery:** "Esqueci minha senha" → `resetPasswordForEmail` com `redirectTo` para o
  deep link; o `supabase_flutter` consome os tokens do link e emite `passwordRecovery`,
  que roteia para a tela de nova senha (validação espelhada em `UpdatePasswordRules`).
  ⚠️ Config de ambiente: o projeto Supabase DEV precisa de
  `https://web.entrelares.app/update-password` no allowlist de redirect de auth.
- **S-01 throttling:** espelho `LoginThrottle` (≥3 falhas → falhas×5 s; ≥5 → 60 s),
  estado em prefs locais (o análogo do sessionStorage web) — sobrevive a restart.
- **S-04 inatividade:** espelho `InactivityPolicy` (30 min, poll de 30 s) — pointer-down
  em qualquer lugar reseta; o resume do lifecycle reavalia na hora (tempo em background
  conta, como a aba escondida no web). Expirou → signOut local + banner no login.

## Espelhos e Today at a Glance (lote 1 — PR3)

- **Card Today at a Glance:** port do `TodayCard.razor` no topo do calendário — responsável
  de hoje (efetivo `actual ?? scheduled`), badges 🔄/⏰, próxima troca (janela de 90 dias,
  primeiro dia com responsável efetivo diferente — mesmo scan do web), nudge de convite
  F-31 (admin sozinho na família) e "voltar para hoje" quando navegando outro mês. A
  projeção que no web vivia inline (sem teste) virou regra pura em `today_rules.dart`.
- **Espelho T-41 (settings):** seam `parseIntSetting`/`parseBoolSetting` (semântica .NET
  `TryParse`) + `PublicSettings` com os 10 acessores e fallbacks dos seeds; o fetch
  (`app_settings` público via RLS) está no data source — o primeiro consumidor é o clamp
  de horizonte (lote 2).
- **Espelho F-32 (entitlement):** `computeIsPremium` (premium OR comp F-58 OR trial
  estritamente futuro) + `describePlan` (countdown com piso de 1 dia), fail-closed por
  construção (`Family` null → free); consumo de UI chega com os gates (lotes 2/5).
- **UX feedback:** `showAppSnack` (sucesso/erro/info, um por vez, toque dispensa, duração
  espelhada `3 s + 35 ms/char > 40, teto 8 s`) — primeiro uso: "Salvo com sucesso" no save
  do sheet; banner âmbar de dia passado no sheet (`K.editorPastReadonly`). O gate "toast
  nunca com literal" (port do `NoToast_CarriesALiteralString`) entrou junto, como o
  registro do PR1 prometia.

## Relatórios, analytics e plataforma (lote 6)

- **Hub de Relatórios** com 3 abas (`ReportsScreen`): Resumo · Histórico · PDF. Melhoria
  nativa sobre o web, que navega entre três rotas — cada aba guarda o próprio filtro.
- **Resumo do Período:** cards por membro com Programado/Realizado/Previsto (U-20) e o
  split U-07 (`cedeu · recebeu`). A contagem é UMA função em core (`caregiverStats`),
  chamada também pelo documento F-33 — no web isso era um comentário pedindo que dois
  trechos não divergissem.
- **Histórico de Ajustes:** quatro abas sobre dois registros (`activity_logs` e os
  `account_logs` do S-10), diff campo-a-campo, "carregar mais" incremental e a entrada
  sintética de fim de trial (F-58 QA 2). **F-45** entra aqui: a alteração vinda de um
  workflow nomeia a origem e carrega as duas mensagens F-44; a busca é enriquecimento e
  nunca derruba a timeline.
- **Relatório em PDF (F-33) — o redesign:** o `print()` do navegador não existe, então o
  documento é montado no aparelho (`pdf`) e entregue pelo sistema (`printing`: share sheet
  ou impressão nativa). Gate F-32 com falha fechada e **upsell neutro** (T-38).
  **Roboto embarcado**: a Helvetica embutida do dart_pdf não tem Unicode e derruba os
  acentos.
- **Analytics T-37:** POST direto na Events API do Umami (`text/plain`, sem preflight),
  desligado enquanto não houver website id — o flavor **dev vem vazio de propósito**. O
  contrato no-PII é espelho puro (`sanitizeAnalyticsPath`): query e fragmento caem sempre,
  GUID e id numérico viram `:id`. Eventos portados: `signup_started`, `family_created`,
  `invitee_joined`, `invite_sent`, `wizard_completed`, `swap_requested`. Os
  `premium-gate-click` chegaram no lote 5, junto das CTAs que eles medem.
- **Alvo web:** habilitado (tensão 1 — Flutter Web substitui o PWA). `flutter build web`
  entra no `verify.yml` e o run imprime o peso gzip do first-load; a medição de aceite do
  canal (Android mediano/4G) é do owner.

## Premium e billing (lote 5)

- **A seção Premium na Família** roda a máquina de estados do `BillingService` da web
  (`computeBillingUi`): waitlist, oferta, ativa, em atraso, agendada (F-42) e premium sem
  assinatura. O cancelamento pede confirmação e a frase **promete o tempo já pago**; o
  caminho de volta F-42 só aparece para método faturável com cliente no gateway — cartão
  nunca, porque retomar débito automático exige um token que o fluxo hospedado não guarda e
  o servidor recusaria o clique.
- **Dois trilhos, decididos pelo BUILD.** O alvo web usa o rail Asaas (checkout T-39 e Pix
  avulso F-48, abertos no navegador, com `/premium/retorno` fazendo poll até o webhook virar
  o plano). O Android é o canal loja: a política de pagamentos da Play proíbe direcionar
  para compra externa, então ali a oferta é **Play Billing** ou a **nota neutra T-38** —
  nunca um link de checkout.
- **O preço do canal loja é o da Play**, formatado pela loja para o país do comprador. O
  `app_settings` (`billing.price_*`) rege só o rail web. Não existe aritmética de preço no
  trilho da loja de propósito.
- **A nota neutra é o padrão de FALHA, não só o estado desligado**: com
  `billing.store_enabled=false`, sem loja no aparelho, com a consulta de produtos estourando
  ou sem produto publicado, o ramo de loja cai nela. Oferta que a loja não honra é pior que
  oferta nenhuma.
- **O cliente não concede nada.** A compra é alegação: o token vai ao
  `billing-store-verify`, que pergunta à Play Developer API se ela é real e até quando paga.
  O acknowledge à Play só acontece **depois** que o servidor aceita — a Play estorna compra
  não reconhecida em três dias, e reconhecer uma que o servidor recusou deixaria a família
  paga e sem direito.
- **Histórico F-43** preguiçoso na primeira abertura e cacheado depois; some para quem não é
  admin (o RPC recusaria) e para família sem assinatura.
- **Funil T-37 completo** com a dimensão `channel` derivada do mesmo fato de build que
  escolhe o trilho — é ela que separa a coorte da loja da coorte web no Umami.
- **Falta configuração de console (do owner)** para o trilho da loja vender:
  `entrelares-app/supabase/README.md` §9-bis.

## Versionamento

| Componente | Versão atual |
|---|---|
| `apps/entrelares_app` | `0.2.28+30` (T-53 lote 5 PR4 — Play Billing no cliente) |

Trilha do estágio 3: `0.2.0+2` abertura de flavors → `0.2.1+3` T-55 → `0.2.2+4`…`0.2.4+6`
lote 1 → `0.2.5+7`…`0.2.8+10` lote 2 → `0.2.9+11`…`0.2.13+15` lote 3 →
`0.2.14+16`…`0.2.19+21` lote 4 → `0.2.20+22`…`0.2.24+26` lote 6 →
`0.2.25+27`…`0.2.28+30` lote 5. **Os seis lotes estão entregues** — o app está
funcionalmente completo e o próximo passo é o cutover do estágio 4.

Regra herdada do produto: bump em toda mudança funcional entregue ao owner.

## Decisões herdadas (não reabrir aqui)

- Flutter **3.44.7** via FVM; JDK **17**; `minSdk` **26**.
- `applicationId` por flavor (estágio 3): **dev = `com.entrelares.flutter`** — DIFERENTE
  do pacote da Play de propósito, para o APK dev coexistir com o app instalado da loja no
  aparelho do owner — e **prod = `com.entrelares.app`** (mesma assinatura de upload —
  validado no estágio 0; assinatura release por flavor entregue no T-55).
- O cliente ESPELHA, o banco IMPÕE — RLS, RPCs, sudo S-10 e revision/revision_token são a
  segurança; este app é só mais um caller.
- Paridade é piso, não teto: onde o Flutter der melhoria natural (Realtime no lugar do
  poll, swipe entre meses, bottom sheet nativo), a fatia usa — sem mudar regra de servidor.
