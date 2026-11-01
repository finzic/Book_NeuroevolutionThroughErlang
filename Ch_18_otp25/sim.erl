%% One-call entry points for watching the flatland predator/prey experiment.
%%
%%   sim:start().  database (created if missing) + polis + visor + a new random population
%%   sim:fresh().  stop everything, wipe the whole mnesia database (every genome, specie,
%%                 population and stat), then start again from brand new random genomes
%%   sim:continue().  carry on evolving the existing (evolved) population for another
%%                    100000 evaluations; sim:continue(N) for N more, or infinity
%%   sim:stop().   stop the population and the polis (the visor window stays open)
%%   sim:quit().   stop the simulation, close the visor and leave Erlang (key X)
%%   sim:logs().   toggle the simulation's console output on/off (key V); off is faster
%%
%% population_monitor:test() always replaces the population 'test' with a fresh random one;
%% fresh/0 additionally throws away everything else that was ever stored.
-module(sim).

-export([start/0, fresh/0, continue/0, continue/1, stop/0, quit/0, logs/0]).

-define(POPULATION, test).
-define(MORE_EVALUATIONS, 100000).

-define(WAIT_MS, 10000).

start() ->
	case filelib:is_dir(mnesia:system_info(directory)) of
		true -> ok;
		false -> polis:create()
	end,
	%% Everything started from here prints through the switchable sim_log gate.
	sim_log:with(fun ensure_polis/0),
	ensure_visor(),
	sim_log:with(fun() -> population_monitor:test() end).

continue() ->
	continue(?MORE_EVALUATIONS).

continue(MoreEvaluations) ->
	case whereis(monitor) of
		undefined -> ok;
		_ -> stop()
	end,
	%% Everything started from here prints through the switchable sim_log gate.
	sim_log:with(fun ensure_polis/0),
	ensure_visor(),
	sim_log:with(fun() -> population_monitor:continue(?POPULATION, MoreEvaluations) end).

fresh() ->
	stop(),
	{atomic, ok} = polis:reset(),
	io:format("~n######## database wiped: starting from new random genomes ########~n~n"),
	start().

stop() ->
	case whereis(monitor) of
		undefined -> ok;
		Monitor ->
			%% The synchronous stop also tells every running agent to terminate.
			catch gen_server:call(Monitor, {stop, normal}, ?WAIT_MS),
			wait_gone(monitor)
	end,
	case whereis(polis) of
		undefined -> ok;
		_ ->
			polis:stop(),
			wait_gone(polis)
	end,
	ok.

%% Stop the evolution cleanly, close the windows, then stop the Erlang node.
quit() ->
	io:format("~n######## quitting: stopping the simulation ########~n"),
	stop(),
	case whereis(visor) of
		undefined -> ok;
		_ -> catch visor:stop(), wait_gone(visor)
	end,
	init:stop().

logs() ->
	State = case sim_log:toggle() of true -> on; false -> off end,
	io:format("simulation logs ~p~n", [State]),
	State.

ensure_polis() ->
	case whereis(polis) of
		undefined -> {ok, _} = polis:start(), ok;
		_ -> ok
	end.

ensure_visor() ->
	case whereis(visor) of
		undefined -> {ok, _} = visor:start(), ok;
		_ -> ok
	end.

wait_gone(Name) ->
	wait_gone(Name, ?WAIT_MS div 50).
wait_gone(Name, 0) ->
	case whereis(Name) of
		undefined -> ok;
		Pid -> exit(Pid, kill), timer:sleep(100)
	end;
wait_gone(Name, N) ->
	case whereis(Name) of
		undefined -> ok;
		_ -> timer:sleep(50), wait_gone(Name, N - 1)
	end.
