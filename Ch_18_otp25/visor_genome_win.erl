%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% The "C" of the genome window: a separate wx_object (own process, own frame) opened
%% by the visor. It shows one agent's neural network (see visor_genome_view), re-reads
%% it about once a second through a throw-away process (visor_genome:fetch_async/3) so
%% neither window ever waits for mnesia, and highlights the node under the mouse.
%% It tells its owner which avatar is shown ({genome_shown, self(), Pid | undefined})
%% so the arena can ring it; the owner monitors the window to notice it closing.
%%
%% Keys: 1 best prey, 2 best predator, G next (best prey -> best predator -> close),
%%       Esc/Q close.
-module(visor_genome_win).
-behaviour(wx_object).
-include_lib("wx/include/wx.hrl").

-export([start/2, show/2, cycle/1, close/1]).
-export([init/1, handle_event/2, handle_sync_event/3, handle_call/3, handle_cast/2,
	handle_info/2, terminate/2, code_change/3]).

-define(REFRESH_MS, 1000).
-define(SIZE, {1000, 700}).

-record(state, {frame, canvas, res, owner, sel, ref, model, hover, shown_pid}).

%%==================================================================== API

%% Must be called from a process that has wx running (the visor); returns the pid.
start(Owner, Sel) ->
	Obj = wx_object:start(?MODULE, {wx:get_env(), Owner, Sel}, []),
	wx_object:get_pid(Obj).

show(Pid, Sel) -> wx_object:cast(Pid, {show, Sel}).
cycle(Pid) -> wx_object:cast(Pid, cycle).
close(Pid) -> wx_object:cast(Pid, close).

%%==================================================================== wx_object callbacks

init({Env, Owner, Sel}) ->
	wx:set_env(Env),
	Frame = wxFrame:new(wx:null(), ?wxID_ANY, "Genome", [{size, ?SIZE}]),
	Canvas = wxPanel:new(Frame, [{style, ?wxFULL_REPAINT_ON_RESIZE bor ?wxWANTS_CHARS}]),
	wxWindow:setBackgroundStyle(Canvas, ?wxBG_STYLE_PAINT),
	wxFrame:connect(Frame, close_window),
	wxPanel:connect(Canvas, paint, [callback]),
	wxPanel:connect(Canvas, size, [{skip, true}]),
	wxPanel:connect(Canvas, key_down),
	wxPanel:connect(Canvas, motion),
	wxPanel:connect(Canvas, leave_window),
	wxFrame:show(Frame),
	wxWindow:setFocus(Canvas),
	S = #state{frame = Frame, canvas = Canvas, res = visor_genome_view:new_resources(), owner = Owner},
	{Frame, select(Sel, S)}.

handle_sync_event(#wx{event = #wxPaint{}}, _Obj, #state{canvas = Canvas, res = Res, model = Model, hover = Hover}) ->
	DC = wxBufferedPaintDC:new(Canvas),
	Size = wxWindow:getClientSize(Canvas),
	wx:batch(fun() -> visor_genome_view:render(DC, Size, Model, Hover, Res) end),
	wxBufferedPaintDC:destroy(DC),
	ok.

handle_event(#wx{event = #wxClose{}}, S) ->
	{stop, normal, S};
handle_event(#wx{event = #wxSize{}}, S) ->
	{noreply, repaint(S)};
handle_event(#wx{event = #wxMouse{type = motion, x = X, y = Y}}, S = #state{model = #{graph := Graph}, canvas = Canvas}) ->
	Layout = visor_genome_view:layout(Graph, wxWindow:getClientSize(Canvas)),
	{noreply, hover(visor_genome_view:node_at(Layout, Graph, {X, Y}), S)};
handle_event(#wx{event = #wxMouse{type = leave_window}}, S) ->
	{noreply, hover(undefined, S)};
handle_event(#wx{event = #wxKey{keyCode = Code}}, S) ->
	case Code of
		$1 -> {noreply, select({best, prey}, S)};
		$2 -> {noreply, select({best, predator}, S)};
		$G -> next(S);
		C when C == $Q; C == ?WXK_ESCAPE -> {stop, normal, S};
		_ -> {noreply, S}
	end;
handle_event(#wx{}, S) ->
	{noreply, S}.

handle_call(_Request, _From, S) ->
	{reply, {error, unknown_request}, S}.

handle_cast({show, Sel}, S) ->
	wxFrame:raise(S#state.frame),
	{noreply, select(Sel, S)};
handle_cast(cycle, S) ->
	next(S);
handle_cast(close, S) ->
	{stop, normal, S};
handle_cast(_Msg, S) ->
	{noreply, S}.

handle_info({genome_fetched, Ref, Result}, S = #state{ref = Ref}) ->
	erlang:send_after(?REFRESH_MS, self(), {genome_refresh, Ref}),
	%A clicked avatar is resolved to its agent id on the first fetch; keep following that agent.
	Pid = maps:get(pid, Result, undefined),
	tell_owner(Pid, S),
	{noreply, repaint(S#state{model = Result, sel = maps:get(sel, Result), shown_pid = Pid})};
handle_info({genome_refresh, Ref}, S = #state{ref = Ref, sel = Sel}) ->
	visor_genome:fetch_async(self(), Ref, Sel),
	{noreply, S};
handle_info(_Stale, S) ->
	{noreply, S}.

terminate(_Reason, #state{res = Res, frame = Frame}) ->
	visor_genome_view:free_resources(Res),
	wxFrame:destroy(Frame),
	ok.

code_change(_OldVsn, S, _Extra) ->
	{ok, S}.

%%==================================================================== internals

next(S = #state{sel = {best, prey}}) -> {noreply, select({best, predator}, S)};
next(S) -> {stop, normal, S}.

select(Sel, S = #state{frame = Frame}) ->
	Ref = make_ref(),
	visor_genome:fetch_async(self(), Ref, Sel),
	Title = title(Sel),
	wxFrame:setTitle(Frame, Title),
	repaint(S#state{sel = Sel, ref = Ref, hover = undefined, model = #{sel => Sel, title => Title}}).

title({best, M}) -> lists:flatten(io_lib:format("Genome of the best ~p", [M]));
title(_) -> "Genome of the clicked agent".

hover(Hover, S = #state{hover = Hover}) -> S;
hover(Hover, S) -> repaint(S#state{hover = Hover}).

tell_owner(Pid, #state{shown_pid = Pid}) -> ok;
tell_owner(Pid, #state{owner = Owner}) -> Owner ! {genome_shown, self(), Pid}, ok.

repaint(S = #state{canvas = Canvas}) ->
	wxWindow:refresh(Canvas, [{eraseBackground, false}]),
	S.
