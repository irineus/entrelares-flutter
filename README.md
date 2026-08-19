# Entrelares — Flutter (T-53, aposta de plataforma)

Spike do **estágio 1** do T-53: a reescrita do [Entrelares](https://github.com/irineus/entrelares-app)
(hoje Blazor WASM PWA) em **Flutter/Dart**. Este repositório nasce como o laboratório da
fatia vertical — calendário mensal + sheet do dia contra o projeto **dev** real, com Realtime
nativo e leitura/escrita sob RLS — e, se a aposta vingar (veredito com números, estágio 1),
vira o repositório do app de produto.

**Reversível por construção:** se o veredito for "fica Blazor", este repositório morre sem
tocar em nada do app atual. Nada aqui é dependência de produção.

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
- **Gate adiado de propósito:** o teste "toda chave declarada tem call site" (lição U-23)
  só faz sentido com as telas todas portadas — entra no fechamento do lote 6.

## Casco e deep links (lote 1 — PR2)

- **Navegação:** `go_router` com `StatefulShellRoute` — os mesmos 4 destinos do NavMenu
  web (Calendário, Família, Avisos, Relatórios); telas não portadas mostram placeholder
  localizado e cada lote só troca o miolo. Guard estilo S-02 no `redirect`: tudo é
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

## Versionamento

| Componente | Versão atual |
|---|---|
| `apps/entrelares_app` | `0.2.4+6` (T-53 lote 1 PR3 — card Today at a Glance, espelhos T-41/F-32, SnackBar + banner âmbar) |

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
