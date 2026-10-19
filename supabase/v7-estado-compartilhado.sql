-- Gincana do Saber 2026 — versão 7.0
-- Estado compartilhado entre operador, telão e tela do aluno, gravado no Supabase.
-- Não altera nada do que já existia (perguntas, operadores, sorteios e as funções *_treino).
-- Pode ser executado mais de uma vez.

-- ---------------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------------

-- Estado ao vivo de cada sala. Leitura pública (telão, aluno e torcida):
-- o gabarito só entra aqui depois que o operador revela a resposta.
create table if not exists public.gincana_estado (
  sala text primary key check (sala in ('treinamento', 'oficial')),
  state jsonb not null default '{}'::jsonb,
  timer jsonb not null default '{}'::jsonb,
  helper_picker jsonb not null default '{"open":false}'::jsonb,
  score_preview jsonb not null default '{"open":false}'::jsonb,
  resposta jsonb not null default '{}'::jsonb,
  rev bigint not null default 0,
  atualizado_em timestamptz not null default now()
);
alter table public.gincana_estado enable row level security;
drop policy if exists gincana_estado_leitura on public.gincana_estado;
create policy gincana_estado_leitura on public.gincana_estado
  for select to anon, authenticated using (true);
revoke all on public.gincana_estado from anon, authenticated;
grant select on public.gincana_estado to anon, authenticated;
insert into public.gincana_estado (sala) values ('treinamento'), ('oficial')
  on conflict (sala) do nothing;

-- Cópia de cada versão do placar salva pelo operador (recuperação e auditoria).
create table if not exists gincana_privado.estado_historico (
  id bigint generated always as identity primary key,
  sala text not null,
  state jsonb not null,
  operador_id uuid,
  salvo_em timestamptz not null default now()
);
alter table gincana_privado.estado_historico enable row level security;
create index if not exists estado_historico_sala_idx
  on gincana_privado.estado_historico (sala, salvo_em desc);

-- Registro permanente dos lançamentos (respostas, desfazer, zerar, restaurar).
create table if not exists gincana_privado.lancamentos (
  id bigint generated always as identity primary key,
  sala text not null,
  tipo text not null,
  etapa text,
  rodada int,
  escola text,
  auxiliadora text,
  pergunta_numero int,
  alternativa text,
  correta boolean,
  tempo_esgotado boolean,
  pontos numeric,
  dados jsonb not null default '{}'::jsonb,
  operador_id uuid,
  criado_em timestamptz not null default now()
);
alter table gincana_privado.lancamentos enable row level security;
create index if not exists lancamentos_sala_idx
  on gincana_privado.lancamentos (sala, criado_em);

-- Configurações (chave do link da tela do aluno por sala).
create table if not exists gincana_privado.config (
  nome text primary key,
  valor text not null,
  atualizado_em timestamptz not null default now()
);
alter table gincana_privado.config enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Realtime (telão e aluno recebem as mudanças na hora)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'gincana_estado'
  ) then
    alter publication supabase_realtime add table public.gincana_estado;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Funções
-- ---------------------------------------------------------------------------

create or replace function gincana_privado.eh_operador()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from gincana_privado.operadores op
     where op.usuario_id = auth.uid() and op.ativo = true
  );
$$;
revoke all on function gincana_privado.eh_operador() from public, anon, authenticated;

-- Hora do servidor em milissegundos: todos os aparelhos acertam o relógio por ela.
create or replace function public.gincana_agora()
returns bigint
language sql volatile
set search_path = ''
as $$ select (extract(epoch from clock_timestamp()) * 1000)::bigint; $$;
revoke all on function public.gincana_agora() from public, anon, authenticated;
grant execute on function public.gincana_agora() to anon, authenticated;

create or replace function public.gincana_sou_operador()
returns boolean
language sql stable security definer
set search_path = ''
as $$ select gincana_privado.eh_operador(); $$;
revoke all on function public.gincana_sou_operador() from public, anon, authenticated;
grant execute on function public.gincana_sou_operador() to authenticated;

-- Operador grava o estado da sala (somente as partes enviadas em p_patch).
create or replace function public.gincana_salvar_estado(p_sala text, p_patch jsonb)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_rev bigint;
  v_old jsonb;
begin
  if not gincana_privado.eh_operador() then
    raise exception 'Operador não autorizado.';
  end if;
  if p_sala is null or p_sala not in ('treinamento', 'oficial') then
    raise exception 'Sala inválida.';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Dados inválidos.';
  end if;
  if octet_length(p_patch::text) > 3000000 then
    raise exception 'Dados grandes demais.';
  end if;

  insert into public.gincana_estado (sala) values (p_sala) on conflict (sala) do nothing;
  select e.state into v_old from public.gincana_estado e where e.sala = p_sala for update;

  update public.gincana_estado e set
    state         = case when p_patch ? 'state'         then p_patch->'state'         else e.state end,
    timer         = case when p_patch ? 'timer'         then p_patch->'timer'         else e.timer end,
    helper_picker = case when p_patch ? 'helper_picker' then p_patch->'helper_picker' else e.helper_picker end,
    score_preview = case when p_patch ? 'score_preview' then p_patch->'score_preview' else e.score_preview end,
    -- Pergunta nova: descarta a resposta do aluno da pergunta anterior.
    resposta      = case when p_patch ? 'state'
                          and (p_patch->'state'->>'qid') is distinct from (e.resposta->>'qid')
                         then '{}'::jsonb else e.resposta end,
    rev = e.rev + 1,
    atualizado_em = now()
  where e.sala = p_sala
  returning e.rev into v_rev;

  if p_patch ? 'state' and (p_patch->'state') is distinct from v_old then
    insert into gincana_privado.estado_historico (sala, state, operador_id)
    values (p_sala, p_patch->'state', auth.uid());
  end if;

  return jsonb_build_object('rev', v_rev, 'agora', (extract(epoch from clock_timestamp()) * 1000)::bigint);
end;
$$;
revoke all on function public.gincana_salvar_estado(text, jsonb) from public, anon, authenticated;
grant execute on function public.gincana_salvar_estado(text, jsonb) to authenticated;

-- Tela do aluno (sem login): grava a alternativa escolhida enquanto o cronômetro corre.
-- O servidor confere a chave do link, a pergunta ativa e o prazo.
create or replace function public.gincana_responder(p_sala text, p_chave text, p_qid text, p_alternativa int)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v public.gincana_estado%rowtype;
  v_chave text;
  v_agora bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_prazo bigint;
begin
  if p_alternativa is null or p_alternativa not between 0 and 2 then
    raise exception 'Alternativa inválida.';
  end if;
  select c.valor into v_chave from gincana_privado.config c where c.nome = 'chave_aluno:' || p_sala;
  if v_chave is null or p_chave is distinct from v_chave then
    raise exception 'Link da tela do aluno inválido. Peça o link atualizado à organização.';
  end if;

  select * into v from public.gincana_estado e where e.sala = p_sala for update;
  if not found then
    raise exception 'Sala não encontrada.';
  end if;
  if p_qid is null or coalesce(v.state->>'qid', '') <> p_qid then
    raise exception 'Esta pergunta não está mais ativa.';
  end if;
  if coalesce((v.state->>'revealed')::boolean, false) or coalesce((v.state->>'recorded')::boolean, false) then
    raise exception 'A resposta já foi revelada.';
  end if;
  if not coalesce((v.timer->>'running')::boolean, false) then
    raise exception 'Aguarde o cronômetro.';
  end if;
  v_prazo := nullif(v.timer->>'deadline', '')::numeric::bigint;
  if v_prazo is null or v_agora > v_prazo + 300 then
    raise exception 'Tempo esgotado.';
  end if;

  update public.gincana_estado e set
    resposta = jsonb_build_object('qid', p_qid, 'selected', p_alternativa, 'at', v_agora),
    rev = e.rev + 1,
    atualizado_em = now()
  where e.sala = p_sala;

  return jsonb_build_object('ok', true, 'selected', p_alternativa, 'at', v_agora);
end;
$$;
revoke all on function public.gincana_responder(text, text, text, int) from public, anon, authenticated;
grant execute on function public.gincana_responder(text, text, text, int) to anon, authenticated;

-- Operador obtém (ou renova) a chave do link da tela do aluno.
create or replace function public.gincana_chave_aluno(p_sala text, p_renovar boolean default false)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nome text := 'chave_aluno:' || p_sala;
  v_valor text;
begin
  if not gincana_privado.eh_operador() then
    raise exception 'Operador não autorizado.';
  end if;
  if p_sala is null or p_sala not in ('treinamento', 'oficial') then
    raise exception 'Sala inválida.';
  end if;
  if p_renovar then
    delete from gincana_privado.config where nome = v_nome;
  end if;
  insert into gincana_privado.config (nome, valor)
  values (v_nome, substr(replace(gen_random_uuid()::text, '-', ''), 1, 16))
  on conflict (nome) do nothing;
  select c.valor into v_valor from gincana_privado.config c where c.nome = v_nome;
  return v_valor;
end;
$$;
revoke all on function public.gincana_chave_aluno(text, boolean) from public, anon, authenticated;
grant execute on function public.gincana_chave_aluno(text, boolean) to authenticated;

-- Sorteio sem repetir perguntas: exclui as já usadas no placar (p_excluir) e,
-- na sala oficial, também todas as já sorteadas oficialmente. Registra em sorteios.
create or replace function public.gincana_sortear(p_sala text, p_dificuldade text, p_etapa text, p_excluir int[] default '{}')
returns table (numero int, enunciado text, alternativa_a text, alternativa_b text, alternativa_c text, dificuldade text, repetida boolean)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_num int;
  v_ambiente text;
  v_repetida boolean := false;
begin
  if not gincana_privado.eh_operador() then
    raise exception 'Operador não autorizado.';
  end if;
  if p_sala is null or p_sala not in ('treinamento', 'oficial') then
    raise exception 'Sala inválida.';
  end if;
  if p_dificuldade is null or p_dificuldade not in ('facil', 'media', 'dificil') then
    raise exception 'Dificuldade inválida.';
  end if;
  if p_etapa is null or p_etapa not in ('A', 'B', 'F') then
    raise exception 'Etapa inválida.';
  end if;
  v_ambiente := case when p_sala = 'oficial' then 'oficial' else 'treinamento' end;

  select p.numero into v_num
    from gincana_privado.perguntas p
   where p.ativa = true and p.dificuldade = p_dificuldade
     and not (p.numero = any (coalesce(p_excluir, '{}')))
     and (v_ambiente <> 'oficial' or not exists (
           select 1 from gincana_privado.sorteios s
            where s.ambiente = 'oficial' and s.pergunta_numero = p.numero))
   order by random() limit 1;

  -- Banco esgotado: repete a pergunta menos sorteada, avisando o operador.
  if v_num is null then
    v_repetida := true;
    select p.numero into v_num
      from gincana_privado.perguntas p
      left join gincana_privado.sorteios s on s.pergunta_numero = p.numero and s.ambiente = v_ambiente
     where p.ativa = true and p.dificuldade = p_dificuldade
     group by p.numero
     order by count(s.id), random() limit 1;
  end if;
  if v_num is null then
    raise exception 'Nenhuma pergunta ativa para a dificuldade %.', p_dificuldade;
  end if;

  insert into gincana_privado.sorteios (pergunta_numero, ambiente, etapa, operador_id)
  values (v_num, v_ambiente, p_etapa, auth.uid());

  return query
    select p.numero, p.enunciado, p.alternativa_a, p.alternativa_b, p.alternativa_c, p.dificuldade, v_repetida
      from gincana_privado.perguntas p where p.numero = v_num;
end;
$$;
revoke all on function public.gincana_sortear(text, text, text, int[]) from public, anon, authenticated;
grant execute on function public.gincana_sortear(text, text, text, int[]) to authenticated;

-- Registro permanente de cada lançamento feito pelo operador.
create or replace function public.gincana_registrar_lancamento(p_sala text, p_tipo text, p_dados jsonb)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if not gincana_privado.eh_operador() then
    raise exception 'Operador não autorizado.';
  end if;
  if p_sala is null or p_sala not in ('treinamento', 'oficial') then
    raise exception 'Sala inválida.';
  end if;
  if p_tipo is null or p_tipo not in ('resposta', 'desfazer', 'zerar', 'restaurar') then
    raise exception 'Tipo de lançamento inválido.';
  end if;
  p_dados := coalesce(p_dados, '{}'::jsonb);
  insert into gincana_privado.lancamentos
    (sala, tipo, etapa, rodada, escola, auxiliadora, pergunta_numero, alternativa, correta, tempo_esgotado, pontos, dados, operador_id)
  values (
    p_sala, p_tipo,
    p_dados->>'phase',
    nullif(p_dados->>'round', '')::int,
    p_dados->>'school',
    nullif(p_dados->>'helper', ''),
    nullif(p_dados->>'numero', '')::int,
    p_dados->>'letra',
    (p_dados->>'correct')::boolean,
    (p_dados->>'timeout')::boolean,
    nullif(p_dados->>'part', '')::numeric,
    p_dados,
    auth.uid()
  )
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.gincana_registrar_lancamento(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.gincana_registrar_lancamento(text, text, jsonb) to authenticated;
