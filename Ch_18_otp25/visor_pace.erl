%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% Watch-speed policy for a scape, so a human can follow what the agents do.
%%
%% Agents in flatland step as fast as the CPU allows: each step ends with a
%% gen_server:call({actuator,...}) to the scape, and the agent waits for the reply
%% before sensing again. A scape slows its agents down by *deferring that reply*
%% (gen_server's {noreply,...} + gen_server:reply/2 later) instead of sleeping, so
%% the scape itself stays responsive to every other agent, the visor and the tick.
%%
%% Each caller (one per actuator) is held to at most Rate replies per second. While
%% paused, replies are held back and released on resume. Rate 'max' disables pacing,
%% which is the book's original behaviour and the default when no visor is attached.
%%
%% Scape side:
%%   case visor_pace:on_reply(Pace, From_PId, From, Reply) of
%%       {reply, P}        -> {reply, Reply, S#{pace := P}};
%%       {defer, Ms, P}    -> erlang:send_after(Ms, self(), {visor_pace, From, Reply}),
%%                            {noreply, S#{pace := P}};
%%       {hold, P}         -> {noreply, S#{pace := P}}
%%   end
%%   handle_info({visor_pace, From, Reply}) -> visor_pace:on_timer(...) likewise
%%   handle_cast({visor, pace, Cmd})       -> {P, Release} = visor_pace:command(Pace, Cmd),
%%                                            [gen_server:reply(F, R) || {F, R} <- Release]
-module(visor_pace).

-export([new/0, command/2, on_reply/4, on_timer/3, info/1, rate/1, paused/1]).
-export_type([pace/0, rate/0, cmd/0]).

-type rate() :: max | pos_integer().
-type cmd() :: {speed, rate()} | pause | resume | toggle_pause | reset.
-type held() :: {gen_server:from(), term()}.
-opaque pace() :: #{rate := rate(), paused := boolean(), due := #{term() => integer()}, held := [held()]}.

-define(MAX_RATE, 100000).
-define(PRUNE_AT, 4096).

-spec new() -> pace().
new() ->
	#{rate => max, paused => false, due => #{}, held => []}.

%% Returns the new pace and the held replies the scape must now send.
-spec command(pace(), cmd()) -> {pace(), [held()]}.
command(P, {speed, max}) ->
	{P#{rate := max, due := #{}}, []};
command(P, {speed, N}) when is_number(N), N > 0 ->
	{P#{rate := min(?MAX_RATE, max(1, round(N))), due := #{}}, []};
command(P, pause) ->
	{P#{paused := true}, []};
command(P = #{held := Held}, resume) ->
	{P#{paused := false, held := [], due := #{}}, lists:reverse(Held)};
command(P = #{paused := true}, toggle_pause) ->
	command(P, resume);
command(P, toggle_pause) ->
	command(P, pause);
command(P, reset) ->
	{P1, Release} = command(P, resume),
	{P1#{rate := max}, Release};
command(P, _Unknown) ->
	{P, []}.

%% Key identifies the paced caller (the actuator pid); From is the gen_server From.
-spec on_reply(pace(), term(), gen_server:from(), term()) ->
	{reply, pace()} | {defer, pos_integer(), pace()} | {hold, pace()}.
on_reply(P = #{paused := true, held := Held}, _Key, From, Reply) ->
	{hold, P#{held := [{From, Reply} | Held]}};
on_reply(P = #{rate := max}, _Key, _From, _Reply) ->
	{reply, P};
on_reply(P = #{rate := Rate, due := Due}, Key, _From, _Reply) ->
	Now = erlang:monotonic_time(millisecond),
	Period = max(1, 1000 div Rate),
	Next = maps:get(Key, Due, Now),
	Due1 = prune(Due, Now),
	case Next =< Now of
		true -> {reply, P#{due := Due1#{Key => Now + Period}}};
		false -> {defer, Next - Now, P#{due := Due1#{Key => Next + Period}}}
	end.

%% A deferred reply's timer fired; it may have been paused in the meantime.
-spec on_timer(pace(), gen_server:from(), term()) -> {reply, pace()} | {hold, pace()}.
on_timer(P = #{paused := true, held := Held}, From, Reply) ->
	{hold, P#{held := [{From, Reply} | Held]}};
on_timer(P, _From, _Reply) ->
	{reply, P}.

-spec info(pace()) -> #{speed := rate(), paused := boolean()}.
info(#{rate := Rate, paused := Paused}) ->
	#{speed => Rate, paused => Paused}.

-spec rate(pace()) -> rate().
rate(#{rate := Rate}) -> Rate.

-spec paused(pace()) -> boolean().
paused(#{paused := Paused}) -> Paused.

%% Callers that died leave stale entries; drop the ones already in the past.
prune(Due, Now) when map_size(Due) >= ?PRUNE_AT ->
	maps:filter(fun(_, T) -> T > Now end, Due);
prune(Due, _Now) ->
	Due.
