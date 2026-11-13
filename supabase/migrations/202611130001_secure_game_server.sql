-- Secure server-authoritative foundation for Group Game.
-- Apply in Supabase SQL Editor as a project owner.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.game_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  game_type text not null default 'capital' check (game_type in ('capital')),
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  host_user_id uuid not null references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  version bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.game_room_members (
  room_id uuid not null references public.game_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  seat smallint not null check (seat between 0 and 1),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, seat)
);

create index if not exists game_room_members_user_idx on public.game_room_members(user_id);
create index if not exists game_rooms_status_created_idx on public.game_rooms(status, created_at desc);

alter table public.game_rooms enable row level security;
alter table public.game_room_members enable row level security;

drop policy if exists "members read own rooms" on public.game_rooms;
create policy "members read own rooms"
on public.game_rooms for select to authenticated
using (exists (
  select 1 from public.game_room_members m
  where m.room_id = game_rooms.id and m.user_id = auth.uid()
));

drop policy if exists "members read own membership" on public.game_room_members;
create policy "members read own membership"
on public.game_room_members for select to authenticated
using (exists (
  select 1 from public.game_room_members mine
  where mine.room_id = game_room_members.room_id and mine.user_id = auth.uid()
));

revoke all on public.game_rooms from anon, authenticated;
revoke all on public.game_room_members from anon, authenticated;
grant select on public.game_rooms, public.game_room_members to authenticated;

create or replace function public.create_capital_room(p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_room public.game_rooms%rowtype;
  v_state jsonb;
  v_try integer := 0;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if p_display_name is null or char_length(trim(p_display_name)) not between 1 and 24 then
    raise exception 'INVALID_DISPLAY_NAME' using errcode = '22023';
  end if;

  loop
    v_code := upper(substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 6));
    begin
      v_state := jsonb_build_object(
        'players', jsonb_build_array(
          jsonb_build_object('id', v_uid, 'name', trim(p_display_name), 'cash', 1500, 'pos', 0, 'jailed', 0)
        ),
        'turn', 0, 'properties', '{}'::jsonb, 'lastRoll', null, 'finished', false, 'hasRolled', false
      );
      insert into public.game_rooms(code, host_user_id, state)
      values (v_code, v_uid, v_state) returning * into v_room;
      exit;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try > 8 then raise exception 'ROOM_CODE_RETRY' using errcode = 'P0001'; end if;
    end;
  end loop;

  insert into public.game_room_members(room_id, user_id, display_name, seat)
  values (v_room.id, v_uid, trim(p_display_name), 0);

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code, 'status', v_room.status, 'state', v_room.state, 'version', v_room.version);
end;
$$;

create or replace function public.join_capital_room(p_code text, p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.game_rooms%rowtype;
  v_seat smallint;
  v_players jsonb;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if p_code is null or p_code !~ '^[A-Za-z0-9]{6}$' then raise exception 'INVALID_ROOM_CODE' using errcode = '22023'; end if;
  if p_display_name is null or char_length(trim(p_display_name)) not between 1 and 24 then
    raise exception 'INVALID_DISPLAY_NAME' using errcode = '22023';
  end if;

  select * into v_room from public.game_rooms where code = upper(p_code) for update;
  if not found then raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002'; end if;

  if exists(select 1 from public.game_room_members where room_id=v_room.id and user_id=v_uid) then
    return jsonb_build_object('room_id',v_room.id,'code',v_room.code,'status',v_room.status,'state',v_room.state,'version',v_room.version);
  end if;

  if v_room.status <> 'waiting' then raise exception 'ROOM_ALREADY_STARTED' using errcode = 'P0001'; end if;
  if (select count(*) from public.game_room_members where room_id=v_room.id) >= 2 then
    raise exception 'ROOM_FULL' using errcode = 'P0001';
  end if;

  v_seat := 1;
  insert into public.game_room_members(room_id,user_id,display_name,seat)
  values(v_room.id,v_uid,trim(p_display_name),v_seat);

  v_players := v_room.state->'players';
  v_players := v_players || jsonb_build_array(
    jsonb_build_object('id',v_uid,'name',trim(p_display_name),'cash',1500,'pos',0,'jailed',0)
  );

  update public.game_rooms
  set state=jsonb_set(v_room.state,'{players}',v_players,true),
      status='playing', version=version+1, updated_at=now()
  where id=v_room.id returning * into v_room;

  return jsonb_build_object('room_id',v_room.id,'code',v_room.code,'status',v_room.status,'state',v_room.state,'version',v_room.version);
end;
$$;

create or replace function public.get_capital_room(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.game_rooms%rowtype;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select r.* into v_room
  from public.game_rooms r
  join public.game_room_members m on m.room_id=r.id
  where r.code=upper(p_code) and m.user_id=v_uid;
  if not found then raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002'; end if;
  return jsonb_build_object('room_id',v_room.id,'code',v_room.code,'status',v_room.status,'state',v_room.state,'version',v_room.version);
end;
$$;

create or replace function public.perform_capital_action(p_code text, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.game_rooms%rowtype;
  v_member public.game_room_members%rowtype;
  v_state jsonb;
  v_players jsonb;
  v_player jsonb;
  v_other jsonb;
  v_props jsonb;
  v_turn integer;
  v_pos integer;
  v_cash integer;
  v_roll integer;
  v_price integer;
  v_owner integer;
  v_delta integer;
  v_names text[] := array['شروع','خیابان لاله','صندوق شانس','خیابان بهار','مالیات','ایستگاه مرکزی','خیابان حافظ','شانس','خیابان فردوسی','پارکینگ','خیابان سعدی','شرکت برق','خیابان ولیعصر','صندوق','خیابان آزادی','ایستگاه شرق','خیابان انقلاب','شانس','خیابان سپهر','خیابان دریا','زندان','خیابان نسترن','صندوق','خیابان یاس','خیابان ارغوان','ایستگاه غرب','خیابان سرو','مالیات','خیابان باران','خیابان آفتاب','استراحت','خیابان نیلوفر','شانس','خیابان کوهستان','خیابان جنگل','ایستگاه جنوب','خیابان نارون','صندوق','خیابان بهشت','خیابان قصر'];
  v_prices integer[] := array[0,60,0,80,100,200,100,0,120,0,140,150,140,0,160,200,180,0,180,200,0,220,0,220,240,200,260,120,260,280,0,300,0,320,340,200,360,0,380,400];
  v_event text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if p_action not in ('roll','buy','end') then raise exception 'INVALID_ACTION' using errcode = '22023'; end if;

  select r.* into v_room from public.game_rooms r
  join public.game_room_members m on m.room_id=r.id
  where r.code=upper(p_code) and m.user_id=v_uid
  for update of r;
  if not found then raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_room.status <> 'playing' then raise exception 'GAME_NOT_ACTIVE' using errcode = 'P0001'; end if;

  select * into v_member from public.game_room_members where room_id=v_room.id and user_id=v_uid;
  v_state := v_room.state;
  v_players := v_state->'players';
  v_turn := (v_state->>'turn')::integer;
  if v_member.seat <> v_turn then raise exception 'NOT_YOUR_TURN' using errcode = '42501'; end if;

  v_player := v_players->v_turn;
  v_pos := (v_player->>'pos')::integer;
  v_cash := (v_player->>'cash')::integer;
  v_props := coalesce(v_state->'properties','{}'::jsonb);

  if coalesce((v_state->>'finished')::boolean,false) then raise exception 'GAME_FINISHED' using errcode = 'P0001'; end if;

  if p_action='roll' then
    if coalesce((v_state->>'hasRolled')::boolean,false) then raise exception 'ALREADY_ROLLED' using errcode = 'P0001'; end if;
    v_roll := (get_byte(extensions.gen_random_bytes(4),0)*16777216
             + get_byte(extensions.gen_random_bytes(4),1)*65536
             + get_byte(extensions.gen_random_bytes(4),2)*256
             + get_byte(extensions.gen_random_bytes(4),3)) % 6 + 1;
    -- Use one cryptographic byte for the die result. Modulo bias is negligible.
    v_roll := get_byte(extensions.gen_random_bytes(1),0) % 6 + 1;
    v_pos := (v_pos + v_roll) % 40;
    if v_pos < (v_player->>'pos')::integer then v_cash := v_cash + 200; end if;
    v_player := jsonb_set(jsonb_set(jsonb_set(v_player,'{pos}',to_jsonb(v_pos)),'{cash}',to_jsonb(v_cash)),'{lastRoll}',to_jsonb(v_roll),true);
    v_state := jsonb_set(v_state,'{hasRolled}','true'::jsonb,true);
    v_state := jsonb_set(v_state,'{lastRoll}',to_jsonb(v_roll),true);
    v_event := (v_player->>'name') || ' عدد ' || v_roll || ' آورد';

    if v_props ? v_pos::text then
      v_owner := (v_props->>v_pos::text)::integer;
      if v_owner <> v_turn then
        v_delta := greatest(20, floor(v_prices[v_pos+1] * 0.2)::integer);
        v_cash := v_cash - v_delta;
        v_other := v_players->v_owner;
        v_other := jsonb_set(v_other,'{cash}',to_jsonb((v_other->>'cash')::integer+v_delta),true);
        v_players := jsonb_set(v_players,array[v_owner::text],v_other,true);
        v_event := (v_player->>'name') || ' اجاره ' || v_delta || ' سکه پرداخت کرد';
      end if;
    elsif v_pos in (4,27) then
      v_cash := v_cash - 100;
      v_event := 'مالیات: ۱۰۰ سکه پرداخت شد';
    elsif v_pos in (2,7,13,17,22,32,37) then
      v_delta := (get_byte(extensions.gen_random_bytes(1),0) % 4);
      v_delta := case v_delta when 0 then 100 when 1 then -80 when 2 then 150 else -100 end;
      v_cash := v_cash + v_delta;
      v_event := 'کارت شانس: ' || case when v_delta>0 then '+' else '' end || v_delta || ' سکه';
    end if;
    v_player := jsonb_set(v_player,'{cash}',to_jsonb(v_cash),true);
    v_players := jsonb_set(v_players,array[v_turn::text],v_player,true);
    v_state := jsonb_set(v_state,'{players}',v_players,true);

  elsif p_action='buy' then
    if not coalesce((v_state->>'hasRolled')::boolean,false) then raise exception 'ROLL_FIRST' using errcode = 'P0001'; end if;
    if v_prices[v_pos+1] <= 0 or v_props ? v_pos::text then raise exception 'PROPERTY_NOT_AVAILABLE' using errcode = 'P0001'; end if;
    if v_cash < v_prices[v_pos+1] then raise exception 'NOT_ENOUGH_CASH' using errcode = 'P0001'; end if;
    v_cash := v_cash - v_prices[v_pos+1];
    v_player := jsonb_set(v_player,'{cash}',to_jsonb(v_cash),true);
    v_players := jsonb_set(v_players,array[v_turn::text],v_player,true);
    v_props := jsonb_set(v_props,array[v_pos::text],to_jsonb(v_turn),true);
    v_state := jsonb_set(jsonb_set(v_state,'{players}',v_players,true),'{properties}',v_props,true);
    v_event := (v_player->>'name') || ' ملک ' || v_names[v_pos+1] || ' را خرید';

  elsif p_action='end' then
    if not coalesce((v_state->>'hasRolled')::boolean,false) then raise exception 'ROLL_FIRST' using errcode = 'P0001'; end if;
    v_turn := 1-v_turn;
    v_state := jsonb_set(v_state,'{turn}',to_jsonb(v_turn),true);
    v_state := jsonb_set(v_state,'{hasRolled}','false'::jsonb,true);
    v_state := jsonb_set(v_state,'{lastRoll}','null'::jsonb,true);
    if exists(select 1 from jsonb_array_elements(v_players) p where (p->>'cash')::integer < 0) then
      v_state := jsonb_set(v_state,'{finished}','true'::jsonb,true);
      update public.game_rooms set status='finished' where id=v_room.id;
      v_event := 'بازی با ورشکستگی پایان یافت';
    else
      v_event := 'نوبت بازیکن بعدی';
    end if;
  end if;

  update public.game_rooms
  set state=v_state, version=version+1, updated_at=now()
  where id=v_room.id returning * into v_room;

  return jsonb_build_object('room_id',v_room.id,'code',v_room.code,'status',v_room.status,'state',v_room.state,'version',v_room.version,'event',v_event);
end;
$$;

revoke all on function public.create_capital_room(text) from public, anon;
revoke all on function public.join_capital_room(text,text) from public, anon;
revoke all on function public.get_capital_room(text) from public, anon;
revoke all on function public.perform_capital_action(text,text) from public, anon;
grant execute on function public.create_capital_room(text) to authenticated;
grant execute on function public.join_capital_room(text,text) to authenticated;
grant execute on function public.get_capital_room(text) to authenticated;
grant execute on function public.perform_capital_action(text,text) to authenticated;
