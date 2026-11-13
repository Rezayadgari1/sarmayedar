-- Capital game upgrade: support 2-8 human players and explicit host start.
-- Run this migration in the Supabase SQL Editor after the previous migration.

alter table public.game_room_members
  drop constraint if exists game_room_members_seat_check;

alter table public.game_room_members
  add constraint game_room_members_seat_check check (seat between 0 and 7);

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
  select count(*)::smallint into v_seat from public.game_room_members where room_id=v_room.id;
  if v_seat >= 8 then raise exception 'ROOM_FULL' using errcode = 'P0001'; end if;

  insert into public.game_room_members(room_id,user_id,display_name,seat)
  values(v_room.id,v_uid,trim(p_display_name),v_seat);

  v_players := v_room.state->'players';
  v_players := v_players || jsonb_build_array(
    jsonb_build_object('id',v_uid,'name',trim(p_display_name),'cash',1500,'pos',0,'jailed',0)
  );

  update public.game_rooms
  set state=jsonb_set(v_room.state,'{players}',v_players,true),
      version=version+1, updated_at=now()
  where id=v_room.id returning * into v_room;

  return jsonb_build_object('room_id',v_room.id,'code',v_room.code,'status',v_room.status,'state',v_room.state,'version',v_room.version);
end;
$$;

create or replace function public.start_capital_game(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.game_rooms%rowtype;
  v_count integer;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select * into v_room from public.game_rooms where code=upper(p_code) for update;
  if not found then raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_room.host_user_id <> v_uid then raise exception 'HOST_ONLY' using errcode = '42501'; end if;
  if v_room.status <> 'waiting' then raise exception 'GAME_ALREADY_STARTED' using errcode = 'P0001'; end if;
  select count(*) into v_count from public.game_room_members where room_id=v_room.id;
  if v_count < 2 then raise exception 'NEED_TWO_PLAYERS' using errcode = 'P0001'; end if;
  if v_count > 8 then raise exception 'ROOM_FULL' using errcode = 'P0001'; end if;

  update public.game_rooms
  set status='playing',
      state=jsonb_set(state,'{hasRolled}','false'::jsonb,true),
      version=version+1, updated_at=now()
  where id=v_room.id returning * into v_room;

  return jsonb_build_object('room_id',v_room.id,'code',v_room.code,'status',v_room.status,'state',v_room.state,'version',v_room.version);
end;
$$;

-- Change turn rotation from two-player toggling to round-robin for all seated players.
do $$
declare
  v_definition text;
begin
  v_definition := pg_get_functiondef('public.perform_capital_action(text,text)'::regprocedure);
  if position('v_turn := 1-v_turn;' in v_definition) = 0 then
    raise exception 'EXPECTED_TURN_ROTATION_NOT_FOUND';
  end if;
  v_definition := replace(
    v_definition,
    'v_turn := 1-v_turn;',
    'v_turn := (v_turn + 1) % jsonb_array_length(v_players);'
  );
  execute v_definition;
end
$$;

revoke all on function public.join_capital_room(text,text) from public, anon;
revoke all on function public.start_capital_game(text) from public, anon;
grant execute on function public.join_capital_room(text,text) to authenticated;
grant execute on function public.start_capital_game(text) to authenticated;

notify pgrst, 'reload schema';
