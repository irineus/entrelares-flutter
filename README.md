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
cd apps/entrelares_app && fvm flutter build apk --debug --split-per-abi
```

**CI (T-54):** todo push/PR roda `.github/workflows/verify.yml` — analyze + `dart test`
no core e analyze + `flutter test` no app, com o Flutter lido do `.fvmrc`. O build de
APK fica FORA do gate (cota de 2000 min/mês da conta, compartilhada com os repos do
produto) — para gerar APK pela CI, use o `workflow_dispatch` com `build-apk`.

## Versionamento

| Componente | Versão atual |
|---|---|
| `apps/entrelares_app` | `0.1.0+1` (spike — pré-produto) |

Regra herdada do produto: bump em toda mudança funcional entregue ao owner.

## Decisões herdadas (não reabrir aqui)

- Flutter **3.44.7** via FVM; JDK **17**; `minSdk` **26**.
- `applicationId` do spike: **`com.entrelares.flutter`** — deliberadamente DIFERENTE do
  pacote da Play (`com.entrelares.app`) para o APK do spike coexistir com o app instalado
  da loja no aparelho do owner. A troca para `com.entrelares.app` (mesma assinatura de
  upload — validado no estágio 0) acontece no estágio 3, nunca antes.
- O cliente ESPELHA, o banco IMPÕE — RLS, RPCs, sudo S-10 e revision/revision_token são a
  segurança; este app é só mais um caller.
- Paridade é piso, não teto: onde o Flutter der melhoria natural (Realtime no lugar do
  poll, swipe entre meses, bottom sheet nativo), a fatia usa — sem mudar regra de servidor.
