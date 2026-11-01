%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% A stand-in scape (no polis, no mnesia) speaking the same visor protocol as
%% flatland, including the watch-speed commands. At speed 'max' (key M) it runs as
%% fast as the CPU allows, to see the visor keep up with a simulation far faster
%% than the screen; at a watch speed it steps each agent N times per second.
%% Agents burn one unit of energy per step and starve at zero; predators eat the
%% prey they touch. The dead are reborn elsewhere, so deaths can be seen in the visor:
%%   visor_demo:start().          % 40 agents, opens the visor on it
%%   visor:stats().               % sim steps/s vs frames shown/skipped, frame age
%%   visor_demo:stop().
-module(visor_demo).
-behaviour(gen_server).
-include("records.hrl").

-export([start/0, start/1, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(BATCH, 500).
-define(PACED_INTERVAL_MS, 20).
-define(PAUSED_INTERVAL_MS, 50).
-define(STEP_LENGTH, 3.0).
-define(MEAL, 400).
-define(STEPS_PER_GENERATION, 200000).
-define(XMAX, 800).
-define(YMAX, 500).

start() ->
	start(#{}).

%% Opts: agents => N (default 40), visor => boolean() (default true), plus any visor:start/1 option.
start(Opts) ->
	WithVisor = maps:get(visor, Opts, true),
	Speed = case WithVisor of true -> maps:get(speed, Opts, 20); false -> max end,
	{ok, Pid} = gen_server:start({local, ?SERVER}, ?MODULE, {maps:get(agents, Opts, 40), Speed}, []),
	case WithVisor of
		true -> visor:start(maps:merge(#{scape => Pid}, maps:without([agents, visor], Opts)));
		false -> {ok, Pid}
	end.

stop() ->
	visor:stop(),
	gen_server:stop(?SERVER).

init({N, Speed}) ->
	self() ! run,
	{Pace, []} = visor_pace:command(visor_pace:new(), {speed, Speed}),
	{ok, #{avatars => scenery() ++ [agent(I) || I <- lists:seq(1, N)], steps => 0, cursor => 0,
	       visor => undefined, pace => Pace, owed => 0.0, deaths => visor_deaths:new_log(),
	       last_run => erlang:monotonic_time(millisecond)}}.

handle_call({visor, subscribe, Visor, MaxHz}, _From, S) ->
	S1 = unsubscribe(S),
	Tab = visor_frame:new(),
	Pub = visor_frame:publish_now(visor_frame:publisher(Tab, MaxHz), fun() -> snapshot(S1) end),
	{reply, {ok, Tab}, S1#{visor := {erlang:monitor(process, Visor), Pub}}};
handle_call(_Req, _From, S) ->
	{reply, {error, unknown_request}, S}.

handle_cast({visor, pace, Cmd}, S = #{pace := Pace}) ->
	{Pace1, _NoHeldCalls} = visor_pace:command(Pace, Cmd),
	{noreply, publish_now(S#{pace := Pace1, owed := 0.0})};
handle_cast({_Visor, unsubscribe}, S) ->
	{noreply, unsubscribe(S)};
handle_cast(_Msg, S) ->
	{noreply, S}.

%% Runs a batch of steps, then yields to the mailbox (so visor commands are served
%% promptly). Unthrottled it re-posts 'run' at once; at a watch speed it runs the
%% steps owed for the elapsed time (Rate per agent per second) every 20 ms.
handle_info(run, S = #{pace := Pace, last_run := Last, owed := Owed}) ->
	Now = erlang:monotonic_time(millisecond),
	S0 = S#{last_run := Now},
	case {visor_pace:paused(Pace), visor_pace:rate(Pace)} of
		{true, _} ->
			erlang:send_after(?PAUSED_INTERVAL_MS, self(), run),
			{noreply, S0};
		{false, max} ->
			self() ! run,
			{noreply, run_steps(?BATCH, S0)};
		{false, Rate} ->
			Due = Owed + Rate * movers(S) * (Now - Last) / 1000,
			N = trunc(Due),
			erlang:send_after(?PACED_INTERVAL_MS, self(), run),
			{noreply, run_steps(N, S0#{owed := Due - N})}
	end;
handle_info({'DOWN', MRef, process, _, _}, S = #{visor := {MRef, _}}) ->
	{noreply, unsubscribe(S)};
handle_info(_Info, S) ->
	{noreply, S}.

terminate(_Reason, S) ->
	unsubscribe(S),
	ok.

code_change(_OldVsn, S, _Extra) ->
	{ok, S}.

%%====================================================================

run_steps(0, S) ->
	S;
run_steps(N, S = #{steps := Steps}) ->
	S1 = lists:foldl(fun(_, Acc) -> step(Acc) end, S, lists:seq(1, N)),
	Steps1 = Steps + N,
	Steps div ?STEPS_PER_GENERATION =/= Steps1 div ?STEPS_PER_GENERATION andalso
		visor:notify(#{generation => Steps1 div ?STEPS_PER_GENERATION, evaluations => Steps1 div 1000}),
	publish(S1#{steps := Steps1}).

movers(#{avatars := Avatars}) ->
	length([A || A = #avatar{type = T} <- Avatars, T == prey orelse T == predator]).

publish_now(S = #{visor := undefined}) ->
	S;
publish_now(S = #{visor := {MRef, Pub}}) ->
	S#{visor := {MRef, visor_frame:publish_now(Pub, fun() -> snapshot(S) end)}}.

publish(S = #{visor := undefined}) ->
	S;
publish(S = #{visor := {MRef, Pub}}) ->
	S#{visor := {MRef, visor_frame:maybe_publish(Pub, fun() -> snapshot(S) end)}}.

unsubscribe(S = #{visor := {MRef, Pub}, pace := Pace}) ->
	erlang:demonitor(MRef, [flush]),
	visor_frame:retire(Pub),
	{Pace1, _} = visor_pace:command(Pace, reset),
	S#{visor := undefined, pace := Pace1};
unsubscribe(S) ->
	S.

snapshot(#{avatars := Avatars, steps := Steps, pace := Pace, deaths := Deaths}) ->
	Frame = visor_frame:from_avatars(Avatars,
		maps:merge(#{scape => visor_demo, steps => Steps, ticks => Steps div ?BATCH}, visor_pace:info(Pace))),
	Frame#{deaths => Deaths}.

%% Moves one agent (round robin), like one actuator call in flatland.
step(S = #{avatars := Avatars, cursor := C}) ->
	Movers = [A || A = #avatar{type = T} <- Avatars, T == prey orelse T == predator],
	Idx = C rem max(1, length(Movers)),
	case Movers of
		[] -> S;
		_ ->
			A = lists:nth(Idx + 1, Movers),
			U_A = move(A),
			U_A1 = U_A#avatar{energy = U_A#avatar.energy - 1, age = U_A#avatar.age + 1},
			S1 = S#{avatars := replace(U_A1, Avatars), cursor := C + 1},
			case U_A1#avatar.energy =< 0 of
				true -> die(U_A1, starved, S1);
				false -> hunt(U_A1, S1)
			end
	end.

hunt(P = #avatar{type = predator, loc = {X, Y}, r = R}, S = #{avatars := Avatars}) ->
	Touching = [V || V = #avatar{type = prey, loc = {VX, VY}, r = VR} <- Avatars,
		math:sqrt((X - VX) * (X - VX) + (Y - VY) * (Y - VY)) < R + VR],
	case Touching of
		[Victim | _] ->
			Fed = P#avatar{energy = P#avatar.energy + ?MEAL, kills = P#avatar.kills + 1},
			die(Victim, {eaten, predator}, S#{avatars := replace(Fed, Avatars)});
		[] ->
			S
	end;
hunt(_Prey, S) ->
	S.

die(A = #avatar{id = Id, type = Type}, Cause, S = #{avatars := Avatars, deaths := Log}) ->
	Log1 = visor_deaths:record(Log, Id, Type, A#avatar.loc, Cause, A#avatar.age),
	S#{avatars := replace(new_agent(Id, Type), Avatars), deaths := Log1}.

replace(A = #avatar{id = Id}, Avatars) ->
	lists:keyreplace(Id, #avatar.id, Avatars, A).

move(A = #avatar{loc = {X, Y}, direction = {DX, DY}, r = R}) ->
	Turn = (rand:uniform() - 0.5) * 0.2,
	{DX1, DY1} = {DX * math:cos(Turn) - DY * math:sin(Turn), DX * math:sin(Turn) + DY * math:cos(Turn)},
	{DX2, X1} = bounce(X + DX1 * ?STEP_LENGTH, DX1, R, ?XMAX),
	{DY2, Y1} = bounce(Y + DY1 * ?STEP_LENGTH, DY1, R, ?YMAX),
	A#avatar{loc = {X1, Y1}, direction = {DX2, DY2}, objects = body(A#avatar.type, {X1, Y1}, {DX2, DY2}, R)}.

bounce(P, D, R, _Max) when P < R -> {abs(D), R};
bounce(P, D, R, Max) when P > Max - R -> {-abs(D), Max - R};
bounce(P, D, _R, _Max) -> {D, P}.

agent(I) ->
	new_agent({agent, I}, case I rem 4 of 0 -> predator; _ -> prey end).

new_agent(Id, Type) ->
	R = case Type of predator -> 6; prey -> 10 end,
	Energy = case Type of predator -> 300 + rand:uniform(500); prey -> 150 + rand:uniform(600) end,
	Loc = {R + rand:uniform(?XMAX - 2 * R), R + rand:uniform(?YMAX - 2 * R)},
	Angle = rand:uniform() * 2 * math:pi(),
	Dir = {math:cos(Angle), math:sin(Angle)},
	#avatar{id = Id, type = Type, loc = Loc, direction = Dir, r = R, energy = Energy, age = 0,
		objects = body(Type, Loc, Dir, R)}.

body(Type, {X, Y} = Loc, {DX, DY}, R) ->
	Color = case Type of predator -> red; prey -> blue end,
	[{circle, undefined, Color, Loc, [Loc], R},
	 {line, undefined, Color, Loc, [Loc, {X + DX * R * 2, Y + DY * R * 2}], void}].

scenery() ->
	Walls = [{{0, 0}, {?XMAX, 0}}, {{?XMAX, 0}, {?XMAX, ?YMAX}}, {{?XMAX, ?YMAX}, {0, ?YMAX}}, {{0, ?YMAX}, {0, 0}}],
	[#avatar{id = {wall, I}, type = wall, objects = [{line, undefined, brown, P1, [P1, P2], void}]}
	 || {I, {P1, P2}} <- lists:zip(lists:seq(1, length(Walls)), Walls)]
	++ [#avatar{id = {plant, I}, type = plant, loc = L, r = 3, objects = [{circle, undefined, green, L, [L], 3}]}
	    || I <- lists:seq(1, 15), L <- [{rand:uniform(?XMAX), rand:uniform(?YMAX)}]]
	++ [#avatar{id = {poison, I}, type = poison, loc = L, r = 3, objects = [{circle, undefined, black, L, [L], 3}]}
	    || I <- lists:seq(1, 10), L <- [{rand:uniform(?XMAX), rand:uniform(?YMAX)}]].
