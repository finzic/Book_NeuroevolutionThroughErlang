%% One-call entry points for watching the flatland predator/prey experiment.
%%
%%   sim:start().  database (created if missing) + polis + visor + a new random population
%%   sim:fresh().  stop everything, wipe the whole mnesia database (every genome, specie,
%%                 population and stat), then start again from brand new random genomes
%%   sim:stop().   stop the population and the polis (the visor window stays open)
%%
%% population_monitor:test() always replaces the population 'test' with a fresh random one;
%% fresh/0 additionally throws away everything else that was ever stored.
-module(sim).

-export([start/0, fresh/0, stop/0]).

-define(WAIT_MS, 10000).

start() ->
	case filelib:is_dir(mnesia:system_info(directory)) of
		true -> ok;
		false -> polis:create()
	end,
	ensure_polis(),
	ensure_visor(),
	population_monitor:test().

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
