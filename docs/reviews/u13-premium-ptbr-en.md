# U-13 · PR 3a-Premium — revisão PT-BR × EN do texto de cobrança

**Para o dono revisar frase a frase antes do merge.** Esta tabela existe porque o teste de
paridade de chaves não substitui leitura humana: ele prova que a chave existe nos dois idiomas,
**nunca que as duas frases dizem a mesma coisa**. E a cobrança está viva em produção — uma
frase mal traduzida aqui não é bug cosmético, é declaração comercial falsa.

O que eu já verifiquei, para você não precisar refazer:

- **Cada frase foi conferida contra o COMPORTAMENTO**, não só contra o português. Onde a cópia
  diz "o tempo restante é somado", o webhook estende a partir do maior entre fim-do-período e
  data-do-pagamento; onde diz "não paga nada hoje", a reativação de fato não emite cobrança.
- **"2 meses grátis" é literalmente verdade**: conferido no `app_settings` do DEV —
  `billing.price_annual_cents` 5490 ÷ `billing.price_monthly_cents` 549 = **10 exatos**, ou
  seja, o anual custa dez mensalidades. Se algum dia os preços mudarem essa razão, a frase
  precisa mudar junto (nos dois idiomas).
- **Nenhum número diverge entre os idiomas** — há um teste varrendo o catálogo inteiro para
  isso (`NumbersInsideAText_AreTheSameInBothLanguages`).
- **A ênfase `<strong>` sobreviveu em todas as entradas** — também com teste.

Duas decisões que valem seu aval explícito estão marcadas com ⚠️ no fim.

---

## 1 · Estado do plano (selo e expiração)

| Chave | PT-BR | EN |
|---|---|---|
| `PremBadgeTrialOne/Many` | ✨ Avaliação Premium — {0} dia restante / {0} dias restantes | ✨ Premium trial — {0} day left / {0} days left |
| `PremBadgeTrialUntil` | (até {0}) | (until {0}) |
| `PremBadgeForever` | ✨ Premium permanente — sem expiração | ✨ Permanent Premium — never expires |
| `PremBadgeActive` | ✨ Premium ativo | ✨ Premium active |
| `PremBadgeFree` | Plano atual: Gratuito | Current plan: Free |
| `PremExpiredTrial` | Sua avaliação Premium terminou em **{0}**. | Your Premium trial ended on **{0}**. |
| `PremExpiredPaid` | Seu Premium expirou em **{0}**. | Your Premium expired on **{0}**. |

## 2 · Introdução e lista de recursos

| Chave | PT-BR | EN |
|---|---|---|
| `PremIntro` | O essencial é **gratuito**: calendário, trocas com aprovação e histórico. | The essentials are **free**: calendar, swaps with approval and history. |
| `PremIntroWaitlist` | O Premium vai reunir recursos avançados — ainda **sem data e sem preço** definidos. | Premium will bring together advanced features — still **with no date and no price** set. |
| `PremIntroOffer` | O Premium libera os recursos avançados abaixo — por família, quantos responsáveis forem. | Premium unlocks the advanced features below — per family, however many caregivers there are. |
| `PremFeatureCaregivers` | 👥 Mais de dois responsáveis na família | 👥 More than two caregivers in the family |
| `PremFeatureHorizon` | 🗓️ Planejar além de 6 meses à frente | 🗓️ Plan more than 6 months ahead |
| `PremFeaturePdf` | 📄 Relatório do histórico em PDF | 📄 History report as a PDF |
| `PremFeatureAdminMode` | 🛡️ Modo administrador para corrigir dias passados | 🛡️ Administrator mode to correct past days |
| `PremFeatureRoles` | 🏷️ Papéis personalizados e exportações avançadas | 🏷️ Custom roles and advanced exports |

## 3 · Assinatura ativa e cancelamento

| Chave | PT-BR | EN |
|---|---|---|
| `PremForeverNote` | 💙 Sua família tem **Premium permanente** — sem expiração e sem cobrança. Aproveite! | 💙 Your family has **permanent Premium** — it never expires and is never charged. Enjoy! |
| `PremActiveStatus` | ✅ **Assinatura ativa** — {0}, {1}. | ✅ **Subscription active** — {0}, {1}. |
| `PremActiveRenews` | Próxima renovação até **{0}**. | Next renewal by **{0}**. |
| `PremCancelWarningUntil` | Cancelar interrompe as próximas cobranças. O período já pago continua valendo — o Premium fica ativo **até {0}** — e **nenhum dado é apagado**; os recursos Premium apenas voltam a ficar bloqueados ao final do período. Confirmar? | Cancelling stops the next charges. The period you already paid for stays valid — Premium stays active **until {0}** — and **no data is deleted**; the Premium features simply become locked again at the end of the period. Confirm? |
| `PremCancelWarning` | *(idem, sem o trecho da data)* | *(same, without the date clause)* |
| `PremCancelConfirm` | Confirmar cancelamento | Confirm cancellation |
| `PremCancelKeep` | Manter assinatura | Keep the subscription |
| `PremCancelButton` | Cancelar assinatura | Cancel the subscription |

## 4 · Pagamento pendente (carência)

| Chave | PT-BR | EN |
|---|---|---|
| `PremOverdueGraceEnded` | ⚠️ **Pagamento pendente** — o período de carência terminou em **{0}** e o acesso Premium foi encerrado. Regularize o pagamento (e-mail de cobrança, remetente Asaas) para reativar a assinatura — **nenhum dado foi apagado**. | ⚠️ **Payment pending** — the grace period ended on **{0}** and Premium access was ended. Settle the payment (billing e-mail, sender Asaas) to reactivate the subscription — **no data was deleted**. |
| `PremOverdueInGrace` | ⚠️ **Pagamento pendente** — a última renovação não foi confirmada. Verifique o e-mail de cobrança (remetente Asaas) para regularizar; os recursos Premium ficam disponíveis até **{0}** (período de carência). | ⚠️ **Payment pending** — the last renewal was not confirmed. Check the billing e-mail (sender Asaas) to settle it; the Premium features stay available until **{0}** (grace period). |
| `PremOverdueInGraceNoDate` | *(idem, "durante o período de carência")* | *(same, "during the grace period")* |

## 5 · Reativação agendada

| Chave | PT-BR | EN |
|---|---|---|
| `PremScheduledStatus` | 🗓️ **Reativação agendada** — nada foi cobrado agora. | 🗓️ **Reactivation scheduled** — nothing was charged now. |
| `PremScheduledDetailMethod` | Seu Premium segue ativo até **{0}**, e a primeira cobrança de {1} ({2}), por {3}, chega nessa data. | Your Premium stays active until **{0}**, and the first charge of {1} ({2}), by {3}, arrives on that date. |
| `PremScheduledDetail` | *(idem, sem o meio de pagamento)* | *(same, without the payment method)* |
| `PremScheduledCancelWarning` | Cancelar desfaz o agendamento — a cobrança não será emitida e **nenhum dado é apagado**. O período já pago continua valendo normalmente. Confirmar? | Cancelling undoes the scheduling — the charge will not be issued and **no data is deleted**. The period you already paid for stays valid as normal. Confirm? |
| `PremScheduledCancelKeep` | Manter agendamento | Keep the scheduling |
| `PremScheduledCancelButton` | Cancelar agendamento | Cancel the scheduling |

## 6 · Período já pago e renovação aditiva

> Este é o bloco mais sensível: ele promete que **nada se perde** ao renovar antes do fim.

| Chave | PT-BR | EN |
|---|---|---|
| `PremPaidUntilAvulso` | ✅ Sua família tem **Premium ativo até {0}** (Pix avulso — **sem renovação automática**). Para continuar depois disso, faça um novo Pix avulso ou assine: **o tempo restante é somado**, nada se perde. | ✅ Your family has **Premium active until {0}** (one-off Pix — **no automatic renewal**). To carry on after that, make a new one-off Pix or subscribe: **the remaining time is added on**, nothing is lost. |
| `PremPaidUntilPeriod` | ✅ Sua família ainda tem **Premium ativo até {0}** (período já pago). Ao assinar novamente, **você paga agora** e o novo período **começa a contar do fim do atual** — o tempo restante é somado, nada se perde. As próximas cobranças seguem a nova data. | ✅ Your family still has **Premium active until {0}** (period already paid for). If you subscribe again, **you pay now** and the new period **starts counting from the end of the current one** — the remaining time is added on, nothing is lost. The next charges follow the new date. |
| `PremTrialAdditive` | ✨ Sua família está na **avaliação Premium até {0}**. Ao assinar, **você paga agora** e o período pago **começa a contar do fim da avaliação** — os dias restantes são somados, nada se perde. | ✨ Your family is on the **Premium trial until {0}**. If you subscribe, **you pay now** and the paid period **starts counting from the end of the trial** — the remaining days are added on, nothing is lost. |
| `PremExpiringSoonOne/Many` | ⏳ Seu acesso Premium termina em **{0} dia / {0} dias** — renove abaixo para não perder os recursos (nenhum dado é apagado). | ⏳ Your Premium access ends in **{0} day / {0} days** — renew below so you do not lose the features (no data is deleted). |

## 7 · Reativar sem cobrança hoje

| Chave | PT-BR | EN |
|---|---|---|
| `PremReactivateButton` | Reativar assinatura — sem cobrança agora | Reactivate the subscription — no charge now |
| `PremReactivateHintMethodDate` | Você **não paga nada hoje**: a primeira cobrança de {0} ({1}), por {2}, só é emitida em **{3}**, quando o período já pago terminar. Pode cancelar antes disso sem custo. | You **pay nothing today**: the first charge of {0} ({1}), by {2}, is only issued on **{3}**, when the period you already paid for ends. You can cancel before then at no cost. |
| *(+3 variantes)* | sem meio de pagamento, sem data, ou nenhum dos dois | same, dropping the method and/or the date |

## 8 · Oferta, Pix avulso e garantia

| Chave | PT-BR | EN |
|---|---|---|
| `PremSubscribeMonthly` | Assinar mensal — {0}/mês | Subscribe monthly — {0}/month |
| `PremSubscribeAnnual` | Assinar anual — {0}/ano · 2 meses grátis | Subscribe annually — {0}/year · 2 months free |
| `PremAvulsoLead` | Prefere **não assinar nada**? Pague um período avulso por Pix — **sem renovação automática**: quando terminar, você escolhe se paga de novo. | Prefer **not to subscribe to anything**? Pay for a single period by Pix — **no automatic renewal**: when it ends, you choose whether to pay again. |
| `PremAvulsoMonthly` | Pix avulso — 1 mês por {0} | One-off Pix — 1 month for {0} |
| `PremAvulsoAnnual` | Pix avulso — 12 meses por {0} | One-off Pix — 12 months for {0} |
| `PremPaymentHint` | Pague por **Pix** — QR code pelo aplicativo do seu banco, sem informar dados de cartão — ou por cartão de crédito, sempre no ambiente seguro do provedor de pagamento (Asaas). Uma assinatura por família — cancele quando quiser, sem perder nenhum dado. | Pay by **Pix** — a QR code in your bank's app, with no card details to type — or by credit card, always inside the payment provider's secure environment (Asaas). One subscription per family — cancel whenever you like, without losing any data. |
| `PremGuarantee` | 🛡️ **Garantia de 7 dias**: se você se arrepender em até 7 dias após o pagamento, devolvemos **o valor integral** (art. 49 do CDC). É só escrever para | 🛡️ **7-day guarantee**: if you change your mind within 7 days of the payment, we refund **the full amount** (art. 49 of the Brazilian Consumer Code). Just write to |
| `PremAdminOnly` | 💡 A assinatura é feita por um **administrador** da família. | 💡 The subscription is taken out by a family **administrator**. |

> **Nota sobre a garantia**: o inglês mantém a base legal e a explicita ("Brazilian Consumer
> Code"), em vez de "art. 49 do CDC" — uma sigla que um leitor estrangeiro não decodifica.
> Manter a referência importa: sem ela a frase vira gesto de boa vontade em vez de direito.

## 9 · Loja (shell da Google Play)

> Aqui o texto é restrito pela política de pagamentos do Play: sem preço, sem link de checkout,
> sem verbo que direcione para compra externa. **O inglês é espelho do PT-BR aprovado, nunca
> mais convidativo.**

| Chave | PT-BR | EN |
|---|---|---|
| `PremStorePaidUntilAvulso` | ✅ Sua família tem **Premium ativo até {0}** (Pix avulso — sem renovação automática). | ✅ Your family has **Premium active until {0}** (one-off Pix — no automatic renewal). |
| `PremStorePaidUntilPeriod` | ✅ Sua família tem **Premium ativo até {0}** (período já pago). | ✅ Your family has **Premium active until {0}** (period already paid for). |
| `PremStoreTrialUntil` | ✨ Sua família está na **avaliação Premium até {0}**. | ✨ Your family is on the **Premium trial until {0}**. |
| `PremStoreNote` | A contratação e a gestão da assinatura Premium são feitas pelo **site do Guarda Compartilhada**, em um navegador — não estão disponíveis neste aplicativo. | Subscribing to and managing Premium are done on the **Guarda Compartilhada website**, in a browser — they are not available in this app. |

## 10 · Lista de interesse e histórico de pagamentos

| Chave | PT-BR | EN |
|---|---|---|
| `PremInterestDone` | ✅ Interesse registrado! Avisaremos você quando o Premium chegar. | ✅ Interest registered! We will let you know when Premium arrives. |
| `PremInterestKeepTrial` | Tenho interesse em manter o Premium | I am interested in keeping Premium |
| `PremInterestWant` | Quero recursos premium | I want premium features |
| `PremInterestHint` | Sem compromisso — é só para sabermos que você tem interesse. | No commitment — it is just so we know you are interested. |
| `PremHistoryToggle` | Histórico de pagamentos | Payment history |
| `PremHistoryEmpty` | Nenhum evento de cobrança ainda. | No billing events yet. |
| `PremHistoryReceipt` | recibo | receipt |
| `PremHistoryPayment` | Pagamento confirmado | Payment confirmed |
| `PremHistoryRefund` | Estorno | Refund |
| `PremHistoryOverdue` | Cobrança vencida | Charge overdue |
| `PremHistoryCanceled` | Assinatura cancelada | Subscription cancelled |
| `PremHistoryDowngraded` | Fim do acesso Premium (retorno ao Gratuito) | End of Premium access (back to Free) |
| `PremHistoryOther` | Evento de cobrança | Billing event |

## 11 · Ciclo e meio de pagamento (reusados acima)

| Chave | PT-BR | EN |
|---|---|---|
| `PremCycleMonthly` / `PremCycleAnnual` | plano mensal / plano anual | monthly plan / annual plan |
| `PremMethodPix` / `PremMethodCard` / `PremMethodBoleto` | Pix / Cartão / Boleto | Pix / Card / Boleto |

---

## 12 · `PremiumReturn` — revisão do que já foi entregue na `1.7.21`

Esta tela já estava traduzida; o registro a colocou na lista de revisão por afirmar a garantia
de 7 dias. **Reli as dez entradas e não encontrei divergência de sentido.**

| Chave | PT-BR | EN |
|---|---|---|
| `PayActiveTitle` | Premium ativo! | Premium is active! |
| `PayActiveBody` | Pagamento confirmado — os recursos Premium já estão liberados para toda a família. Obrigado por apoiar o Guarda Compartilhada! | Payment confirmed — the Premium features are already unlocked for the whole family. Thank you for supporting Guarda Compartilhada! |
| `PayGuarantee` | 🛡️ Lembrete: você tem 7 dias de garantia — arrependeu, devolvemos o valor integral. É só escrever para | 🛡️ A reminder: you have a 7-day guarantee — if you change your mind, we refund the full amount. Just write to |
| `PayAlmostTitle` | Quase lá… | Almost there… |
| `PayAlmostBody` | Ainda estamos aguardando a confirmação do pagamento. Pagamentos por Pix costumam confirmar em instantes; se você fechou a página do pagamento sem concluir, é só assinar novamente na página da família. | We are still waiting for the payment to be confirmed. Pix payments usually confirm within moments; if you closed the payment page without finishing, just subscribe again from the family page. |
| `PayAlmostHint` | Assim que o pagamento for confirmado, o Premium é liberado automaticamente — não é preciso fazer mais nada. | As soon as the payment is confirmed, Premium is unlocked automatically — there is nothing else to do. |
| `PayConfirmingTitle` | Confirmando o pagamento… | Confirming the payment… |
| `PayConfirmingBody` | Aguarde um instante — estamos confirmando com o provedor de pagamento. | One moment — we are confirming with the payment provider. |
| `PayBackToFamily` | Voltar para a família | Back to the family |

**Uma observação, não uma correção**: o `PayGuarantee` (as duas versões, igualmente) não cita
o art. 49 do CDC, enquanto o `PremGuarantee` do `FamilyPage` cita. Os dois idiomas estão
coerentes entre si, então **não é problema de tradução** — é uma inconsistência de redação
PT-BR que vem do F-48. Não mexi porque alterar cópia comercial em português está fora do
escopo de um PR de i18n; se você quiser alinhar, é uma linha nos dois catálogos.

---

## ⚠️ Duas decisões que quero seu aval explícito

**1 · "Pix" não foi traduzido.** É nome próprio de um arranjo de pagamento brasileiro e é como
o aplicativo do banco o chama — traduzir para "instant transfer" tornaria a instrução menos
acionável, não mais. "avulso" virou "one-off". *Alternativa, se preferir:* "Pix (Brazilian
instant payment)" na primeira ocorrência.

**2 · O preço continua em formato brasileiro nos dois idiomas** — `R$ 5,49`, não `R$ 5.49`.
A cobrança acontece em reais, e trocar o separador decimal num **preço** é exatamente como
alguém lê errado quanto vai pagar. Isso também é coerente com o U-24, que separou formatação
numérica por idioma como item próprio, justamente por tocar todo o app. Há um teste fixando
isso (`PriceFormat_IsBrazilian_RegardlessOfUiLanguage`), então mudar de ideia depois é uma
alteração deliberada, não um deslize. *Alternativa, se preferir:* `BRL 5.49` em inglês.
