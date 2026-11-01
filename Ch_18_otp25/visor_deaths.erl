%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% Making deaths visible.
%%
%% Model side: the scape keeps a small death log (totals per cause plus the last
%% ?RECENT death events, each numbered) and puts it in every published frame. Since
%% each frame carries the recent history, a death is not lost when the frame that
%% would have shown it was throttled away.
%%
%% Controller side: the visor turns the events it has not seen yet into markers: a
%% fading cross where the avatar died, a label with the cause and age, and, once
%% the same agent re-enters the scape (the book's exoself retries an agent several
%% times), a dashed line to where it came back plus an expanding ring there.
%% primitives/2 hands the view plain, wx-free drawing instructions.
-module(visor_deaths).

-export([new_log/0, record/6]).
-export([new_marks/0, absorb/3, prune/2, primitives/2, hud_line/1, total/1]).
-export_type([log/0, marks/0, cause/0, primitive/0]).

-type point() :: {number(), number()}.
-type cause() :: starved | old_age | {eaten, Killer :: atom()} | atom().
-type event() :: #{n := pos_integer(), id := term(), type := atom(), loc := point(),
	cause := cause(), age := non_neg_integer()}.
-type log() :: #{total := non_neg_integer(), by_cause := #{atom() => pos_integer()}, recent := [event()]}.
-type mark() :: #{ev := event(), t := integer(), respawn := undefined | {point(), integer()}}.
-type marks() :: #{last_n := undefined | non_neg_integer(), marks := [mark()],
	total := non_neg_integer(), by_cause := map(), last := undefined | event()}.
-type color() :: atom().
-type primitive() :: {cross, color(), point(), Alpha :: float()}
	| {label, color(), point(), unicode:chardata(), Alpha :: float()}
	| {link, color(), point(), point(), Alpha :: float()}
	| {ring, color(), point(), Progress :: float()}.

-define(RECENT, 64).
-define(MAX_MARKS, 40).
-define(MAX_LABELS, 15).
-define(FADE_MS, 5000).
-define(RING_MS, 1200).

%%==================================================================== model side

-spec new_log() -> log().
new_log() ->
	#{total => 0, by_cause => #{}, recent => []}.

-spec record(log(), term(), atom(), point(), cause(), non_neg_integer()) -> log().
record(Log = #{total := Total, by_cause := ByCause, recent := Recent}, Id, Type, Loc, Cause, Age) ->
	N = Total + 1,
	Event = #{n => N, id => Id, type => Type, loc => Loc, cause => Cause, age => Age},
	Log#{total := N,
	     by_cause := maps:update_with(cause_key(Cause), fun(C) -> C + 1 end, 1, ByCause),
	     recent := lists:sublist([Event | Recent], ?RECENT)}.

%%==================================================================== controller side

-spec new_marks() -> marks().
new_marks() ->
	#{last_n => undefined, marks => [], total => 0, by_cause => #{}, last => undefined}.

%% Folds a newly pulled frame into the markers. Returns the ids of the agents that
%% died since the previous frame, so the caller can restart their trails.
-spec absorb(marks(), map(), integer()) -> {marks(), [term()]}.
absorb(M, #{deaths := Log} = Frame, Now) ->
	#{total := Total, by_cause := ByCause, recent := Recent} = Log,
	M0 = case M of
		#{last_n := Last} when is_integer(Last), Total < Last -> new_marks();  % a new scape
		_ -> M
	end,
	case M0 of
		#{last_n := undefined} ->
			%% Just connected: show counts, but don't replay deaths that happened earlier.
			{M0#{last_n := Total, total := Total, by_cause := ByCause, last := latest(Recent)}, []};
		#{last_n := Last0, marks := Old} ->
			New = [Ev || Ev = #{n := N} <- Recent, N > Last0],
			Fresh = [#{ev => Ev, t => Now, respawn => undefined} || Ev <- New],
			Agents = maps:from_list([{Id, Loc} || {Id, _Color, Loc} <- maps:get(agents, Frame, [])]),
			Marks = lists:sublist(link_respawns(Fresh ++ Old, Agents, Now), ?MAX_MARKS),
			Live = [Mk || Mk <- Marks, alive(Mk, Now)],
			{M0#{last_n := Total, marks := Live, total := Total, by_cause := ByCause,
			     last := case Recent of [] -> maps:get(last, M0); _ -> latest(Recent) end},
			 [Id || #{id := Id} <- New]}
	end;
absorb(M, _FrameWithoutDeaths, _Now) ->
	{M, []}.

%% Drops faded markers; used while no new frames arrive (e.g. simulation paused).
-spec prune(marks(), integer()) -> marks().
prune(M = #{marks := Marks}, Now) ->
	M#{marks := [Mk || Mk <- Marks, alive(Mk, Now)]}.

-spec primitives(marks(), integer()) -> [primitive()].
primitives(#{marks := Marks}, Now) ->
	Shapes = lists:flatmap(fun(Mk) -> mark_primitives(Mk, Now) end, Marks),
	Labels = lists:sublist([L || L = {label, _, _, _, _} <- Shapes], ?MAX_LABELS),
	[P || P <- Shapes, element(1, P) =/= label] ++ Labels.

-spec total(marks()) -> non_neg_integer().
total(#{total := Total}) -> Total.

-spec hud_line(marks()) -> string().
hud_line(#{total := Total, by_cause := ByCause, last := Last}) ->
	Causes = [io_lib:format("~s ~p", [cause_text(C), N]) || {C, N} <- lists:sort(maps:to_list(ByCause))],
	LastText = case Last of
		undefined -> "";
		#{type := Type, cause := Cause, age := Age} ->
			io_lib:format("   last: ~p ~s at age ~p", [Type, cause_text(Cause), Age])
	end,
	unicode:characters_to_list(io_lib:format("Deaths: ~p (~s)~s",
		[Total, lists:join(", ", Causes), LastText])).

%%==================================================================== internals

%% Newest marks first; only an agent's most recent death links to where it re-entered.
link_respawns(Marks, Agents, Now) ->
	{Linked, _Seen} = lists:mapfoldl(
		fun(Mk = #{ev := #{id := Id}, respawn := R}, Seen) ->
			Mk1 = case {R, Seen, Agents} of
				{undefined, #{Id := _}, _} -> Mk;
				{undefined, _, #{Id := Loc}} -> Mk#{respawn := {Loc, Now}};
				_ -> Mk
			end,
			{Mk1, Seen#{Id => true}}
		end, #{}, Marks),
	Linked.

alive(#{t := T}, Now) -> Now - T < ?FADE_MS.

mark_primitives(#{ev := #{type := Type, loc := Loc, cause := Cause, age := Age}, t := T, respawn := R}, Now) ->
	Alpha = max(0.0, 1.0 - (Now - T) / ?FADE_MS),
	Color = type_color(Type),
	Respawn = case R of
		undefined -> [];
		{RLoc, RT} ->
			[{link, Color, Loc, RLoc, Alpha}]
			++ [{ring, Color, RLoc, (Now - RT) / ?RING_MS} || Now - RT < ?RING_MS]
	end,
	Text = io_lib:format("~s @~p", [cause_text(Cause), Age]),
	Respawn ++ [{cross, Color, Loc, Alpha}, {label, Color, Loc, Text, Alpha}].

latest([]) -> undefined;
latest([Ev | _]) -> Ev.

type_color(prey) -> blue;
type_color(predator) -> red;
type_color(_) -> black.

cause_key({Cause, _Detail}) -> Cause;
cause_key(Cause) -> Cause.

cause_text(starved) -> "starved";
cause_text(old_age) -> "old age";
cause_text(eaten) -> "eaten";
cause_text({eaten, By}) -> io_lib:format("eaten by ~p", [By]);
cause_text({Cause, Detail}) -> io_lib:format("~p (~p)", [Cause, Detail]);
cause_text(Cause) -> io_lib:format("~p", [Cause]).
