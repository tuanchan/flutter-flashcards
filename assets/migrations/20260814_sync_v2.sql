-- Sync v2 contract shared by Flutter and the Windows C# client.
-- This migration is idempotent and can be executed repeatedly in Supabase.

create extension if not exists pgcrypto;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'topics', 'courses', 'cards', 'card_examples', 'review_states'
  ] loop
    execute format(
      'alter table public.%I add column if not exists revision bigint not null default 1',
      table_name
    );
    execute format(
      'alter table public.%I add column if not exists last_device_id text',
      table_name
    );
    execute format(
      'alter table public.%I add column if not exists last_mutation_id uuid',
      table_name
    );
    execute format(
      'alter table public.%I add column if not exists deleted_at timestamptz',
      table_name
    );
  end loop;
end;
$$;

-- A receipt makes retries of the same mutation idempotent even if the client
-- lost the HTTP response after PostgreSQL committed the first request.
create table if not exists public.sync_mutation_receipts (
  owner_id uuid not null references auth.users(id) on delete cascade,
  mutation_id uuid not null,
  device_id text not null,
  table_name text not null,
  entity_id uuid,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (owner_id, mutation_id)
);

alter table public.sync_mutation_receipts enable row level security;
drop policy if exists own_rows on public.sync_mutation_receipts;
create policy own_rows on public.sync_mutation_receipts
for all to authenticated
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

create or replace function public.sync_v2_stamp_row()
returns trigger
language plpgsql
as $$
begin
  -- Do not advance a revision for a no-op UPDATE. updated_at and revision are
  -- server-owned and are excluded from the comparison.
  if (to_jsonb(new) - 'updated_at' - 'revision')
       is not distinct from
     (to_jsonb(old) - 'updated_at' - 'revision') then
    new.updated_at := old.updated_at;
    new.revision := old.revision;
    return new;
  end if;

  new.revision := old.revision + 1;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'topics', 'courses', 'cards', 'card_examples', 'review_states'
  ] loop
    execute format('drop trigger if exists set_updated_at on public.%I', table_name);
    execute format('drop trigger if exists sync_v2_stamp_row on public.%I', table_name);
    execute format(
      'create trigger sync_v2_stamp_row before update on public.%I '
      'for each row execute function public.sync_v2_stamp_row()',
      table_name
    );
  end loop;
end;
$$;

/* Superseded draft retained only as migration design history.
create or replace function public.apply_sync_v2_mutation(
  p_table text,
  p_entity_id uuid,
  p_operation text,
  p_payload jsonb,
  p_mutation_id uuid,
  p_device_id text,
  p_base_revision bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid := auth.uid();
  v_id uuid := coalesce(p_entity_id, gen_random_uuid());
  v_current_revision bigint;
  v_row jsonb;
  v_receipt jsonb;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_deleted_at timestamptz;
begin
  if v_owner is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  if p_table not in ('topics', 'courses', 'cards', 'card_examples', 'review_states') then
    raise exception using errcode = '22023', message = 'unsupported sync table';
  end if;
  if p_operation not in ('upsert', 'delete') then
    raise exception using errcode = '22023', message = 'unsupported sync operation';
  end if;
  if p_mutation_id is null or coalesce(trim(p_device_id), '') = '' then
    raise exception using errcode = '22023', message = 'mutation_id and device_id are required';
  end if;

  select response into v_receipt
  from public.sync_mutation_receipts
  where owner_id = v_owner and mutation_id = p_mutation_id;
  if found then
    return v_receipt;
  end if;

  execute format(
    'select revision from public.%I where owner_id = $1 and id = $2 for update',
    p_table
  ) into v_current_revision using v_owner, v_id;

  if v_current_revision is null then
    if coalesce(p_base_revision, 0) <> 0 then
      raise exception using
        errcode = '40001',
        message = format('sync conflict: %s/%s no longer exists (base revision %s)', p_table, v_id, p_base_revision);
    end if;
    if p_operation = 'delete' then
      v_receipt := jsonb_build_object(
        'table', p_table, 'id', v_id, 'deleted', true,
        'revision', 0, 'updated_at', clock_timestamp(),
        'last_device_id', p_device_id, 'last_mutation_id', p_mutation_id
      );
    else
      v_payload := v_payload
        - 'owner_id' - 'revision' - 'updated_at'
        - 'last_device_id' - 'last_mutation_id';
      execute format(
        'insert into public.%I '
        'select * from jsonb_populate_record(null::public.%I, $1 || jsonb_build_object('
        '''id'', $2, ''owner_id'', $3, ''revision'', 1, ''updated_at'', clock_timestamp(), '
        '''last_device_id'', $4, ''last_mutation_id'', $5)) returning to_jsonb(%I.*)',
        p_table, p_table, p_table
      ) into v_row using v_payload, v_id, v_owner, p_device_id, p_mutation_id;
      v_receipt := jsonb_build_object('table', p_table, 'row', v_row);
    end if;
  else
    if coalesce(p_base_revision, 0) <> v_current_revision then
      raise exception using
        errcode = '40001',
        message = format(
          'sync conflict: %s/%s base revision %s, current revision %s',
          p_table, v_id, p_base_revision, v_current_revision
        );
    end if;

    if p_operation = 'delete' then
      v_deleted_at := coalesce(
        nullif(v_payload ->> 'deleted_at', '')::timestamptz,
        clock_timestamp()
      );
      execute format(
        'update public.%I set deleted_at = $1, last_device_id = $2, '
        'last_mutation_id = $3 where owner_id = $4 and id = $5 returning to_jsonb(%I.*)',
        p_table, p_table
      ) into v_row using v_deleted_at, p_device_id, p_mutation_id, v_owner, v_id;

      -- Course deletion is one server transaction. Descendants receive their
      -- own tombstone instead of being inferred from a client snapshot.
      if p_table = 'courses' then
        update public.cards
        set deleted_at = v_deleted_at,
            last_device_id = p_device_id,
            last_mutation_id = p_mutation_id
        where owner_id = v_owner and course_id = v_id and deleted_at is null;

        update public.card_examples e
        set deleted_at = v_deleted_at,
            last_device_id = p_device_id,
            last_mutation_id = p_mutation_id
        from public.cards c
        where e.owner_id = v_owner and c.owner_id = v_owner
          and e.card_id = c.id and c.course_id = v_id and e.deleted_at is null;

        update public.review_states r
        set deleted_at = v_deleted_at,
            last_device_id = p_device_id,
            last_mutation_id = p_mutation_id
        from public.cards c
        where r.owner_id = v_owner and c.owner_id = v_owner
          and r.card_id = c.id and c.course_id = v_id and r.deleted_at is null;
      elsif p_table = 'cards' then
        update public.card_examples
        set deleted_at = v_deleted_at,
            last_device_id = p_device_id,
            last_mutation_id = p_mutation_id
        where owner_id = v_owner and card_id = v_id and deleted_at is null;
        update public.review_states
        set deleted_at = v_deleted_at,
            last_device_id = p_device_id,
            last_mutation_id = p_mutation_id
        where owner_id = v_owner and card_id = v_id and deleted_at is null;
      end if;
      v_receipt := jsonb_build_object('table', p_table, 'row', v_row);
    else
      v_payload := v_payload
        - 'id' - 'owner_id' - 'revision' - 'updated_at'
        - 'last_device_id' - 'last_mutation_id';
      execute format(
        'update public.%I t set '
        '(name, created_at, deleted_at) = '
        '(coalesce(($1->>''name''), t.name), coalesce(($1->>''created_at'')::timestamptz, t.created_at), '
        'case when $1 ? ''deleted_at'' then ($1->>''deleted_at'')::timestamptz else t.deleted_at end), '
        'last_device_id = $2, last_mutation_id = $3 '
        'where t.owner_id = $4 and t.id = $5 returning to_jsonb(t.*)',
        p_table
      ) into v_row using v_payload, p_device_id, p_mutation_id, v_owner, v_id;

      -- The generic UPDATE above only fits topics. Each other table uses a
      -- typed jsonb_populate_record update so absent keys keep current values.
      if p_table <> 'topics' then
        execute format(
          'update public.%I t set '
          '(owner_id, revision, updated_at, last_device_id, last_mutation_id) = '
          '(t.owner_id, t.revision, t.updated_at, $2, $3), '
          '(select (x).* from jsonb_populate_record(t, $1) x) = '
          '(select (x).* from jsonb_populate_record(t, $1) x) '
          'where t.owner_id = $4 and t.id = $5 returning to_jsonb(t.*)',
          p_table
        ) into v_row using v_payload, p_device_id, p_mutation_id, v_owner, v_id;
      end if;
      v_receipt := jsonb_build_object('table', p_table, 'row', v_row);
    end if;
  end if;

  insert into public.sync_mutation_receipts(
    owner_id, mutation_id, device_id, table_name, entity_id, response
  ) values (
    v_owner, p_mutation_id, p_device_id, p_table, v_id, v_receipt
  );
  return v_receipt;
end;
$$;

*/
-- Per-table typed updates are required because PostgreSQL cannot assign an
-- arbitrary composite record to a row with one generic SET expression.
-- Replace the first implementation with per-table typed updates. PostgreSQL
-- cannot assign an arbitrary composite record to a row with one generic SET.
create or replace function public.apply_sync_v2_mutation(
  p_table text,
  p_entity_id uuid,
  p_operation text,
  p_payload jsonb,
  p_mutation_id uuid,
  p_device_id text,
  p_base_revision bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid := auth.uid();
  v_id uuid := coalesce(p_entity_id, gen_random_uuid());
  v_current_revision bigint;
  v_row jsonb;
  v_receipt jsonb;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_deleted_at timestamptz;
begin
  if v_owner is null then raise exception using errcode='28000', message='authentication required'; end if;
  if p_table not in ('topics','courses','cards','card_examples','review_states') then
    raise exception using errcode='22023', message='unsupported sync table';
  end if;
  if p_operation not in ('upsert','delete') then
    raise exception using errcode='22023', message='unsupported sync operation';
  end if;
  if p_mutation_id is null or coalesce(trim(p_device_id),'') = '' then
    raise exception using errcode='22023', message='mutation_id and device_id are required';
  end if;

  select response into v_receipt from public.sync_mutation_receipts
  where owner_id=v_owner and mutation_id=p_mutation_id;
  if found then return v_receipt; end if;

  if p_table='review_states' and nullif(v_payload->>'card_id','') is not null then
    select id,revision into v_id,v_current_revision
    from public.review_states
    where owner_id=v_owner and card_id=(v_payload->>'card_id')::uuid
    for update;
    if not found then
      v_id := coalesce(p_entity_id,gen_random_uuid());
      v_current_revision := null;
    end if;
  else
    execute format('select revision from public.%I where owner_id=$1 and id=$2 for update', p_table)
      into v_current_revision using v_owner, v_id;
  end if;

  if v_current_revision is null then
    if coalesce(p_base_revision,0) <> 0 then
      raise exception using errcode='40001', message=format('sync conflict: %s/%s is missing',p_table,v_id);
    end if;
    if p_operation='delete' then
      v_receipt := jsonb_build_object('table',p_table,'id',v_id,'deleted',true,'revision',0,
        'updated_at',clock_timestamp(),'last_device_id',p_device_id,'last_mutation_id',p_mutation_id);
    else
      v_payload := v_payload - 'owner_id' - 'revision' - 'updated_at' - 'last_device_id' - 'last_mutation_id';
      execute format(
        'insert into public.%I select * from jsonb_populate_record(null::public.%I, '
        '$1 || jsonb_build_object(''id'',$2,''owner_id'',$3,''revision'',1,''updated_at'',clock_timestamp(),'
        '''last_device_id'',$4,''last_mutation_id'',$5)) returning to_jsonb(%I.*)',
        p_table,p_table,p_table)
        into v_row using v_payload,v_id,v_owner,p_device_id,p_mutation_id;
      v_receipt := jsonb_build_object('table',p_table,'row',v_row);
    end if;
  else
    if coalesce(p_base_revision,0) <> v_current_revision then
      raise exception using errcode='40001', message=format(
        'sync conflict: %s/%s base revision %s, current revision %s',
        p_table,v_id,p_base_revision,v_current_revision);
    end if;
    if p_operation='delete' then
      v_deleted_at := coalesce(nullif(v_payload->>'deleted_at','')::timestamptz,clock_timestamp());
      execute format('update public.%I set deleted_at=$1,last_device_id=$2,last_mutation_id=$3 '
        'where owner_id=$4 and id=$5 returning to_jsonb(%I.*)',p_table,p_table)
        into v_row using v_deleted_at,p_device_id,p_mutation_id,v_owner,v_id;
      if p_table='courses' then
        update public.cards set deleted_at=v_deleted_at,last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and course_id=v_id and deleted_at is null;
        update public.card_examples e set deleted_at=v_deleted_at,last_device_id=p_device_id,last_mutation_id=p_mutation_id
          from public.cards c where e.owner_id=v_owner and c.owner_id=v_owner and e.card_id=c.id and c.course_id=v_id and e.deleted_at is null;
        update public.review_states r set deleted_at=v_deleted_at,last_device_id=p_device_id,last_mutation_id=p_mutation_id
          from public.cards c where r.owner_id=v_owner and c.owner_id=v_owner and r.card_id=c.id and c.course_id=v_id and r.deleted_at is null;
      elsif p_table='cards' then
        update public.card_examples set deleted_at=v_deleted_at,last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and card_id=v_id and deleted_at is null;
        update public.review_states set deleted_at=v_deleted_at,last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and card_id=v_id and deleted_at is null;
      end if;
      v_receipt := jsonb_build_object('table',p_table,'row',v_row);
    else
      v_payload := v_payload - 'id' - 'owner_id' - 'revision' - 'updated_at' - 'last_device_id' - 'last_mutation_id';
      if p_table='topics' then
        update public.topics t set name=coalesce(v_payload->>'name',t.name),
          created_at=coalesce((v_payload->>'created_at')::timestamptz,t.created_at),
          deleted_at=case when v_payload?'deleted_at' then (v_payload->>'deleted_at')::timestamptz else t.deleted_at end,
          last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and id=v_id returning to_jsonb(t.*) into v_row;
      elsif p_table='courses' then
        update public.courses t set
          topic_id=case when v_payload?'topic_id' then (v_payload->>'topic_id')::uuid else t.topic_id end,
          title=coalesce(v_payload->>'title',t.title), description=case when v_payload?'description' then v_payload->>'description' else t.description end,
          language_id=case when v_payload?'language_id' then (v_payload->>'language_id')::smallint else t.language_id end,
          language_name=case when v_payload?'language_name' then v_payload->>'language_name' else t.language_name end,
          language_code=coalesce(v_payload->>'language_code',t.language_code),
          card_count=coalesce((v_payload->>'card_count')::integer,t.card_count),
          is_favorite=coalesce((v_payload->>'is_favorite')::boolean,t.is_favorite),
          is_archived=coalesce((v_payload->>'is_archived')::boolean,t.is_archived),
          deleted_at=case when v_payload?'deleted_at' then (v_payload->>'deleted_at')::timestamptz else t.deleted_at end,
          last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and id=v_id returning to_jsonb(t.*) into v_row;
      elsif p_table='cards' then
        update public.cards t set course_id=coalesce((v_payload->>'course_id')::uuid,t.course_id),
          term=coalesce(v_payload->>'term',t.term),definition=coalesce(v_payload->>'definition',t.definition),
          pronunciation=case when v_payload?'pronunciation' then v_payload->>'pronunciation' else t.pronunciation end,
          raw_text=case when v_payload?'raw_text' then v_payload->>'raw_text' else t.raw_text end,
          input_format=case when v_payload?'input_format' then v_payload->>'input_format' else t.input_format end,
          extra_meaning=case when v_payload?'extra_meaning' then v_payload->>'extra_meaning' else t.extra_meaning end,
          note=case when v_payload?'note' then v_payload->>'note' else t.note end,
          image_path=case when v_payload?'image_path' then v_payload->>'image_path' else t.image_path end,
          audio_path=case when v_payload?'audio_path' then v_payload->>'audio_path' else t.audio_path end,
          position=coalesce((v_payload->>'position')::integer,t.position),
          is_favorite=coalesce((v_payload->>'is_favorite')::boolean,t.is_favorite),
          is_hidden=coalesce((v_payload->>'is_hidden')::boolean,t.is_hidden),
          deleted_at=case when v_payload?'deleted_at' then (v_payload->>'deleted_at')::timestamptz else t.deleted_at end,
          last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and id=v_id returning to_jsonb(t.*) into v_row;
      elsif p_table='card_examples' then
        update public.card_examples t set card_id=coalesce((v_payload->>'card_id')::uuid,t.card_id),
          example_text=coalesce(v_payload->>'example_text',t.example_text),
          pronunciation=case when v_payload?'pronunciation' then v_payload->>'pronunciation' else t.pronunciation end,
          meaning=case when v_payload?'meaning' then v_payload->>'meaning' else t.meaning end,
          deleted_at=case when v_payload?'deleted_at' then (v_payload->>'deleted_at')::timestamptz else t.deleted_at end,
          last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and id=v_id returning to_jsonb(t.*) into v_row;
      else
        update public.review_states t set card_id=coalesce((v_payload->>'card_id')::uuid,t.card_id),
          level=coalesce((v_payload->>'level')::integer,t.level),ease_factor=coalesce((v_payload->>'ease_factor')::double precision,t.ease_factor),
          interval_days=coalesce((v_payload->>'interval_days')::integer,t.interval_days),
          repetition_count=coalesce((v_payload->>'repetition_count')::integer,t.repetition_count),
          correct_count=coalesce((v_payload->>'correct_count')::integer,t.correct_count),
          wrong_count=coalesce((v_payload->>'wrong_count')::integer,t.wrong_count),
          last_reviewed_at=case when v_payload?'last_reviewed_at' then (v_payload->>'last_reviewed_at')::timestamptz else t.last_reviewed_at end,
          next_review_at=case when v_payload?'next_review_at' then (v_payload->>'next_review_at')::timestamptz else t.next_review_at end,
          deleted_at=case when v_payload?'deleted_at' then (v_payload->>'deleted_at')::timestamptz else t.deleted_at end,
          last_device_id=p_device_id,last_mutation_id=p_mutation_id
          where owner_id=v_owner and id=v_id returning to_jsonb(t.*) into v_row;
      end if;
      v_receipt := jsonb_build_object('table',p_table,'row',v_row);
    end if;
  end if;

  insert into public.sync_mutation_receipts(owner_id,mutation_id,device_id,table_name,entity_id,response)
  values(v_owner,p_mutation_id,p_device_id,p_table,v_id,v_receipt);
  return v_receipt;
end;
$$;

-- Authoritative SRS contract used by both clients. Offline clients may show an
-- optimistic preview, but this locked row and returned payload are canonical.
create or replace function public.apply_srs_review_v2(
  p_card_id uuid,
  p_rating text,
  p_reviewed_at timestamptz,
  p_mutation_id uuid,
  p_device_id text,
  p_base_revision bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid := auth.uid();
  v_row public.review_states%rowtype;
  v_receipt jsonb;
  v_level integer;
  v_interval integer;
  v_ease double precision;
begin
  if v_owner is null then raise exception using errcode='28000',message='authentication required'; end if;
  if lower(p_rating) not in ('again','hard','good','easy') then
    raise exception using errcode='22023',message='rating must be Again, Hard, Good, or Easy';
  end if;
  if p_mutation_id is null or coalesce(trim(p_device_id),'') = '' then
    raise exception using errcode='22023',message='mutation_id and device_id are required';
  end if;
  if not exists (
    select 1 from public.cards
    where id=p_card_id and owner_id=v_owner and deleted_at is null
  ) then
    raise exception using errcode='23503',message='card is missing, deleted, or belongs to another owner';
  end if;
  select response into v_receipt from public.sync_mutation_receipts
    where owner_id=v_owner and mutation_id=p_mutation_id;
  if found then return v_receipt; end if;

  select * into v_row from public.review_states
    where owner_id=v_owner and card_id=p_card_id for update;
  if not found then
    if coalesce(p_base_revision,0) <> 0 then
      raise exception using errcode='40001',message='sync conflict: review state is missing';
    end if;
    insert into public.review_states(owner_id,card_id,last_device_id,last_mutation_id)
      values(v_owner,p_card_id,p_device_id,p_mutation_id) returning * into v_row;
  elsif coalesce(p_base_revision,0) <> v_row.revision then
    raise exception using errcode='40001',message=format(
      'sync conflict: review state base revision %s, current revision %s',p_base_revision,v_row.revision);
  end if;

  v_ease := greatest(1.3,coalesce(v_row.ease_factor,2.5));
  if lower(p_rating)='again' then
    v_level := 0; v_interval := 0; v_ease := greatest(1.3,v_ease-0.20);
  elsif lower(p_rating)='hard' then
    v_level := greatest(1,coalesce(v_row.level,0));
    v_interval := greatest(1,round(greatest(1,coalesce(v_row.interval_days,0))*1.2)::integer);
    v_ease := greatest(1.3,v_ease-0.15);
  elsif lower(p_rating)='easy' then
    v_level := least(8,coalesce(v_row.level,0)+2);
    v_interval := (array[1,2,4,7,15,30,60,120])[v_level];
    v_ease := v_ease+0.15;
  else
    v_level := least(8,coalesce(v_row.level,0)+1);
    v_interval := (array[1,2,4,7,15,30,60,120])[v_level];
  end if;

  update public.review_states set
    level=v_level,ease_factor=v_ease,interval_days=v_interval,
    repetition_count=coalesce(repetition_count,0)+1,
    correct_count=coalesce(correct_count,0)+case when lower(p_rating)='again' then 0 else 1 end,
    wrong_count=coalesce(wrong_count,0)+case when lower(p_rating)='again' then 1 else 0 end,
    last_reviewed_at=p_reviewed_at,
    next_review_at=case when lower(p_rating)='again' then p_reviewed_at+interval '10 minutes'
      else p_reviewed_at+make_interval(days=>v_interval) end,
    deleted_at=null,last_device_id=p_device_id,last_mutation_id=p_mutation_id
    where owner_id=v_owner and card_id=p_card_id returning * into v_row;

  v_receipt := jsonb_build_object('table','review_states','row',to_jsonb(v_row));
  insert into public.sync_mutation_receipts(owner_id,mutation_id,device_id,table_name,entity_id,response)
    values(v_owner,p_mutation_id,p_device_id,'review_states',v_row.id,v_receipt);
  return v_receipt;
end;
$$;

create or replace function public.sync_v2_changes_since(p_since timestamptz)
returns table(table_name text, row_data jsonb)
language sql
security definer
set search_path = public
as $$
  select changes.table_name, changes.row_data
  from (
    select 'topics'::text as table_name, to_jsonb(t) as row_data
    from public.topics t
    where t.owner_id=auth.uid() and t.updated_at>p_since
    union all
    select 'courses',to_jsonb(t) from public.courses t
    where t.owner_id=auth.uid() and t.updated_at>p_since
    union all
    select 'cards',to_jsonb(t) from public.cards t
    where t.owner_id=auth.uid() and t.updated_at>p_since
    union all
    select 'card_examples',to_jsonb(t) from public.card_examples t
    where t.owner_id=auth.uid() and t.updated_at>p_since
    union all
    select 'review_states',to_jsonb(t) from public.review_states t
    where t.owner_id=auth.uid() and t.updated_at>p_since
  ) as changes
  order by
    (changes.row_data->>'updated_at')::timestamptz,
    changes.table_name;
$$;

grant execute on function public.apply_sync_v2_mutation(text,uuid,text,jsonb,uuid,text,bigint) to authenticated;
grant execute on function public.apply_srs_review_v2(uuid,text,timestamptz,uuid,text,bigint) to authenticated;
grant execute on function public.sync_v2_changes_since(timestamptz) to authenticated;

-- DELETE payloads must contain old_record columns such as card_id and revision.
do $$
declare
  table_name text;
begin
  if exists (select 1 from pg_publication where pubname='supabase_realtime') then
    foreach table_name in array array[
      'topics','courses','cards','card_examples','review_states'
    ] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname='supabase_realtime' and schemaname='public'
          and tablename=table_name
      ) then
        execute format(
          'alter publication supabase_realtime add table public.%I',
          table_name
        );
      end if;
    end loop;
  end if;
end;
$$;

alter table public.topics replica identity full;
alter table public.courses replica identity full;
alter table public.cards replica identity full;
alter table public.card_examples replica identity full;
alter table public.review_states replica identity full;
