%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% Genome inspector model for the visor: turns an agent's genotype (mnesia) into a
%% plain graph map the view can draw. Selections:
%%   {best, Morphology} - the fittest agent of that morphology (live or in the dead pool)
%%   {pid, ExoselfPid}  - the avatar clicked in the scape (avatar id == exoself pid)
%%   {agent, AgentId}   - a fixed agent, kept while it exists in the database
%% fetch/1 may block on mnesia and on the population_monitor, so the controller runs
%% it in a throw-away process (fetch_async/3) and never waits for it.
-module(visor_genome).
-include("records.hrl").

-export([fetch/1, fetch_async/3, graph/1, best/1]).
-export_type([selection/0, result/0, graph/0]).

-type selection() :: {best, atom()} | {pid, pid()} | {agent, term()}.
-type node_kind() :: sensor | neuron | actuator.
-type graph() :: #{agent_id := term(), morphology := atom(), generation := term(),
	fitness := number() | undefined,
	nodes := [#{id := term(), kind := node_kind(), layer := number(), name := string(), label := string(),
		details := [string()]}],
	edges := [#{from := term(), to := term(), weight := number() | undefined, weights := [number()],
		recurrent := boolean()}]}.
-type result() :: #{sel := selection(), title := string(), graph => graph(),
	pid => pid() | undefined, error => string()}.

-spec fetch_async(pid(), reference(), selection()) -> pid().
fetch_async(ReplyTo, Ref, Sel) ->
	spawn(fun() ->
		Result = try fetch(Sel)
			catch Class:Reason -> #{sel => Sel, title => title(Sel), error => fmt("~p:~p", [Class, Reason])}
			end,
		ReplyTo ! {genome_fetched, Ref, Result}
	end).

-spec fetch(selection()) -> result().
fetch({pid, Pid} = Sel) ->
	Active = population_monitor:active_agents(),
	case lists:keyfind(Pid, 2, Active) of
		{AgentId, Pid} -> with_graph({agent, AgentId}, AgentId, Pid);
		false -> #{sel => Sel, title => title(Sel), error => "not an evolving agent (or already gone)"}
	end;
fetch({best, Morphology} = Sel) ->
	case best(Morphology) of
		undefined -> #{sel => Sel, title => title(Sel), error => "no evaluated agent yet"};
		AgentId -> with_graph(Sel, AgentId, live_pid(AgentId))
	end;
fetch({agent, AgentId} = Sel) ->
	with_graph(Sel, AgentId, live_pid(AgentId)).

with_graph(Sel, AgentId, Pid) ->
	case graph(AgentId) of
		{ok, G} -> #{sel => Sel, title => title(Sel), graph => G, pid => Pid};
		{error, Why} -> #{sel => Sel, title => title(Sel), error => Why, pid => Pid}
	end.

live_pid(AgentId) ->
	case lists:keyfind(AgentId, 1, population_monitor:active_agents()) of
		{AgentId, Pid} -> Pid;
		false -> undefined
	end.

title({best, Morphology}) -> fmt("Genome of the best ~p", [Morphology]);
title({pid, _}) -> "Genome of the clicked agent";
title({agent, _}) -> "Genome of the clicked agent".

%% The agent of Morphology with the highest fitness among all its species' agents
%% (agent_ids also holds the dead pool, i.e. the parents of the current agents).
-spec best(atom()) -> term() | undefined.
best(Morphology) ->
	Agents = [A || SpecieId <- mnesia:dirty_all_keys(specie),
		#specie{constraint = #constraint{morphology = M}, agent_ids = Ids} <- mnesia:dirty_read(specie, SpecieId),
		M == Morphology,
		Id <- Ids,
		A = #agent{} <- mnesia:dirty_read(agent, Id)],
	Scored = [{fitness(A#agent.fitness), A#agent.id} || A <- Agents, is_number(fitness(A#agent.fitness))],
	case lists:reverse(lists:sort(Scored)) of
		[{_, Id} | _] -> Id;
		[] -> undefined
	end.

-spec graph(term()) -> {ok, graph()} | {error, string()}.
graph(AgentId) ->
	case mnesia:dirty_read(agent, AgentId) of
		[A = #agent{cx_id = CxId}] ->
			case mnesia:dirty_read(cortex, CxId) of
				[Cx] -> {ok, build(A, Cx)};
				[] -> {error, "genome is being rewritten (mutation)"}
			end;
		[] ->
			{error, "agent deleted from the population"}
	end.

build(A, Cx) ->
	Sensors = read_all(sensor, Cx#cortex.sensor_ids),
	Neurons = read_all(neuron, Cx#cortex.neuron_ids),
	Actuators = read_all(actuator, Cx#cortex.actuator_ids),
	%Neurons are named n1, n2, ... in layer order so the hover details can refer to them.
	Sorted = lists:sort(fun(A1, A2) -> {layer(A1#neuron.id), A1#neuron.id} =< {layer(A2#neuron.id), A2#neuron.id} end, Neurons),
	Names = maps:from_list(
		[{S#sensor.id, sensor_label(S)} || S <- Sensors]
		++ [{N#neuron.id, "n" ++ integer_to_list(I)} || {I, N} <- lists:zip(lists:seq(1, length(Sorted)), Sorted)]
		++ [{Ac#actuator.id, atom_label(Ac#actuator.name)} || Ac <- Actuators]),
	Name = fun(Id) -> maps:get(Id, Names, "?") end,
	Nodes = [#{id => S#sensor.id, kind => sensor, layer => -1, name => Name(S#sensor.id), label => Name(S#sensor.id),
			details => [fmt("sensor ~p: ~p readings per step, one per ray: ~s", [S#sensor.name, S#sensor.vl,
					lists:join(" ", ray_labels(S#sensor.vl))]),
				fmt("feeds: ~s", [names(Name, S#sensor.fanout_ids)])]} || S <- Sensors]
		++ [#{id => N#neuron.id, kind => neuron, layer => layer(N#neuron.id), name => Name(N#neuron.id),
			label => Name(N#neuron.id) ++ " " ++ atom_label(N#neuron.af),
			details => neuron_details(N, Name)} || N <- Sorted]
		++ [#{id => Ac#actuator.id, kind => actuator, layer => 1, name => Name(Ac#actuator.id), label => Name(Ac#actuator.id),
			details => [fmt("actuator ~p: ~p outputs per step", [Ac#actuator.name, Ac#actuator.vl]),
				fmt("driven by: ~s", [names(Name, Ac#actuator.fanin_ids)])]} || Ac <- Actuators],
	Known = maps:from_list([{maps:get(id, Nd), maps:get(layer, Nd)} || Nd <- Nodes]),
	InEdges = [#{from => From, to => N#neuron.id, weight => mean_weight(WeightsP), weights => weights(WeightsP),
			recurrent => maps:get(From, Known) >= layer(N#neuron.id)}
		|| N <- Neurons, {From, WeightsP} <- N#neuron.input_idps, is_map_key(From, Known)],
	OutEdges = [#{from => N#neuron.id, to => To, weight => undefined, weights => [], recurrent => false}
		|| N <- Neurons, To = {_, actuator} <- N#neuron.output_ids, is_map_key(To, Known)],
	#{agent_id => A#agent.id,
	  morphology => (A#agent.constraint)#constraint.morphology,
	  generation => A#agent.generation,
	  fitness => fitness(A#agent.fitness),
	  nodes => Nodes,
	  edges => InEdges ++ OutEdges}.

%% Dirty reads may race a mutation; missing records are simply left out.
read_all(Table, Ids) ->
	[R || Id <- Ids, R <- mnesia:dirty_read(Table, Id)].

neuron_details(N, Name) ->
	{PF, _} = case N#neuron.pf of {_, _} = P -> P; P -> {P, []} end,
	[fmt("neuron ~s   activation ~s   aggregation ~s   plasticity ~s",
		[Name(N#neuron.id), atom_label(N#neuron.af), atom_label(N#neuron.aggr_f), atom_label(PF)])
	 | [case From of
			bias -> fmt("  bias ~s", [weights_text(weights(WeightsP))]);
			{_, sensor} -> fmt("  in  from ~s: ~s", [Name(From), ray_weights_text(weights(WeightsP))]);
			_ -> fmt("  in  from ~s~s: ~s", [Name(From), recurrent_tag(From, N#neuron.id), weights_text(weights(WeightsP))])
		end || {From, WeightsP} <- N#neuron.input_idps]]
	++ [fmt("  out to ~s", [names(Name, N#neuron.output_ids)])].

recurrent_tag({_, neuron} = From, To) ->
	case layer(From) >= layer(To) of
		true -> " (recurrent)";
		false -> ""
	end;
recurrent_tag(_From, _To) ->
	"".

names(Name, Ids) -> lists:join(", ", [Name(Id) || Id <- Ids]).

weights(WeightsP) -> [W || {W, _PlasticityParams} <- WeightsP, is_number(W)].

weights_text(Ws) -> lists:join(" ", [signed(W) || W <- Ws]).

%Scanner readings come ordered from the rightmost ray to the leftmost (sensor:create_UnitRays/5
%builds them left to right, then they are reversed); flatland's scanners fan 5 rays 18 degrees apart.
ray_labels(5) -> ["R36", "R18", "ahead", "L18", "L36"];
ray_labels(N) -> ["#" ++ integer_to_list(I) || I <- lists:seq(1, N)].

ray_weights_text(Ws) ->
	lists:join(" ", [[Label, ":", signed(W)] || {Label, W} <- lists:zip(ray_labels(length(Ws)), Ws)]).

signed(W) when W >= 0 -> io_lib:format("+~.2f", [float(W)]);
signed(W) -> io_lib:format("~.2f", [float(W)]).

layer({{LayerIndex, _}, _}) when is_number(LayerIndex) -> LayerIndex;
layer(_) -> 0.

mean_weight(WeightsP) ->
	Ws = [W || {W, _PlasticityParams} <- WeightsP, is_number(W)],
	case Ws of
		[] -> 0.0;
		_ -> lists:sum(Ws) / length(Ws)
	end.

fitness(F) when is_number(F) -> F;
fitness([_ | _] = Fs) -> case lists:all(fun is_number/1, Fs) of true -> lists:sum(Fs); false -> undefined end;
fitness(_) -> undefined.

sensor_label(#sensor{name = Name, vl = VL}) -> fmt("~s x~p", [atom_label(Name), VL]).

atom_label(distance_scanner) -> "distance";
atom_label(color_scanner) -> "colour";
atom_label(threat_scanner) -> "threat";
atom_label(A) when is_atom(A) -> atom_to_list(A);
atom_label({A, _}) when is_atom(A) -> atom_to_list(A);
atom_label(Other) -> fmt("~p", [Other]).

fmt(Format, Args) ->
	unicode:characters_to_list(io_lib:format(Format, Args)).
