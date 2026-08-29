-- =============================================================================
-- F-09 — correção: um aparelho que troca de conta consegue se registrar.
--
-- O DEFEITO, medido em produção em 29/08/2026. O app registra o token com
-- `upsert(..., onConflict: 'token')`, porque o UNIQUE está no token e a linha
-- que já o detém pode pertencer a OUTRO perfil — o mesmo aparelho, um segundo
-- login. Re-apontar a linha é exatamente o que deve acontecer. Só que o ramo
-- `ON CONFLICT DO UPDATE` é um UPDATE de verdade, e o `USING` da policy
-- `push_subscriptions_update_own` exige que a linha JÁ seja sua. Ela não é. O
-- Postgres recusa com
--
--     new row violates row-level security policy (USING expression)
--
-- e o app cai no aviso neutro do F-09 ("Não foi possível ativar os avisos
-- agora"). Oito recusas em dois minutos no log de produção, na conta mais
-- antiga do produto — que não tinha nada de especial além de ter sido a
-- SEGUNDA a pedir o token daquele aparelho. Na ordem inversa, a quebrada seria
-- a outra.
--
-- POR QUE O GATE NÃO PEGOU. `push_subscriptions.dart` tem o teste "the same
-- token cannot be registered twice", que exercita um INSERT puro e afirma a
-- recusa — correta, e por um caminho que o app nunca toma. A forma de chamada
-- que a produção envia (o upsert) nunca foi testada. É a mesma armadilha do
-- `translateSaveError`: o teste encoda um formato de entrada que o produto não
-- usa, fica verde e a produção nunca casa.
--
-- A CORREÇÃO, e por que ela mora AQUI e não no cliente. Um BEFORE INSERT que
-- apaga a linha que já detém aquele token. Sem conflito, o ramo UPDATE nunca é
-- consultado, e o INSERT segue pelo `WITH CHECK` da policy de inserção — que
-- continua exigindo que o `profile_id` seja o seu. Nada foi afrouxado: mover a
-- linha de outra pessoa por UPDATE continua recusado, ler o token dela continua
-- recusado, apagá-la diretamente continua recusado.
--
-- Trocar de conta num aparelho não é um caso raro deste produto: é o suporte de
-- uma família inteira num telefone só. E a regra que este trigger implementa já
-- estava ESCRITA no F-09, em dois comentários, sem nenhuma camada que a
-- executasse: "um aparelho pertence a uma conta por vez, e um token que migrou
-- para outro login não pode deixar a linha antiga para trás recebendo os avisos
-- do usuário anterior".
--
-- A CAPACIDADE que isto concede, dita em voz alta: quem APRESENTA um token
-- reivindica aquele aparelho. É a mesma capacidade que um RPC SECURITY DEFINER
-- daria, e estritamente menor que a de afrouxar a policy de UPDATE — um
-- `USING (true)` permitiria varrer a tabela inteira com um único UPDATE sem
-- WHERE. Aqui só se alcança a linha cujo token você já tem em mãos, e ter o
-- token é ser o aparelho. Perder o push é a consequência correta e desejada
-- para a conta anterior: ela não está mais nesse telefone.
--
-- Vale para TODO BUILD JÁ INSTALADO, que é a razão de a correção ser do banco.
-- O 2.3.0 está em aparelhos e não tem como chamar um RPC que não existia
-- quando foi compilado; este trigger conserta o upsert que ele já envia.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.claim_push_token()
RETURNS trigger
LANGUAGE plpgsql
-- SECURITY DEFINER porque o dono da linha que sai é outro perfil, e nenhuma
-- policy de DELETE deste produto permite (nem deve permitir) que um usuário
-- alcance a linha de outro. O dono da função é `postgres`, que não é submetido
-- às policies da tabela.
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
	-- Só a linha do MESMO token, e só quando ela é de outro perfil. Um
	-- re-registro do próprio aparelho (o caminho comum: o app reparando a
	-- inscrição a cada sessão) não apaga e reinsere nada — cai no
	-- `ON CONFLICT DO UPDATE`, que a policy autoriza porque a linha já é sua,
	-- e preserva o `id` e o `created_at`.
	DELETE FROM public.push_subscriptions
	WHERE token = NEW.token
	  AND profile_id IS DISTINCT FROM NEW.profile_id;

	RETURN NEW;
END;
$$;

ALTER FUNCTION public.claim_push_token() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.claim_push_token() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.claim_push_token() IS
	'F-09: quem apresenta um token de registro reivindica aquele aparelho. Apaga a linha do dono anterior antes do INSERT, para que o upsert do app não caia no ramo UPDATE — que a RLS recusa, corretamente, sobre a linha de outro perfil.';

DROP TRIGGER IF EXISTS push_subscriptions_claim_token ON public.push_subscriptions;
CREATE TRIGGER push_subscriptions_claim_token
	BEFORE INSERT ON public.push_subscriptions
	FOR EACH ROW
	EXECUTE FUNCTION public.claim_push_token();
