%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% The visor: a wx based viewer for the flatland scape, structured as Erlang MVC.
%%
%%   Model      - the scape (flatland.erl). It owns the world and, while a visor is
%%                subscribed, publishes throttled render-ready frames through
%%                visor_frame (a single latest-value-wins ETS slot).
%%   View       - visor_view.erl. Stateless: render(DC, Size, Scene, Resources).
%%   Controller - this module, a wx_object. It owns all GUI state (camera, toggles,
%%                rate meters), turns keyboard, mouse and API requests into
%%                command/2 calls, and pulls the newest frame on its own clock.
%%
%% Why the display never lags: the scape never sends frames as messages, so there is
%% no queue to fall behind on. On each tick the controller reads only the newest
%% frame and asks wx to repaint once; wx coalesces repaints, and the next tick is
%% armed before work starts, so at most one tick message is ever pending. If the
%% simulation outruns the screen, intermediate frames are skipped, never delayed.
%% User commands go to the same small mailbox and are applied immediately.
%%
%% Watch speed: to make the agents' behaviour intelligible the visor asks the scape
%% to pace its agents (see visor_pace) to a number of steps per second per agent,
%% 20 by default. Pausing really pauses the simulation. Use speed 'max' (key M) to
%% let evolution run flat out; closing the visor always restores full speed.
%%
%% Deaths: each death is marked by a fading cross (blue prey, red predator) with
%% its cause and age; when the agent re-enters the scape for its next evaluation a
%% dashed line leads to where it reappeared (see visor_deaths).
%%
%% Shell usage:
%%   visor:start().                        % follow the polis' flatland scape
%%   visor:start(#{scape => Pid, speed => 20 | max, fps => 60, publish_hz => 60}).
%%   visor:speed(5). visor:speed(max). visor:pause(). visor:trails(). visor:deaths().
%%   visor:zo(). visor:zo({Zoom,PanX,PanY}). visor:fit(). visor:legend().
%%   visor:hud(). visor:freeze(). visor:stats(). visor:stop().
%% Keys: , . (or [ ]) slower/faster, M max speed on/off, Space/P pause simulation,
%%       T trails, D death markers, C fitness chart, arrows/drag pan, wheel or +/- zoom, F fit, L legend, H hud,
%%       Z freeze display only, V simulation console logs on/off (off is faster),
%%       Q/Esc close this window only, X quit everything (simulation, windows and Erlang).
%%       G genome window: best prey -> best predator -> closed. Clicking a prey/predator shows its genome.
%%
%% Genome window: a separate wx_object (visor_genome_win) draws the selected agent's
%% neural network; it reads mnesia through throw-away processes, so neither window
%% ever waits for the database. The agent it shows is ringed in yellow in the arena.
-module(visor).
-behaviour(wx_object).
-include_lib("wx/include/wx.hrl").

-export([start/0, start/1, stop/0]).
-export([speed/1, pause/0, trails/0, deaths/0, chart/0, genome/0, genome/1]).
-export([zo/0, zo/1, fit/0, legend/0, hud/0, freeze/0, fps/1, stats/0, notify/1]).
-export([ct2color/1, ct_legend/0]).
-export([init/1, handle_event/2, handle_sync_event/3, handle_call/3, handle_cast/2,
	handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(WIDTH, 1440).
-define(HEIGHT, 900).
-define(INIT_SCAPE_TYPE, flatland).
-define(DEFAULT_FPS, 30).
-define(DEFAULT_PUBLISH_HZ, 60).
-define(RECONNECT_MS, 1000).
-define(SUBSCRIBE_TIMEOUT, 2000).
-define(METER_WINDOW_MS, 1000).
-define(PAN_STEP, 60).
-define(ZOOM_STEP, 1.25).
-define(DEFAULT_SPEED, 20).
-define(SPEEDS, [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]).
-define(TRAIL_LEN, 60).
-define(CLICK_PX, 4).
-define(PICK_PX, 18).

-record(state, {
	frame,
	canvas,
	res,
	source,
	scape,
	scape_mon,
	tab,
	fps,
	publish_hz,
	seq = 0,
	snapshot,
	camera,
	auto_fit = true,
	hud = true,
	legend = false,
	frozen = false,
	speed,
	watch_speed,
	sim_paused = false,
	show_trails = true,
	trails = #{},
	show_deaths = true,
	evo = visor_evo:new(),
	show_chart = true,
	deaths = visor_deaths:new_marks(),
	drag,
	press,
	genome_win,
	genome_mon,
	genome_pid,
	logs = true,
	info = #{},
	meter
}).

%%==================================================================== API

start() ->
	start(#{}).

%% Opts: scape => pid() | ScapeType :: atom()  (default flatland, resolved via polis)
%%       fps => FramesPerSecond                (default 30)
%%       publish_hz => MaxFramesTheScapeBuilds (default 60)
%%       speed => StepsPerSecondPerAgent | max (default 20)
start(Opts) when is_map(Opts) ->
	case wx_object:start({local, ?SERVER}, ?MODULE, Opts, []) of
		{error, _} = Error -> Error;
		Obj -> {ok, wx_object:get_pid(Obj)}
	end.

stop() -> cast(stop).

zo() -> zo({0.2, 200, 200}).
zo({Zoom, PanX, PanY} = Filter) when is_number(Zoom), Zoom > 0, is_number(PanX), is_number(PanY) ->
	cast({command, {filter, Filter}}).

%% Agent steps per second (per agent), or max for the unthrottled simulation.
speed(max) -> cast({command, {speed, max}});
speed(N) when is_integer(N), N > 0 -> cast({command, {speed, N}}).
pause() -> cast({command, toggle_pause}).
trails() -> cast({command, toggle_trails}).
deaths() -> cast({command, toggle_deaths}).
chart() -> cast({command, toggle_chart}).
%% genome() cycles best prey -> best predator -> off; genome(Sel) picks one directly.
genome() -> cast({command, cycle_genome}).
genome(off) -> cast({command, close_genome});
genome(Morphology) when Morphology == prey; Morphology == predator -> cast({command, {genome, {best, Morphology}}});
genome(AgentId) -> cast({command, {genome, {agent, AgentId}}}).

fit() -> cast({command, fit}).
legend() -> cast({command, toggle_legend}).
hud() -> cast({command, toggle_hud}).
freeze() -> cast({command, toggle_freeze}).
fps(Fps) when is_integer(Fps), Fps > 0, Fps =< 240 -> cast({fps, Fps}).

stats() ->
	case whereis(?SERVER) of
		undefined -> {error, not_running};
		Pid -> wx_object:call(Pid, stats)
	end.

%% Fire-and-forget hook for other processes (e.g. population_monitor) to show
%% evolution progress in the HUD. Never blocks and is a no-op without a visor.
notify(Info) when is_map(Info) ->
	case whereis(?SERVER) of
		undefined -> ok;
		Pid -> Pid ! {visor_notify, Info}, ok
	end.

cast(Msg) ->
	case whereis(?SERVER) of
		undefined -> {error, not_running};
		Pid -> wx_object:cast(Pid, Msg)
	end.

%%==================================================================== wx_object callbacks

init(Opts) ->
	wx:new(),
	Frame = wxFrame:new(wx:null(), ?wxID_ANY, "Visor", [{size, {?WIDTH, ?HEIGHT}}]),
	Canvas = wxPanel:new(Frame, [{style, ?wxFULL_REPAINT_ON_RESIZE bor ?wxWANTS_CHARS}]),
	wxWindow:setBackgroundStyle(Canvas, ?wxBG_STYLE_PAINT),
	wxFrame:connect(Frame, close_window),
	wxPanel:connect(Canvas, paint, [callback]),
	wxPanel:connect(Canvas, size, [{skip, true}]),
	wxPanel:connect(Canvas, key_down),
	[wxPanel:connect(Canvas, Ev) || Ev <- [left_down, left_up, motion, mousewheel]],
	wxFrame:show(Frame),
	wxWindow:setFocus(Canvas),
	Speed = maps:get(speed, Opts, ?DEFAULT_SPEED),
	S = #state{
		frame = Frame,
		canvas = Canvas,
		res = visor_view:new_resources(),
		source = maps:get(scape, Opts, ?INIT_SCAPE_TYPE),
		fps = maps:get(fps, Opts, ?DEFAULT_FPS),
		publish_hz = maps:get(publish_hz, Opts, ?DEFAULT_PUBLISH_HZ),
		speed = Speed,
		watch_speed = case Speed of max -> ?DEFAULT_SPEED; _ -> Speed end,
		camera = visor_camera:new(),
		logs = sim_log:enabled(),
		meter = new_meter(0, #{})
	},
	self() ! connect,
	self() ! tick,
	{Frame, S}.

%% Runs in this process while wx waits; must only read the state.
handle_sync_event(#wx{event = #wxPaint{}}, _Obj, S = #state{canvas = Canvas, res = Res}) ->
	DC = wxBufferedPaintDC:new(Canvas),
	Size = wxWindow:getClientSize(Canvas),
	wx:batch(fun() -> visor_view:render(DC, Size, scene(S), Res) end),
	wxBufferedPaintDC:destroy(DC),
	ok.

handle_event(#wx{event = #wxClose{}}, S) ->
	{stop, normal, S};
handle_event(#wx{event = #wxSize{}}, S) ->
	{noreply, refresh(maybe_autofit(S))};
handle_event(#wx{event = #wxKey{type = key_down, keyCode = Code}}, S) ->
	case key_command(Code) of
		undefined -> {noreply, S};
		close -> {stop, normal, S};
		quit_all ->
			%% sim:quit/0 stops the simulation, then this window, then the node.
			spawn(sim, quit, []),
			{noreply, S};
		Cmd -> {noreply, command(Cmd, S)}
	end;
handle_event(#wx{event = #wxMouse{type = mousewheel, wheelRotation = Rot, x = X, y = Y}}, S) ->
	Factor = case Rot > 0 of true -> ?ZOOM_STEP; false -> 1 / ?ZOOM_STEP end,
	{noreply, command({zoom, Factor, {X, Y}}, S)};
handle_event(#wx{event = #wxMouse{type = left_down, x = X, y = Y}}, S) ->
	wxWindow:setFocus(S#state.canvas),
	{noreply, S#state{drag = {X, Y}, press = {X, Y}}};
handle_event(#wx{event = #wxMouse{type = left_up, x = X, y = Y}}, S = #state{press = {X0, Y0}})
		when abs(X - X0) =< ?CLICK_PX, abs(Y - Y0) =< ?CLICK_PX ->
	{noreply, click({X, Y}, S#state{drag = undefined, press = undefined})};
handle_event(#wx{event = #wxMouse{type = left_up}}, S) ->
	{noreply, S#state{drag = undefined, press = undefined}};
handle_event(#wx{event = #wxMouse{type = motion, leftDown = true, x = X, y = Y}}, S = #state{drag = {X0, Y0}}) ->
	{noreply, command({pan, X - X0, Y - Y0}, S#state{drag = {X, Y}})};
handle_event(#wx{}, S) ->
	{noreply, S}.

handle_call(stats, _From, S = #state{speed = Speed, sim_paused = Paused, deaths = Deaths}) ->
	{reply, (maps:get(rates, S#state.meter))#{speed => Speed, sim_paused => Paused,
		deaths => visor_deaths:total(Deaths)}, S};
handle_call(_Request, _From, S) ->
	{reply, {error, unknown_request}, S}.

handle_cast(stop, S) ->
	{stop, normal, S};
handle_cast({fps, Fps}, S) ->
	{noreply, S#state{fps = Fps}};
handle_cast({command, Cmd}, S) ->
	{noreply, command(Cmd, S)};
handle_cast(_Msg, S) ->
	{noreply, S}.

handle_info(tick, S = #state{fps = Fps}) ->
	erlang:send_after(1000 div Fps, self(), tick),
	{noreply, measure(pull(S))};
handle_info(connect, S = #state{tab = undefined}) ->
	{noreply, refresh(connect(S))};
handle_info(connect, S) ->
	{noreply, S};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, S = #state{scape_mon = Mon}) ->
	{noreply, refresh(disconnected(S))};
handle_info({visor_notify, #{new_population := _} = Info}, S) ->
	{noreply, refresh(S#state{info = maps:without([new_population], Info), evo = visor_evo:new()})};
handle_info({visor_notify, #{finished := {Morphology, Fitness, Neurons}} = Info}, S = #state{info = Old, evo = Evo}) ->
	{noreply, refresh(S#state{info = maps:merge(Old, maps:without([finished], Info)),
		evo = visor_evo:add(Evo, Morphology, Fitness, Neurons, maps:get(evaluations, Info, undefined),
			maps:get(agent_generation, Info, undefined))})};
handle_info({visor_notify, Info}, S = #state{info = Old}) ->
	{noreply, refresh(S#state{info = maps:merge(Old, Info)})};
handle_info({genome_shown, Win, Pid}, S = #state{genome_win = Win}) ->
	{noreply, refresh(S#state{genome_pid = Pid})};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, S = #state{genome_mon = Mon}) ->
	{noreply, refresh(S#state{genome_win = undefined, genome_mon = undefined, genome_pid = undefined})};
handle_info(_Stale, S) ->
	{noreply, S}.

terminate(_Reason, S = #state{res = Res}) ->
	case S#state.genome_win of
		undefined -> ok;
		Win -> visor_genome_win:close(Win)
	end,
	case S#state.scape of
		undefined -> ok;
		Scape -> gen_server:cast(Scape, {self(), unsubscribe})
	end,
	visor_view:free_resources(Res),
	wx:destroy(),
	ok.

code_change(_OldVsn, S, _Extra) ->
	{ok, S}.

%%==================================================================== controller logic

%% Every user intent, from any input device or the shell API, goes through here.
command({pan, DX, DY}, S = #state{camera = Cam}) ->
	refresh(S#state{camera = visor_camera:pan(Cam, DX, DY), auto_fit = false});
command({zoom, Factor}, S = #state{canvas = Canvas}) ->
	{W, H} = wxWindow:getClientSize(Canvas),
	command({zoom, Factor, {W / 2, H / 2}}, S);
command({zoom, Factor, Anchor}, S = #state{camera = Cam}) ->
	refresh(S#state{camera = visor_camera:zoom_at(Cam, Factor, Anchor), auto_fit = false});
command({filter, Filter}, S) ->
	refresh(S#state{camera = Filter, auto_fit = false});
command(fit, S) ->
	refresh(autofit(S#state{auto_fit = true}));
command(toggle_hud, S = #state{hud = Hud}) ->
	refresh(S#state{hud = not Hud});
command(toggle_legend, S = #state{legend = Legend}) ->
	refresh(S#state{legend = not Legend});
command(toggle_logs, S) ->
	refresh(S#state{logs = sim_log:toggle()});
command(toggle_freeze, S = #state{frozen = Frozen}) ->
	refresh(S#state{frozen = not Frozen});
command(cycle_genome, S = #state{genome_win = undefined}) ->
	command({genome, {best, prey}}, S);
command(cycle_genome, S = #state{genome_win = Win}) ->
	visor_genome_win:cycle(Win),
	S;
command(close_genome, S = #state{genome_win = undefined}) ->
	S;
command(close_genome, S = #state{genome_win = Win}) ->
	visor_genome_win:close(Win),
	S;
command({genome, Sel}, S = #state{genome_win = undefined}) ->
	Win = visor_genome_win:start(self(), Sel),
	S#state{genome_win = Win, genome_mon = erlang:monitor(process, Win)};
command({genome, Sel}, S = #state{genome_win = Win}) ->
	visor_genome_win:show(Win, Sel),
	S;
command(toggle_chart, S = #state{show_chart = Show}) ->
	refresh(S#state{show_chart = not Show});
command(toggle_deaths, S = #state{show_deaths = Show}) ->
	refresh(S#state{show_deaths = not Show});
command(toggle_trails, S = #state{show_trails = Show}) ->
	refresh(S#state{show_trails = not Show, trails = #{}});
command({speed, max}, S) ->
	send_pace(refresh(S#state{speed = max}));
command({speed, N}, S) ->
	send_pace(refresh(S#state{speed = N, watch_speed = N}));
command(slower, S = #state{speed = Speed, watch_speed = W}) ->
	Current = case Speed of max -> lists:last(?SPEEDS) * 2; _ -> W end,
	command({speed, lists:last([lists:min(?SPEEDS) | [X || X <- ?SPEEDS, X < Current]])}, S);
command(faster, S = #state{speed = max}) ->
	S;
command(faster, S = #state{watch_speed = W}) ->
	command({speed, case [X || X <- ?SPEEDS, X > W] of [] -> max; [X | _] -> X end}, S);
command(toggle_max, S = #state{speed = max, watch_speed = W}) ->
	command({speed, W}, S);
command(toggle_max, S) ->
	command({speed, max}, S);
command(toggle_pause, S = #state{sim_paused = Paused}) ->
	send_pace(refresh(S#state{sim_paused = not Paused})).

%% Tells the scape the current watch speed and pause state (idempotent).
send_pace(S = #state{scape = undefined}) ->
	S;
send_pace(S = #state{scape = Scape, speed = Speed, sim_paused = Paused}) ->
	gen_server:cast(Scape, {visor, pace, {speed, Speed}}),
	gen_server:cast(Scape, {visor, pace, case Paused of true -> pause; false -> resume end}),
	S.

key_command(?WXK_LEFT) -> {pan, ?PAN_STEP, 0};
key_command(?WXK_RIGHT) -> {pan, -?PAN_STEP, 0};
key_command(?WXK_UP) -> {pan, 0, ?PAN_STEP};
key_command(?WXK_DOWN) -> {pan, 0, -?PAN_STEP};
key_command(C) when C == $+; C == $=; C == ?WXK_NUMPAD_ADD -> {zoom, ?ZOOM_STEP};
key_command(C) when C == $-; C == ?WXK_NUMPAD_SUBTRACT -> {zoom, 1 / ?ZOOM_STEP};
key_command(C) when C == $F; C == $0 -> fit;
key_command($L) -> toggle_legend;
key_command($H) -> toggle_hud;
key_command(C) when C == $,; C == $[ -> slower;
key_command(C) when C == $.; C == $] -> faster;
key_command($M) -> toggle_max;
key_command(C) when C == ?WXK_SPACE; C == $P -> toggle_pause;
key_command($T) -> toggle_trails;
key_command($D) -> toggle_deaths;
key_command($C) -> toggle_chart;
key_command($Z) -> toggle_freeze;
key_command($G) -> cycle_genome;
key_command($V) -> toggle_logs;
key_command($X) -> quit_all;
key_command(C) when C == $Q; C == ?WXK_ESCAPE -> close;
key_command(_) -> undefined.

%% Reads only the newest frame; anything published in between is simply skipped.
pull(S = #state{frozen = true}) ->
	S;
pull(S = #state{tab = Tab, seq = Seq, deaths = Deaths = #{marks := [_ | _]}}) when Tab =/= undefined ->
	case visor_frame:latest(Tab) of
		{ok, Seq, _Same} ->
			refresh(S#state{deaths = visor_deaths:prune(Deaths, erlang:monotonic_time(millisecond))});
		_ ->
			pull_new(S)
	end;
pull(S) ->
	pull_new(S).

pull_new(S = #state{tab = undefined}) ->
	S;
pull_new(S = #state{tab = Tab, seq = Seq}) ->
	case visor_frame:latest(Tab) of
		{ok, Seq, _Same} -> S;
		{ok, NewSeq, Frame} ->
			S1 = update_deaths(S#state{seq = NewSeq, snapshot = Frame}),
			refresh(maybe_autofit(update_trails(S1)));
		empty -> S;
		gone -> refresh(disconnected(S))
	end.

refresh(S = #state{canvas = Canvas, meter = M = #{repaints := N}}) ->
	wxWindow:refresh(Canvas, [{eraseBackground, false}]),
	S#state{meter = M#{repaints := N + 1}}.

%% Death markers fade on the wall clock, so keep repainting while any are visible
%% even if the scape publishes nothing new (e.g. paused).
%% At max speed deaths come by the thousand per second: only the counts are kept.
update_deaths(S = #state{snapshot = Frame, deaths = Deaths, trails = Trails, speed = Speed}) ->
	{Deaths1, Died} = visor_deaths:absorb(Deaths, Frame, erlang:monotonic_time(millisecond)),
	Deaths2 = case Speed of max -> Deaths1#{marks := []}; _ -> Deaths1 end,
	S#state{deaths = Deaths2, trails = maps:without(Died, Trails)}.

%% Trails are the controller's memory of where each agent was in the frames it
%% showed; agents that left the scape lose theirs.
update_trails(S = #state{show_trails = false}) ->
	S;
update_trails(S = #state{speed = max}) ->
	S#state{trails = #{}};
update_trails(S = #state{snapshot = #{agents := Agents}, trails = Old}) ->
	New = maps:from_list([{Id, {Color, extend_trail(Loc, Old, Id)}} || {Id, Color, Loc} <- Agents]),
	S#state{trails = New};
update_trails(S) ->
	S.

extend_trail(Loc, Old, Id) ->
	case Old of
		#{Id := {_, [Loc | _] = Points}} -> Points;
		#{Id := {_, Points}} -> [Loc | lists:sublist(Points, ?TRAIL_LEN - 1)];
		_ -> [Loc]
	end.

maybe_autofit(S = #state{auto_fit = true}) -> autofit(S);
maybe_autofit(S) -> S.

autofit(S = #state{snapshot = #{bounds := Bounds}, canvas = Canvas}) when Bounds =/= undefined ->
	S#state{camera = visor_camera:fit(Bounds, wxWindow:getClientSize(Canvas))};
autofit(S) ->
	S.

%%==================================================================== model connection

connect(S = #state{source = Source, publish_hz = Hz}) ->
	case resolve(Source) of
		{ok, Scape} ->
			try gen_server:call(Scape, {visor, subscribe, self(), Hz}, ?SUBSCRIBE_TIMEOUT) of
				{ok, Tab} ->
					send_pace(S#state{scape = Scape, tab = Tab, seq = 0, trails = #{},
						deaths = visor_deaths:new_marks(),
						scape_mon = erlang:monitor(process, Scape),
						meter = new_meter(0, #{})});
				_ ->
					retry_connect(S)
			catch
				exit:_ -> retry_connect(S)
			end;
		error ->
			retry_connect(S)
	end.

resolve(Pid) when is_pid(Pid) ->
	{ok, Pid};
resolve(Type) when is_atom(Type) ->
	try gen_server:call(polis, {get_scape, Type}, ?SUBSCRIBE_TIMEOUT) of
		Pid when is_pid(Pid) -> {ok, Pid};
		_ -> error
	catch
		exit:_ -> error
	end.

retry_connect(S) ->
	erlang:send_after(?RECONNECT_MS, self(), connect),
	S.

disconnected(S = #state{scape_mon = Mon}) ->
	Mon =/= undefined andalso erlang:demonitor(Mon, [flush]),
	retry_connect(S#state{scape = undefined, scape_mon = undefined, tab = undefined}).

%%==================================================================== HUD & rate meter

new_meter(Seq, Rates) ->
	#{t0 => erlang:monotonic_time(millisecond), seq0 => Seq, last_seq => Seq,
	  shown => 0, repaints => 0, steps0 => undefined, rates => Rates}.

%% Once per window, turns raw counters into rates. Distinguishes how fast the
%% simulation runs from how often the scape publishes and how often we display.
measure(S = #state{meter = M0, seq = Seq, snapshot = Snapshot}) ->
	Now = erlang:monotonic_time(millisecond),
	Steps = sim_steps(Snapshot),
	M1 = case Seq =/= maps:get(last_seq, M0) of
		true -> M0#{shown := maps:get(shown, M0) + 1, last_seq := Seq};
		false -> M0
	end,
	M = case maps:get(steps0, M1) of undefined -> M1#{steps0 := Steps}; _ -> M1 end,
	#{t0 := T0, seq0 := Seq0, shown := Shown0, repaints := Repaints, steps0 := Steps0} = M,
	case Now - T0 >= ?METER_WINDOW_MS of
		false ->
			S#state{meter = M};
		true ->
			Secs = (Now - T0) / 1000,
			Published = max(0, Seq - Seq0),
			Shown = min(Shown0, Published),
			Rates = #{
				view_fps => round(Repaints / Secs),
				frames_published_per_s => round(Published / Secs),
				frames_shown_per_s => round(Shown / Secs),
				frames_skipped_per_s => round((Published - Shown) / Secs),
				sim_steps_per_s => round(max(0, Steps - Steps0) / Secs),
				frame_age_ms => frame_age(Snapshot)
			},
			S#state{meter = (new_meter(Seq, Rates))#{steps0 := Steps}}
	end.

sim_steps(#{stats := #{steps := Steps}}) -> Steps;
sim_steps(_) -> 0.

frame_age(#{published_at := T}) -> erlang:monotonic_time(millisecond) - T;
frame_age(_) -> undefined.

scene(S = #state{snapshot = Snapshot, camera = Cam, trails = Trails}) ->
	#{frame => Snapshot, camera => Cam, trails => maps:values(Trails), deaths => death_marks(S),
	  chart => case S#state.show_chart of true -> visor_evo:chart(S#state.evo); false -> undefined end,
	  selected => S#state.genome_pid,
	  hud => hud_lines(S), banner => banner(S)}.

%% A click (press and release without dragging) on a prey/predator inspects its genome.
click(Point, S = #state{snapshot = #{agents := Agents}, camera = Cam}) ->
	Near = [{dist2(visor_camera:to_screen(Cam, Loc), Point), Id} || {Id, _Color, Loc} <- Agents, is_pid(Id)],
	case lists:sort([N || N = {D2, _} <- Near, D2 =< ?PICK_PX * ?PICK_PX]) of
		[{_, Pid} | _] -> command({genome, {pid, Pid}}, S);
		[] -> S
	end;
click(_Point, S) ->
	S.

dist2({X0, Y0}, {X1, Y1}) -> (X1 - X0) * (X1 - X0) + (Y1 - Y0) * (Y1 - Y0).

death_marks(#state{speed = max}) ->
	[];
death_marks(#state{show_deaths = true, deaths = Deaths}) ->
	visor_deaths:primitives(Deaths, erlang:monotonic_time(millisecond));
death_marks(_) ->
	[].

banner(#state{tab = undefined, source = Source}) ->
	fmt("Waiting for scape ~p ...", [Source]);
banner(_) ->
	undefined.

hud_lines(S = #state{hud = Hud, legend = Legend}) ->
	HudLines = case Hud of true -> status_lines(S); false -> [] end,
	LegendLines = case Legend of
		true -> ["Legend:" | [string:trim(L) || L <- ct_legend()]];
		false -> []
	end,
	HudLines ++ LegendLines.

status_lines(#state{snapshot = Snapshot, camera = {Zoom, _, _}, info = Info, frozen = Frozen,
		meter = #{rates := R}, fps = Fps, publish_hz = Hz, source = Source,
		speed = Speed, sim_paused = Paused, deaths = Deaths, evo = Evo, logs = Logs}) ->
	Stats = case Snapshot of #{stats := St} -> St; _ -> #{} end,
	Counts = case Snapshot of #{counts := C} -> C; _ -> #{} end,
	FrozenTag = case Frozen of true -> "  [DISPLAY FROZEN]"; false -> "" end,
	SpeedText = case Speed of
		max -> "MAX (unthrottled; trails and death markers off)";
		N -> fmt("~p steps/s per agent", [N])
	end,
	PausedTag = case Paused of true -> "  [SIMULATION PAUSED]"; false -> "" end,
	[fmt("Scape: ~p~s", [maps:get(scape, Stats, Source), FrozenTag]),
	 fmt("Speed: ~s~s   , . slower/faster  M max  Space pause  T trails  D deaths  C chart  G genome", [SpeedText, PausedTag]),
	 fmt("Sim: ~p steps/s   tick: ~p   console logs: ~s (V)", [maps:get(sim_steps_per_s, R, 0),
		maps:get(ticks, Stats, 0), case Logs of true -> "on"; false -> "off" end]),
	 fmt("Frames: published ~p/s (max ~p)  shown ~p/s  skipped ~p/s", [
		maps:get(frames_published_per_s, R, 0), Hz,
		maps:get(frames_shown_per_s, R, 0), maps:get(frames_skipped_per_s, R, 0)]),
	 fmt("View: ~p repaints/s (tick ~p/s)  frame age: ~p ms",
		[maps:get(view_fps, R, 0), Fps, maps:get(frame_age_ms, R, undefined)])]
	++ [fmt("Lineage generation: ~s   evaluations: ~p",
		[visor_evo:generations_text(Evo, maps:get(generation, Info, undefined)),
		 maps:get(evaluations, Info, '-')]) || map_size(Info) > 0]
	++ visor_evo:hud_lines(Evo)
	++ [visor_deaths:hud_line(Deaths)]
	++ [fmt("Avatars: ~s", [lists:join("  ",
		[io_lib:format("~p ~p", [T, N]) || {T, N} <- lists:sort(maps:to_list(Counts))])])]
	++ [fmt("Zoom ~.3f | arrows/drag pan  wheel,+/- zoom  F fit  L legend  H hud  Z freeze view  click: genome  Q close  X quit all", [Zoom])].

fmt(Format, Args) ->
	unicode:characters_to_list(io_lib:format(Format, Args)).

%%==================================================================== sensor/color helpers (from the book)

ct2color(Sensors) ->
	SensorNames = [Name || {sensor, Name, _SensorId, _VL, _Parameters} <- Sensors],
	case count_SensorTypes(SensorNames, {0, 0, 0, 0}) of
		{_, 0, 0, 0} -> red;    %prey_sensor
		{0, _, 0, 0} -> blue;   %plant_sensor
		{_, _, 0, 0} -> white;  %prey_sensor and plant_sensor
		{0, _, _, 0} -> cyan;   %plant_sensor, predator_sensor
		{_, 0, _, 0} -> grey;   %prey_sensor, predator_sensor
		{_, _, _, _} -> black   %prey_sensor, plant_sensor, predator_sensor
	end.

count_SensorTypes([Sensor | Sensors], {Prey, Plant, Flatlander, Other}) ->
	case Sensor of
		coned_prey_sensor -> count_SensorTypes(Sensors, {Prey + 1, Plant, Flatlander, Other});
		coned_plant_sensor -> count_SensorTypes(Sensors, {Prey, Plant + 1, Flatlander, Other});
		coned_flatlander_sensor -> count_SensorTypes(Sensors, {Prey, Plant, Flatlander + 1, Other});
		_ -> count_SensorTypes(Sensors, {Prey, Plant, Flatlander, Other + 1})
	end;
count_SensorTypes([], Tuple) ->
	Tuple.

ct_legend() ->
	["Red -> prey_sensor\n",
	 "Blue -> plant_sensor\n",
	 "White -> prey_sensor & plant_sensor\n",
	 "Cyan -> plant_sensor & predator_sensor\n",
	 "Grey -> prey_sensor & predator_sensor\n",
	 "Black -> prey_sensor & plant_sensor & predator_sensor\n"].
