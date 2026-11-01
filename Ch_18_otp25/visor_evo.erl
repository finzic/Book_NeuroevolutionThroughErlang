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
%%       - a short moving median (last ?SHORT agents): reacts quickly,
%%       - a long moving median (last ?LONG agents): the real trend.
%%       - one dot per finished agent (evenly thinned to ?DOTS), so the chart reads as
%%         individual results and not as a continuous curve.
%%     Medians, not means: a single lucky kill bonus does not move them, so the
%%     y axis stays fitted to typical agents.
%%     The best fitness ever reached is only in the HUD line: as a chart line its rare
%%     outliers squashed the averages to the bottom of the plot. The dashed line is the
%%     median fitness of each species' pool of survivors, the real progress of a
%%     steady-state evolution; like the dots it never sets the y axis.
-module(visor_evo).

-export([new/0, add/5, add/6, add_pool/4, generations_text/2, hud_lines/1, chart/1, total/1]).
-export_type([evo/0, chart/0]).

-type point() :: {number(), number()}.
-type series() :: #{n := non_neg_integer(), points := [point()], first := [number()],
	best := number(), neurons := [non_neg_integer()]}.
-opaque evo() :: #{atom() => series()}.
-type chart() :: #{series := [#{morphology := atom(), short := [point()], long := [point()], dots := [point()], pool := [point()]}],
	x_range := {number(), number()}, y_max := number(), short := pos_integer(), long := pos_integer()}.

-define(KEEP, 5000).
-define(SHORT, 10).
-define(LONG, 50).
-define(CHART_POINTS, 300).
-define(DOTS, 600).

-spec new() -> evo().
new() -> #{}.

%% Evaluations: the population's total evaluations when the agent finished, used as
%% the shared time axis; undefined falls back to the number of reports received.
-spec add(evo(), atom(), number(), non_neg_integer() | undefined, number() | undefined) -> evo().
add(Evo, Morphology, Fitness, Neurons, Evaluations) ->
	add(Evo, Morphology, Fitness, Neurons, Evaluations, undefined).

%% Generation: the finished agent's own generation (mutation steps in its ancestry).
%% The population has no common generation in steady-state evolution, so the HUD shows
%% the highest one reached per morphology.
-spec add(evo(), atom(), number(), non_neg_integer() | undefined, number() | undefined,
	non_neg_integer() | undefined) -> evo().
add(Evo, Morphology, Fitness, Neurons, Evaluations, Generation) when is_number(Fitness) ->
	X = case is_number(Evaluations) of true -> Evaluations; false -> total(Evo) + 1 end,
	S = maps:get(Morphology, Evo, #{n => 0, points => [], first => [], best => Fitness, neurons => []}),
	#{n := N, points := Points, first := First, best := Best, neurons := Ns} = S,
	Evo#{Morphology => S#{
		gen => case Generation of
			G when is_integer(G) -> max(G, maps:get(gen, S, 0));
			_ -> maps:get(gen, S, undefined)
		end,
		n := N + 1,
		points := lists:sublist([{X, Fitness} | Points], ?KEEP),
		first := case length(First) < ?SHORT of true -> First ++ [Fitness]; false -> First end,
		best := max(Best, Fitness),
		neurons := case Neurons of undefined -> Ns; _ -> lists:sublist([Neurons | Ns], ?SHORT) end}};
add(Evo, _Morphology, _Fitness, _Neurons, _Evaluations, _Generation) ->
	Evo.

%% The median fitness in the morphology's pool of survivors, at the given evaluation count.
%% Ignored until the morphology has reported a finished agent.
-spec add_pool(evo(), atom(), number(), number() | undefined) -> evo().
add_pool(Evo, Morphology, Best, Evaluations) when is_number(Best), is_number(Evaluations) ->
	case Evo of
		#{Morphology := S} ->
			Evo#{Morphology := S#{pool => lists:sublist([{Evaluations, Best} | maps:get(pool, S, [])], ?KEEP)}};
		_ ->
			Evo
	end;
add_pool(Evo, _Morphology, _Best, _Evaluations) ->
	Evo.

%% "prey 143, predator 97"; the population's own generation (generational algorithm)
%% when there is one, "-" when nothing is known yet.
-spec generations_text(evo(), term()) -> string().
generations_text(Evo, PopulationGeneration) ->
	Gens = [{M, G} || {M, #{gen := G}} <- lists:sort(maps:to_list(Evo)), is_integer(G)],
	case {Gens, PopulationGeneration} of
		{[], undefined} -> "-";
		{[], G} -> io_lib:format("~p", [G]);
		_ -> lists:join(", ", [io_lib:format("~p ~p", [M, G]) || {M, G} <- Gens])
	end.

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
	Series = [series(M, lists:reverse(Points), lists:reverse(maps:get(pool, S, []))) ||
		{M, #{points := Points} = S} <- lists:sort(maps:to_list(Evo)), length(Points) >= 2],
	case Series of
		[] ->
			undefined;
		_ ->
			Xs = [X || #{short := Sh} <- Series, {X, _} <- Sh],
			Ys = [Y || #{short := Sh, long := Lo} <- Series, {_, Y} <- Sh ++ Lo],
			%Dots above the axis (rare lucky agents) are drawn clamped at the top edge,
			%so the axis fits the typical agents: 95th percentile of the dots at most.
			DotYs = lists:sort([Y || #{dots := Ds} <- Series, {_, Y} <- Ds]),
			Typical = lists:nth(max(1, ceil(0.95 * length(DotYs))), DotYs),
			#{series => Series, x_range => {lists:min(Xs), max(lists:max(Xs), lists:min(Xs) + 1)},
			  y_max => lists:max([0.001, Typical | Ys]), short => ?SHORT, long => ?LONG}
	end.

%% The chart is rebuilt on every repaint, so medians are computed only at the
%% (at most ?CHART_POINTS + 1) indices that get plotted.
series(Morphology, Points, Pool) ->
	T = list_to_tuple(Points),
	Is = sample_indices(tuple_size(T)),
	PT = list_to_tuple(Pool),
	#{morphology => Morphology,
	  pool => [element(I, PT) || I <- sample_indices(tuple_size(PT))],
	  short => [{element(1, element(I, T)), median_at(T, I, ?SHORT)} || I <- Is],
	  long => [{element(1, element(I, T)), median_at(T, I, ?LONG)} || I <- Is],
	  dots => [element(I, T) || I <- sample_indices(tuple_size(T), ?DOTS)]}.

%% Median fitness of the Window points ending at index I (fewer at the start).
median_at(T, I, Window) ->
	Fs = lists:sort([element(2, element(J, T)) || J <- lists:seq(max(1, I - Window + 1), I)]),
	N = length(Fs),
	case N rem 2 of
		1 -> lists:nth(N div 2 + 1, Fs);
		0 -> (lists:nth(N div 2, Fs) + lists:nth(N div 2 + 1, Fs)) / 2
	end.

sample_indices(N) ->
	sample_indices(N, ?CHART_POINTS).

sample_indices(N, Max) when N =< Max ->
	lists:seq(1, N);
sample_indices(N, Max) ->
	Step = N / Max,
	lists:usort([min(N, 1 + trunc(I * Step)) || I <- lists:seq(0, Max - 1)] ++ [N]).

avg([]) -> 0.0;
avg(Xs) -> lists:sum(Xs) / length(Xs).
