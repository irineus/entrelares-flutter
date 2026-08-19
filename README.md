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
`com.entrelares.app` (o pacote da Play) contra produção. Builds release assinam por
flavor via `key.properties` (T-55 — ver "Assinatura (release)" abaixo). `fvm flutter
test` não tem flavor e cai em dev por construção.

**CI (T-54):** todo push/PR roda `.github/workflows/verify.yml` — analyze + `dart test`
no core e analyze + `flutter test` no app, com o Flutter lido do `.fvmrc`. O build de
APK fica FORA do gate (cota de 2000 min/mês da conta, compartilhada com os repos do
produto) — para gerar APK pela CI, use o `workflow_dispatch` com `build-apk`. O APK
da CI é **debug** (o runner não tem — e nunca terá — os keystores do T-55; release é
build local por construção).

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

## Versionamento

| Componente | Versão atual |
|---|---|
| `apps/entrelares_app` | `0.2.1+3` (T-55 — assinatura release por flavor via `key.properties`) |

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
