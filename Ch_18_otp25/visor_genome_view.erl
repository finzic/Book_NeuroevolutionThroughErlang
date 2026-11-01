%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% The "V" of the genome window: stateless layout and drawing of a visor_genome graph.
%%
%% Layout: one column per layer - sensors left, neuron layers in the middle, actuators
%% right. Within a column nodes are ordered by the barycentre of their neighbours
%% (a few forward/backward sweeps), which removes most crossing lines.
%% Every link enters its target from the left and ends in an arrowhead.
%%   forward (to a later column):   smooth curve left to right;
%%   same column (recurrent):       arc bulging to the right of the column;
%%   backward (recurrent, to an earlier column): leaves its source to the right, drops
%%                                  to its own lane under the network, runs back and
%%                                  rises into the target, never crossing a node;
%%   self (recurrent):              small loop above the neuron.
-module(visor_genome_view).
-include_lib("wx/include/wx.hrl").

-export([new_resources/0, free_resources/1, render/5, layout/2, node_at/3]).

-define(BG, {24, 26, 30}).
-define(NODE_R, 9).
-define(MIN_NODE_R, 4).
-define(LEFT, 150).
-define(RIGHT, 150).
-define(TOP, 118).
-define(INFO_H, 150).
-define(LANE_GAP, 14).
-define(LANE_SHARE, 0.3).
-define(SIDE, 22).
-define(DENSE_GAP, 30).
-define(SWEEPS, 4).
-define(ARROW, 8.0).
-define(PICK_R, 14).

new_resources() ->
	#{bg => wxBrush:new(?BG),
	  title_font => wxFont:new(13, ?wxFONTFAMILY_SWISS, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
	  font => wxFont:new(10, ?wxFONTFAMILY_SWISS, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL),
	  bold => wxFont:new(10, ?wxFONTFAMILY_SWISS, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
	  mono => wxFont:new(9, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL)}.

free_resources(#{bg := Bg} = Res) ->
	wxBrush:destroy(Bg),
	[wxFont:destroy(maps:get(F, Res)) || F <- [title_font, font, bold, mono]],
	ok.

%%==================================================================== layout

%% Returns node positions, node radius, column headers, crowded columns (labels go to the
%% side) and one lane per backward link.
layout(#{nodes := Nodes, edges := Edges}, {W, H}) ->
	Layers = lists:usort([L || #{layer := L} <- Nodes]),
	NCols = length(Layers),
	ColIndex = maps:from_list(lists:zip(Layers, lists:seq(0, NCols - 1))),
	Col = maps:from_list([{Id, maps:get(L, ColIndex)} || #{id := Id, layer := L} <- Nodes]),
	Forward = [{F, T} || #{from := F, to := T} <- Edges, maps:get(F, Col) < maps:get(T, Col)],
	Backward = [{F, T} || #{from := F, to := T} <- Edges, maps:get(F, Col) > maps:get(T, Col)],
	Columns0 = [lists:sort([Id || #{id := Id, layer := L} <- Nodes, L == Layer]) || Layer <- Layers],
	Columns = order_columns(Columns0, Forward),
	NetBottom0 = H - ?INFO_H,
	NLanes = length(Backward),
	LaneGap = case NLanes of
		0 -> ?LANE_GAP;
		_ -> min(?LANE_GAP, (NetBottom0 - ?TOP) * ?LANE_SHARE / NLanes)
	end,
	NetBottom = NetBottom0 - NLanes * LaneGap - 10,
	Gaps = [(NetBottom - ?TOP) / (length(C) + 1) || C <- Columns],
	R = max(?MIN_NODE_R, min(?NODE_R, lists:min(Gaps) / 2.6)),
	AW = max(1, W - ?LEFT - ?RIGHT),
	ColX = fun(_) when NCols == 1 -> ?LEFT + AW / 2;
	          (I) -> ?LEFT + AW * I / (NCols - 1)
	       end,
	Pos = maps:from_list(lists:append(
		[begin
			N = length(Ids),
			[{Id, {ColX(I), ?TOP + (NetBottom - ?TOP) * J / (N + 1)}} || {J, Id} <- lists:zip(lists:seq(1, N), Ids)]
		 end || {I, Ids} <- lists:zip(lists:seq(0, NCols - 1), Columns)])),
	%Short backward links get the lanes nearest to the network so long ones wrap around them.
	ByLen = lists:sort([{maps:get(F, Col) - maps:get(T, Col), F, T} || {F, T} <- Backward]),
	Lanes = maps:from_list([{{F, T}, NetBottom + 10 + LaneGap * K}
		|| {K, {_, F, T}} <- lists:zip(lists:seq(1, NLanes), ByLen)]),
	Dense = sets:from_list([Id || {C, Gap} <- lists:zip(Columns, Gaps), Gap < ?DENSE_GAP, Id <- C]),
	#{pos => Pos, lanes => Lanes, r => R, col => Col, dense => Dense,
	  columns => [{ColX(I), column_title(Layer, Layers)} || {I, Layer} <- lists:zip(lists:seq(0, NCols - 1), Layers)],
	  net_bottom => NetBottom}.

column_title(-1, _) -> "sensors";
column_title(1, _) -> "actuators";
column_title(Layer, Layers) ->
	Hidden = [L || L <- Layers, L > -1, L < 1],
	"layer " ++ integer_to_list(length(lists:takewhile(fun(L) -> L =/= Layer end, Hidden)) + 1).

%% Barycentre heuristic: alternately order each column by the mean position of its
%% predecessors (forward sweep) and successors (backward sweep).
order_columns(Columns, Forward) ->
	lists:foldl(fun(_, Cs) -> sweep(backward, sweep(forward, Cs, Forward), Forward) end,
		Columns, lists:seq(1, ?SWEEPS)).

%Edges are {From, To}; reorder/3 wants {Node, Neighbour} pairs.
sweep(forward, Columns, Edges) ->
	lists:reverse(lists:foldl(
		fun(Col, []) -> [Col];
		   (Col, Done) -> [reorder(Col, rank(Done), [{T, F} || {F, T} <- Edges]) | Done]
		end, [], Columns));
sweep(backward, Columns, Edges) ->
	lists:foldr(
		fun(Col, []) -> [Col];
		   (Col, Done) -> [reorder(Col, rank(Done), Edges) | Done]
		end, [], Columns).

%% Neighbours (ids with a known rank) give the barycentre; nodes without any keep their place.
reorder(Col, Rank, Edges) ->
	N = length(Col),
	Keyed = [{case [maps:get(Nb, Rank) || {Id2, Nb} <- Edges, Id2 == Id, is_map_key(Nb, Rank)] of
			[] -> J / (N + 1);
			Rs -> lists:sum(Rs) / length(Rs)
		  end, J, Id} || {J, Id} <- lists:zip(lists:seq(1, N), Col)],
	[Id || {_, _, Id} <- lists:sort(Keyed)].

%Relative height (0..1) of every node in the already placed columns.
rank(Columns) ->
	maps:from_list([{Id, J / (length(Col) + 1)}
		|| Col <- Columns, {J, Id} <- lists:zip(lists:seq(1, length(Col)), Col)]).

%%==================================================================== hit test

node_at(#{pos := Pos}, _Graph, {X, Y}) ->
	Near = [{(PX - X) * (PX - X) + (PY - Y) * (PY - Y), Id} || {Id, {PX, PY}} <- maps:to_list(Pos)],
	case lists:sort([N || N = {D2, _} <- Near, D2 =< ?PICK_R * ?PICK_R]) of
		[{_, Id} | _] -> Id;
		[] -> undefined
	end.

%%==================================================================== render

%% Model: #{title, graph | error, pid}. Hover: node id under the mouse or undefined.
render(DC, {W, H} = Size, Model, Hover, Res) ->
	GC = wxGraphicsContext:create(DC),
	try
		wxGraphicsContext:setPen(GC, ?wxTRANSPARENT_PEN),
		wxGraphicsContext:setBrush(GC, maps:get(bg, Res)),
		wxGraphicsContext:drawRectangle(GC, 0, 0, W, H),
		text(GC, maps:get(title_font, Res), {255, 255, 255}, maps:get(title, Model, "Genome"), 12, 8),
		case Model of
			#{graph := Graph} -> draw_graph(GC, Size, Graph, maps:get(pid, Model, undefined), Hover, Res);
			#{error := Why} -> text(GC, maps:get(font, Res), {255, 160, 120}, Why, 12, 34);
			_ -> text(GC, maps:get(font, Res), {200, 200, 200}, "loading ...", 12, 34)
		end
	after
		wxGraphicsContext:destroy(GC)
	end,
	ok.

draw_graph(GC, Size, Graph = #{nodes := Nodes, edges := Edges}, Pid, Hover, Res) ->
	#{font := Font, bold := Bold, mono := Mono} = Res,
	text(GC, Font, {210, 210, 210}, summary(Graph, Pid), 12, 32),
	text(GC, Font, {150, 150, 150},
		"links: green = positive weight, red = negative, thickness = strength, grey = to actuator, arrow = direction", 12, 50),
	text(GC, Font, {150, 150, 150},
		"dashed = recurrent (memory): arcs inside a layer, lanes underneath going back.  Hover a node for its genes.", 12, 66),
	L = #{pos := Pos, lanes := Lanes, columns := Columns, net_bottom := NetBottom} = layout(Graph, Size),
	[text(GC, Bold, {170, 170, 170}, T, X - text_w(GC, T) / 2, ?TOP - 30) || {X, T} <- Columns],
	MaxW = lists:max([0.5 | [abs(Wt) || #{weight := Wt} <- Edges, is_number(Wt)]]),
	Touch = fun(#{from := F, to := T}) -> Hover == undefined orelse F == Hover orelse T == Hover end,
	{Faded, Lit} = lists:partition(fun(E) -> not Touch(E) end, Edges),
	Dim = case length(Edges) > 40 of true -> 0.08; false -> 0.12 end,
	[draw_edge(GC, E, L, MaxW, Dim) || E <- Faded],
	[draw_edge(GC, E, L, MaxW, case Hover of undefined -> 0.8; _ -> 1.0 end) || E <- Lit],
	case maps:size(Lanes) of
		0 -> ok;
		_ -> text(GC, Mono, {120, 120, 120}, "backward links", 12, NetBottom + 4)
	end,
	Neighbours = case Hover of
		undefined -> [];
		_ -> [T || #{from := F, to := T} <- Edges, F == Hover] ++ [F || #{from := F, to := T} <- Edges, T == Hover]
	end,
	[draw_node(GC, maps:get(Id, Pos), Nd, Hover == undefined orelse Id == Hover orelse lists:member(Id, Neighbours),
		Id == Hover, L, Res) || Nd = #{id := Id} <- Nodes],
	draw_info(GC, Size, [Nd || Nd = #{id := Id} <- Nodes, Id == Hover], Mono, Font),
	draw_legend(GC, Size, Res),
	ok.

summary(#{morphology := M, generation := Gen, fitness := F, nodes := Nodes, edges := Edges}, Pid) ->
	FitText = case F of undefined -> "-"; _ -> io_lib:format("~.3f", [float(F)]) end,
	Where = case Pid of undefined -> "not in the arena right now"; _ -> "in the arena now (yellow ring)" end,
	io_lib:format("~p   generation ~p   stored fitness ~s   ~p neurons   ~p links (~p recurrent)   ~s",
		[M, Gen, FitText, length([x || #{kind := neuron} <- Nodes]), length(Edges),
		 length([x || #{recurrent := true} <- Edges]), Where]).

draw_info(GC, {_W, H}, [], _Mono, Font) ->
	text(GC, Font, {130, 130, 130}, "Hover a sensor, neuron or actuator to list its connections and weights.",
		12, H - ?INFO_H + 18);
draw_info(GC, {_W, H}, [#{details := Lines}], Mono, _Font) ->
	MaxLines = (?INFO_H - 20) div 14,
	Shown = case length(Lines) > MaxLines of
		true -> lists:sublist(Lines, MaxLines - 1) ++ [io_lib:format("  ... ~p more", [length(Lines) - MaxLines + 1])];
		false -> Lines
	end,
	lists:foldl(fun(Line, Y) -> text(GC, Mono, {230, 230, 230}, Line, 12, Y), Y + 14 end,
		H - ?INFO_H + 14, Shown).

-define(LEGEND_W, 350).

%% What a sensor input number means, bottom-right. Values from sensor:clr2val/1 and
%% sensor:shortest_intrLine/2.
draw_legend(GC, {W, H}, #{mono := Mono, bold := Bold}) ->
	X0 = W - ?LEGEND_W - 10, Y0 = H - ?INFO_H + 4,
	wxGraphicsContext:setPen(GC, ?wxTRANSPARENT_PEN),
	Panel = wxBrush:new({40, 43, 50}),
	wxGraphicsContext:setBrush(GC, Panel),
	wxGraphicsContext:drawRoundedRectangle(GC, X0, Y0, ?LEGEND_W, ?INFO_H - 10, 6),
	wxBrush:destroy(Panel),
	X = X0 + 10,
	text(GC, Bold, {255, 255, 255}, "Sensor inputs: 5 rays, one number each", X, Y0 + 6),
	text(GC, Mono, {200, 200, 200}, "weight order  R36 R18 ahead L18 L36 (degrees)", X, Y0 + 24),
	text(GC, Mono, {200, 200, 200}, "colour = what the ray hits first:", X, Y0 + 42),
	Swatches = [{"poison", "-1", {25, 25, 25}}, {"plant", "-0.5", {40, 170, 60}}, {"prey", "0", {40, 90, 220}},
		{"predator", "0.5", {220, 40, 40}}, {"wall", "0.75", {130, 85, 40}}, {"nothing", "1", undefined}],
	lists:foreach(
		fun({I, {Name, Val, RGB}}) ->
			SX = X + 8 + (I div 3) * 155,
			SY = Y0 + 60 + (I rem 3) * 16,
			swatch(GC, SX, SY + 7, RGB),
			text(GC, Mono, {230, 230, 230}, io_lib:format("~-9s~5s", [Name, Val]), SX + 12, SY)
		end, lists:zip(lists:seq(0, length(Swatches) - 1), Swatches)),
	text(GC, Mono, {200, 200, 200}, "distance = pixels to it, -1 = nothing hit", X, Y0 + 112),
	ok.

%"nothing" has no colour: a dash instead of a dot.
swatch(GC, X, Y, undefined) ->
	with_pen(GC, {200, 200, 200}, 1.0, 2, ?wxPENSTYLE_SOLID, fun() ->
		wxGraphicsContext:strokeLines(GC, [{X - 5, Y}, {X + 5, Y}])
	end);
swatch(GC, X, Y, RGB) ->
	with_pen(GC, {200, 200, 200}, 1.0, 1, ?wxPENSTYLE_SOLID, fun() ->
		Brush = wxBrush:new(RGB),
		wxGraphicsContext:setBrush(GC, Brush),
		wxGraphicsContext:drawEllipse(GC, X - 5, Y - 5, 10, 10),
		wxBrush:destroy(Brush)
	end).

%%==================================================================== edges

draw_edge(GC, #{from := F, to := T, weight := Wt} = E, Layout, MaxW, Alpha) ->
	{RGB, Width} = case Wt of
		undefined -> {{170, 170, 170}, 1.5};
		_ when Wt >= 0 -> {{90, 220, 120}, 0.8 + 3.5 * Wt / MaxW};
		_ -> {{255, 105, 90}, 0.8 - 3.5 * Wt / MaxW}
	end,
	Rec = maps:get(recurrent, E, false) orelse F == T,
	Style = case Rec of true -> ?wxPENSTYLE_SHORT_DASH; false -> ?wxPENSTYLE_SOLID end,
	{Start, Segments, ArrowFrom, End} = route(F, T, Layout),
	with_pen(GC, RGB, Alpha, Width, Style, fun() ->
		Path = wxGraphicsContext:createPath(GC),
		wxGraphicsPath:moveToPoint(Path, Start),
		[case Seg of
			{curve, C1, C2, P} -> wxGraphicsPath:addCurveToPoint(Path, C1, C2, P);
			{line, P} -> wxGraphicsPath:addLineToPoint(Path, P)
		 end || Seg <- Segments],
		wxGraphicsContext:strokePath(GC, Path)
	end),
	with_pen(GC, RGB, Alpha, max(1.2, Width * 0.8), ?wxPENSTYLE_SOLID, fun() ->
		wxGraphicsContext:strokeLines(GC, arrow(ArrowFrom, End))
	end).

%% {Start, Segments, PointTheArrowComesFrom, End} for a link.
route(Id, Id, #{pos := Pos, r := R}) ->
	{X, Y} = maps:get(Id, Pos),
	End = {X - R * 0.6, Y - R * 0.8},
	C2 = {X - 30, Y - 42},
	{{X + R * 0.6, Y - R * 0.8}, [{curve, {X + 30, Y - 42}, C2, End}], C2, End};
route(F, T, #{pos := Pos, r := R, col := Col, lanes := Lanes}) ->
	{SX, SY} = maps:get(F, Pos),
	{TX, TY} = maps:get(T, Pos),
	SC = maps:get(F, Col),
	TC = maps:get(T, Col),
	if
		SC < TC ->
			DX = max(30, (TX - SX) / 2),
			End = {TX - R - 1, TY},
			C2 = {TX - DX, TY},
			{{SX + R, SY}, [{curve, {SX + DX, SY}, C2, End}], C2, End};
		SC == TC ->
			Bulge = R + 14 + 0.35 * abs(TY - SY),
			End = {TX + R + 1, TY},
			C2 = {TX + Bulge, TY},
			{{SX + R, SY}, [{curve, {SX + Bulge, SY}, C2, End}], C2, End};
		true ->
			Lane = maps:get({F, T}, Lanes),
			Out = SX + R + ?SIDE,
			In = TX - R - ?SIDE,
			End = {TX - R - 1, TY},
			{{SX + R, SY},
			 [{curve, {Out, SY}, {Out, SY}, {Out, SY + 12}},
			  {line, {Out, Lane - 8}},
			  {curve, {Out, Lane}, {Out, Lane}, {Out - 8, Lane}},
			  {line, {In + 8, Lane}},
			  {curve, {In, Lane}, {In, Lane}, {In, Lane - 8}},
			  {line, {In, TY + 12}},
			  {curve, {In, TY}, {In, TY}, End}],
			 {In, TY}, End}
	end.

arrow({CX, CY}, {X, Y}) ->
	A = math:atan2(Y - CY, X - CX),
	Wing = fun(D) -> {X + ?ARROW * math:cos(A + math:pi() + D), Y + ?ARROW * math:sin(A + math:pi() + D)} end,
	[Wing(0.45), {X, Y}, Wing(-0.45)].

%%==================================================================== nodes

draw_node(GC, {X, Y}, #{id := Id, kind := Kind, label := Label0, name := Name}, Lit, Hovered,
		#{r := R0, dense := Dense}, #{font := Font, bold := Bold}) ->
	Crowded = sets:is_element(Id, Dense),
	Label = case Crowded andalso Kind == neuron andalso not Hovered of true -> Name; false -> Label0 end,
	Fill = case Kind of sensor -> {110, 190, 255}; neuron -> {255, 195, 80}; actuator -> {130, 225, 130} end,
	Alpha = case Lit of true -> 1.0; false -> 0.3 end,
	Brush = wxBrush:new(rgba(Fill, Alpha)),
	R = case Hovered of true -> R0 + 3; false -> R0 end,
	with_pen(GC, case Hovered of true -> {255, 255, 255}; false -> {0, 0, 0} end, Alpha, 2, ?wxPENSTYLE_SOLID,
		fun() ->
			wxGraphicsContext:setBrush(GC, Brush),
			wxGraphicsContext:drawEllipse(GC, X - R, Y - R, 2 * R, 2 * R)
		end),
	wxBrush:destroy(Brush),
	LabelFont = case Hovered of true -> Bold; false -> Font end,
	wxGraphicsContext:setFont(GC, LabelFont, rgba({235, 235, 235}, Alpha)),
	{TW, TH, _, _} = wxGraphicsContext:getTextExtent(GC, Label),
	{TX, TY} = case Kind of
		sensor -> {X - R - 6 - TW, Y - TH / 2};
		actuator -> {X + R + 6, Y - TH / 2};
		neuron when Crowded -> {X - R - 4 - TW, Y - TH / 2};
		neuron -> {X - TW / 2, Y - R - TH - 2}
	end,
	wxGraphicsContext:drawText(GC, Label, TX, TY).

%%==================================================================== helpers

text(GC, Font, RGB, Text, X, Y) ->
	wxGraphicsContext:setFont(GC, Font, RGB),
	wxGraphicsContext:drawText(GC, Text, X, Y).

text_w(GC, Text) ->
	{TW, _, _, _} = wxGraphicsContext:getTextExtent(GC, Text),
	TW.

with_pen(GC, RGB, Alpha, Width, Style, Fun) ->
	Pen = wxPen:new(rgba(RGB, Alpha), [{width, max(1, round(Width))}, {style, Style}]),
	try
		wxGraphicsContext:setPen(GC, Pen),
		Fun()
	after
		wxPen:destroy(Pen)
	end.

rgba({R, G, B}, Alpha) ->
	{R, G, B, max(0, min(255, round(255 * Alpha)))}.
