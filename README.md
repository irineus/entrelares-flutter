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
```

**Flavors (estágio 3):** todo build Android exige `--flavor dev` ou `--flavor prod` —
ambientes são variantes de build (o singleton do Supabase inicializa uma vez por
processo), nunca um switcher de runtime. `dev` = `com.entrelares.flutter` contra o
projeto dev ("Entrelares Dev" no launcher, título com `[Dev]`); `prod` =
`com.entrelares.app` (o pacote da Play) contra produção. Distribuir o flavor prod
está travado no keystore próprio (T-55). `fvm flutter test` não tem flavor e cai em
dev por construção.

**CI (T-54):** todo push/PR roda `.github/workflows/verify.yml` — analyze + `dart test`
no core e analyze + `flutter test` no app, com o Flutter lido do `.fvmrc`. O build de
APK fica FORA do gate (cota de 2000 min/mês da conta, compartilhada com os repos do
produto) — para gerar APK pela CI, use o `workflow_dispatch` com `build-apk`.

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

## Versionamento

| Componente | Versão atual |
|---|---|
| `apps/entrelares_app` | `0.2.2+4` (T-53 lote 1 — i18n U-13/U-24: catálogos, resolver, formatos e renderer) |

Regra herdada do produto: bump em toda mudança funcional entregue ao owner.

## Decisões herdadas (não reabrir aqui)

- Flutter **3.44.7** via FVM; JDK **17**; `minSdk` **26**.
- `applicationId` por flavor (estágio 3): **dev = `com.entrelares.flutter`** — DIFERENTE
  do pacote da Play de propósito, para o APK dev coexistir com o app instalado da loja no
  aparelho do owner — e **prod = `com.entrelares.app`** (mesma assinatura de upload —
  validado no estágio 0; distribuição travada no T-55).
- O cliente ESPELHA, o banco IMPÕE — RLS, RPCs, sudo S-10 e revision/revision_token são a
  segurança; este app é só mais um caller.
- Paridade é piso, não teto: onde o Flutter der melhoria natural (Realtime no lugar do
  poll, swipe entre meses, bottom sheet nativo), a fatia usa — sem mudar regra de servidor.
