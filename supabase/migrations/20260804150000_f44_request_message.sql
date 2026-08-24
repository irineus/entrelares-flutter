-- F-44: optional free text on the swap workflow — the requester's message,
-- written once at creation (swap AND revert), and the approver's note, written
-- only on approval (symmetric to the existing rejection_reason). Both mirror
-- rejection_reason's discipline: nullable plain text, 200-char limit enforced
-- by the UI (maxlength), no DB CHECK. The message lives on the REQUEST only —
-- it is never copied to care_schedules.notes, so a rejected/reverted request's
-- motive dies with the request and can't masquerade as a day observation.
ALTER TABLE public.swap_requests
  ADD COLUMN IF NOT EXISTS request_message text,
  ADD COLUMN IF NOT EXISTS approval_note text;

COMMENT ON COLUMN public.swap_requests.request_message IS
  'F-44: optional message from the requester, set once at creation (swap or revert request).';
COMMENT ON COLUMN public.swap_requests.approval_note IS
  'F-44: optional note from the approver, set only on approval (rejection uses rejection_reason).';
