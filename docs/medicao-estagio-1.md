# Medição do estágio 1 — roteiro do aparelho físico

O veredito do T-53 pede números de **Android mediano real**. O número do emulador
(registrado no PR 3) é só piso de sanidade — o que decide é o que você medir aqui.

## Instalação

O APK de sideload é o **arm64** (`app-arm64-v8a-release.apk`, ~20 MB), assinado com a
keystore de debug DESTA máquina — coexiste com o app da Play (`com.entrelares.app`), mas um
build de outra máquina exigirá desinstalar antes (lição 2.2 do piloto).

```powershell
adb install .\app-arm64-v8a-release.apk
```

(ou copie o APK para o aparelho e instale pelo gerenciador de arquivos.)

## 1 · Cold start (o número do critério (a))

Feche o app (recentes → deslizar). Depois:

```powershell
adb shell am force-stop com.entrelares.flutter
adb shell am start -W com.entrelares.flutter/com.entrelares.entrelares_app.MainActivity
```

Anote o **TotalTime** (ms). Repita 3× e use a mediana. O comparável no PWA: abrir o
app da Play (`com.entrelares.app`) do zero até o calendário interativo — cronômetro na
mão, mesmo aparelho, mesma rede.

## 2 · Primeira interação

Do toque no ícone até conseguir **tocar num dia e o sheet abrir**. Cronômetro, 3×,
mediana — nos dois apps.

## 3 · Realtime (o que o PWA não tem)

1. Aparelho com o app Flutter aberto no mês atual, logado na família de teste (dev).
2. No PC, abra o QA web (`qa.entrelares.app`) com OUTRO membro da família e mude o
   responsável de um dia futuro.
3. Meça o tempo até o aparelho refletir a mudança **sem tocar em nada**. O poll do PWA
   (F-23) leva até o intervalo do poll; o esperado aqui é ~1–3 s.

## 4 · O caminho de escrita e o conflito (T-33/T-35)

1. No aparelho, abra um dia futuro já atribuído. NÃO salve ainda.
2. No QA web, mude o MESMO dia para outro responsável e salve.
3. Agora salve no aparelho: deve aparecer **"Outro responsável salvou este dia
   primeiro"** — nunca um erro cru nem um salvamento silencioso por cima.
4. Feche o sheet, puxe para atualizar, salve de novo: deve funcionar.

## 5 · Sessão (lições 1.1/1.3)

1. Deixe o app fechado por 24h+ (ou revogue a sessão no dashboard do Supabase dev).
2. Abra: deve cair no login com "Sua sessão anterior expirou" — nunca abrir "logado"
   com todas as chamadas falhando.
3. Botão Sair sempre navega para o login, mesmo sem rede.

## Onde registrar

Os números entram na tabela do veredito em `entrelares-app/docs/flutter-migracao.md`
(seção "Veredito do estágio 1") e no card T-53 do board.
