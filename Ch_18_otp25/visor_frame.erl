%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% The "M -> V" channel of the visor MVC.
%%
%% A scape (the model) owns a protected ETS table holding exactly one row: the
%% latest render-ready frame. The scape overwrites that row at most MaxHz times per
%% second, and the visor (controller) reads it on its own clock. Because the slot is
%% latest-value-wins, frames are dropped rather than queued: however fast the
%% simulation runs, the display can never fall behind it, and the scape never blocks
%% on, or sends messages to, the GUI.
-module(visor_frame).
-include("records.hrl").

-export([new/0, delete/1, latest/1]).
-export([publisher/2, maybe_publish/2, publish_now/2, retire/1]).
-export([from_avatars/2, bounds/1]).

-export_type([frame/0, shape/0, agent/0, publisher/0]).

-type color() :: atom().
-type point() :: {number(), number()}.
-type shape() :: {circle, color(), point(), number()}
	| {line, color(), [point()]}
	| {arrow, color(), [point()]}
	| {polygon, color(), [point()]}.
-type agent() :: {Id :: term(), color(), point()}.
-type frame() :: #{shapes := [shape()],
	agents := [agent()],
	bounds := {number(), number(), number(), number()} | undefined,
	counts := #{atom() => non_neg_integer()},
	stats := map(),
	deaths => visor_deaths:log(),
	published_at => integer()}.
-opaque publisher() :: #{tab := ets:tid(),
	period := integer(),
	last := integer() | undefined,
	seq := non_neg_integer()}.

-define(KEY, latest).

%%==================================================================== channel

-spec new() -> ets:tid().
new() ->
	ets:new(?MODULE, [set, protected, {read_concurrency, true}]).

-spec delete(ets:tid()) -> ok.
delete(Tab) ->
	try ets:delete(Tab) catch error:badarg -> ok end,
	ok.

%% Called by the reader. 'gone' means the owning scape (and its table) died.
-spec latest(ets:tid()) -> {ok, pos_integer(), frame()} | empty | gone.
latest(Tab) ->
	try ets:lookup(Tab, ?KEY) of
		[{?KEY, Seq, Frame}] -> {ok, Seq, Frame};
		[] -> empty
	catch
		error:badarg -> gone
	end.

%%==================================================================== writer side

-spec publisher(ets:tid(), pos_integer()) -> publisher().
publisher(Tab, MaxHz) when is_integer(MaxHz), MaxHz > 0 ->
	Period = erlang:convert_time_unit(1, second, native) div MaxHz,
	#{tab => Tab, period => Period, last => undefined, seq => 0}.

%% Cheap when throttled: a single monotonic clock read. BuildFun is only evaluated
%% when a frame is actually going to be published.
-spec maybe_publish(publisher(), fun(() -> frame())) -> publisher().
maybe_publish(#{period := Period, last := Last} = Pub, BuildFun) ->
	Now = erlang:monotonic_time(),
	case Last =:= undefined orelse Now - Last >= Period of
		true -> publish(Pub, BuildFun, Now);
		false -> Pub
	end.

-spec publish_now(publisher(), fun(() -> frame())) -> publisher().
publish_now(Pub, BuildFun) ->
	publish(Pub, BuildFun, erlang:monotonic_time()).

-spec retire(publisher()) -> ok.
retire(#{tab := Tab}) ->
	delete(Tab).

publish(#{tab := Tab, seq := Seq} = Pub, BuildFun, Now) ->
	U_Seq = Seq + 1,
	Frame = (BuildFun())#{published_at => erlang:monotonic_time(millisecond)},
	try ets:insert(Tab, {?KEY, U_Seq, Frame}) catch error:badarg -> ok end,
	Pub#{last := Now, seq := U_Seq}.

%%==================================================================== frame building

%% Translates the scape's avatar objects into a flat, wx-agnostic display list.
%% Static scenery is emitted first so agents are always painted on top of it.
-spec from_avatars([#avatar{}], map()) -> frame().
from_avatars(Avatars, Stats) ->
	Sorted = lists:sort(fun(A, B) -> layer(A) =< layer(B) end, Avatars),
	Shapes = [Shape || A <- Sorted, Obj <- objects(A), Shape <- to_shape(Obj)],
	Counts = lists:foldl(
		fun(#avatar{type = T}, Acc) -> maps:update_with(T, fun(N) -> N + 1 end, 1, Acc) end,
		#{}, Avatars),
	Agents = [{Id, color(A), Loc} || A = #avatar{id = Id, loc = {X, Y} = Loc} <- Avatars,
		layer(A) == 2, is_number(X), is_number(Y)],
	#{shapes => Shapes, agents => Agents, bounds => bounds(Shapes), counts => Counts, stats => Stats}.

layer(#avatar{type = T}) when T == wall; T == rock; T == pillar; T == fire_pit -> 0;
layer(#avatar{type = T}) when T == plant; T == poison -> 1;
layer(_) -> 2.

color(A) ->
	case [C || {_Kind, _Id, C, _Pivot, _Coords, _P} <- objects(A)] of
		[C | _] -> C;
		[] -> black
	end.

objects(#avatar{objects = Objects}) when is_list(Objects) -> Objects;
objects(_) -> [].

to_shape({circle, _Id, Color, _Pivot, [{X, Y}], R}) when is_number(R) -> [{circle, Color, {X, Y}, R}];
to_shape({line, _Id, Color, _Pivot, Coords, _}) -> [{line, Color, Coords}];
to_shape({arrow, _Id, Color, _Pivot, Coords, _}) -> [{arrow, Color, Coords}];
to_shape({polygon, _Id, Color, _Pivot, Coords, _}) -> [{polygon, Color, Coords}];
to_shape(_Unknown) -> [].

-spec bounds([shape()]) -> {number(), number(), number(), number()} | undefined.
bounds(Shapes) ->
	lists:foldl(fun extend/2, undefined, Shapes).

extend({circle, _, {X, Y}, R}, Acc) ->
	grow({X + R, Y + R}, grow({X - R, Y - R}, Acc));
extend({_, _, Coords}, Acc) ->
	lists:foldl(fun grow/2, Acc, Coords).

grow({X, Y}, undefined) -> {X, Y, X, Y};
grow({X, Y}, {X0, Y0, X1, Y1}) -> {min(X, X0), min(Y, Y0), max(X, X1), max(Y, Y1)}.
