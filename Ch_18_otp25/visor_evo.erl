%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% Evolution progress as the visor shows it (pure functions, no wx).
%%
%% The population_monitor reports every agent that finishes its evaluations (its
%% best fitness over all its attempts, its neuron count and the population's total
%% evaluations so far) through visor:notify/1. Here those reports are kept per
%% morphology (prey, predator, ...) so the visor can show whether each species is
%% improving:
%%   * HUD lines comparing the first agents with the latest ones,
%%   * a chart where all species share one time axis (population evaluations), so
%%     the predator/prey arms race can be read side by side, with per species
%%       - a short moving average (last ?SHORT agents): noisy, reacts quickly,
%%       - a long moving average (last ?LONG agents): the real trend,
%%       - the best fitness ever reached (a step line that never goes down).
-module(visor_evo).

-export([new/0, add/5, hud_lines/1, chart/1, total/1]).
-export_type([evo/0, chart/0]).

-type point() :: {number(), number()}.
-type series() :: #{n := non_neg_integer(), points := [point()], first := [number()],
	best := number(), neurons := [non_neg_integer()]}.
-opaque evo() :: #{atom() => series()}.
-type chart() :: #{series := [#{morphology := atom(), short := [point()], long := [point()], best := [point()]}],
	x_range := {number(), number()}, y_max := number(), short := pos_integer(), long := pos_integer()}.

-define(KEEP, 5000).
-define(SHORT, 10).
-define(LONG, 50).
-define(CHART_POINTS, 300).

-spec new() -> evo().
new() -> #{}.

%% Evaluations: the population's total evaluations when the agent finished, used as
%% the shared time axis; undefined falls back to the number of reports received.
-spec add(evo(), atom(), number(), non_neg_integer() | undefined, number() | undefined) -> evo().
add(Evo, Morphology, Fitness, Neurons, Evaluations) when is_number(Fitness) ->
	X = case is_number(Evaluations) of true -> Evaluations; false -> total(Evo) + 1 end,
	S = maps:get(Morphology, Evo, #{n => 0, points => [], first => [], best => Fitness, neurons => []}),
	#{n := N, points := Points, first := First, best := Best, neurons := Ns} = S,
	Evo#{Morphology => S#{
		n := N + 1,
		points := lists:sublist([{X, Fitness} | Points], ?KEEP),
		first := case length(First) < ?SHORT of true -> First ++ [Fitness]; false -> First end,
		best := max(Best, Fitness),
		neurons := case Neurons of undefined -> Ns; _ -> lists:sublist([Neurons | Ns], ?SHORT) end}};
add(Evo, _Morphology, _Fitness, _Neurons, _Evaluations) ->
	Evo.

-spec total(evo()) -> non_neg_integer().
total(Evo) ->
	lists:sum([N || #{n := N} <- maps:values(Evo)]).

-spec hud_lines(evo()) -> [string()].
hud_lines(Evo) ->
	[line(M, S) || {M, S} <- lists:sort(maps:to_list(Evo))].

line(Morphology, #{n := N, points := Points, first := First, best := Best, neurons := Ns}) ->
	Fits = [F || {_, F} <- Points],
	Recent = lists:sublist(Fits, ?SHORT),
	Long = lists:sublist(Fits, ?LONG),
	NeuronText = case Ns of [] -> ""; _ -> io_lib:format("  neurons ~.1f", [avg(Ns)]) end,
	unicode:characters_to_list(io_lib:format(
		"~p: ~p finished  fitness first ~p avg ~.2f -> last ~p avg ~.2f, last ~p avg ~.2f  best ~.2f~s",
		[Morphology, N, length(First), avg(First), length(Recent), avg(Recent),
		 length(Long), avg(Long), float(Best), NeuronText])).

-spec chart(evo()) -> chart() | undefined.
chart(Evo) ->
	Series = [series(M, lists:reverse(Points)) || {M, #{points := Points}} <- lists:sort(maps:to_list(Evo)),
		length(Points) >= 2],
	case Series of
		[] ->
			undefined;
		_ ->
			Xs = [X || #{best := B} <- Series, {X, _} <- B],
			Ys = [Y || #{short := Sh, best := B} <- Series, {_, Y} <- Sh ++ B],
			#{series => Series, x_range => {lists:min(Xs), max(lists:max(Xs), lists:min(Xs) + 1)},
			  y_max => lists:max([0.001 | Ys]), short => ?SHORT, long => ?LONG}
	end.

series(Morphology, Points) ->
	#{morphology => Morphology,
	  short => decimate(moving_avg(Points, ?SHORT)),
	  long => decimate(moving_avg(Points, ?LONG)),
	  best => decimate(running_max(Points))}.

moving_avg(Points, Window) ->
	moving_avg(Points, Window, queue:new(), 0, 0.0, []).
moving_avg([], _W, _Q, _Len, _Sum, Acc) ->
	lists:reverse(Acc);
moving_avg([{X, F} | Ps], W, Q, Len, Sum, Acc) when Len >= W ->
	{{value, Old}, Q1} = queue:out(Q),
	Sum1 = Sum - Old + F,
	moving_avg(Ps, W, queue:in(F, Q1), Len, Sum1, [{X, Sum1 / Len} | Acc]);
moving_avg([{X, F} | Ps], W, Q, Len, Sum, Acc) ->
	moving_avg(Ps, W, queue:in(F, Q), Len + 1, Sum + F, [{X, (Sum + F) / (Len + 1)} | Acc]).

%% Step line of the best fitness so far, extended to the latest point.
running_max([{X0, F0} | Ps]) ->
	{Best, Acc} = lists:foldl(
		fun({X, F}, {Max, Acc}) when F > Max -> {F, [{X, F}, {X, Max} | Acc]};
		   (_, MaxAcc) -> MaxAcc
		end, {F0, [{X0, F0}]}, Ps),
	{LastX, _} = lists:last([{X0, F0} | Ps]),
	lists:reverse([{LastX, Best} | Acc]).

decimate(Ps) when length(Ps) =< ?CHART_POINTS ->
	Ps;
decimate(Ps) ->
	Step = length(Ps) / ?CHART_POINTS,
	T = list_to_tuple(Ps),
	[element(min(tuple_size(T), 1 + trunc(I * Step)), T) || I <- lists:seq(0, ?CHART_POINTS - 1)] ++ [lists:last(Ps)].

avg([]) -> 0.0;
avg(Xs) -> lists:sum(Xs) / length(Xs).
