%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% The "V" of the visor MVC: stateless rendering of a scene onto a wx DC.
%% Everything it draws comes from its arguments; the wx pens/brushes/fonts it uses
%% are created once by new_resources/0 (and owned by the controller) so that
%% painting a frame allocates no wx objects except the graphics context.
-module(visor_view).
-include_lib("wx/include/wx.hrl").

-export([new_resources/0, free_resources/1, render/4, palette/0]).
-export_type([scene/0, resources/0]).

-type scene() :: #{frame := visor_frame:frame() | undefined,
	camera := visor_camera:camera(),
	trails => [{atom(), [{number(), number()}]}],
	deaths => [visor_deaths:primitive()],
	chart => undefined | map(),
	selected => pid() | undefined,
	hud := [unicode:chardata()],
	banner := unicode:chardata() | undefined}.
-type resources() :: map().

-define(BACKGROUND, {246, 242, 230}).
-define(UNKNOWN_COLOR, {255, 0, 255}).
-define(MIN_RADIUS_PX, 1.5).
-define(ARROW_HEAD_PX, 8.0).
-define(HUD_PAD, 8).
-define(CROSS_PX, 7.0).
-define(RING_MIN_PX, 6.0).
-define(RING_MAX_PX, 34.0).

palette() ->
	[{red, {220, 40, 40}},
	 {blue, {40, 90, 220}},
	 {green, {40, 170, 60}},
	 {black, {25, 25, 25}},
	 {white, {255, 255, 255}},
	 {cyan, {0, 190, 200}},
	 {grey, {130, 130, 130}},
	 {yellow, {230, 200, 0}},
	 {brown, {130, 85, 40}}].

-spec new_resources() -> resources().
new_resources() ->
	Colors = [{Name, color_kit(RGB)} || {Name, RGB} <- [{'$unknown', ?UNKNOWN_COLOR} | palette()]],
	#{colors => maps:from_list(Colors),
	  background => wxBrush:new(?BACKGROUND),
	  hud_brush => wxBrush:new({0, 0, 0, 160}),
	  font => wxFont:new(10, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL),
	  small_font => wxFont:new(8, ?wxFONTFAMILY_SWISS, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
	  banner_font => wxFont:new(16, ?wxFONTFAMILY_SWISS, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD)}.

color_kit(RGB) ->
	#{outline => wxPen:new(darken(RGB), [{width, 1}]),
	  stroke => wxPen:new(RGB, [{width, 2}]),
	  trail => wxPen:new(blend(RGB, ?BACKGROUND, 0.45), [{width, 2}]),
	  fill => wxBrush:new(RGB)}.

-spec free_resources(resources()) -> ok.
free_resources(#{colors := Colors, background := Bg, hud_brush := Hud, font := F, small_font := SF, banner_font := BF}) ->
	[begin wxPen:destroy(O), wxPen:destroy(S), wxPen:destroy(T), wxBrush:destroy(Fill) end
	 || #{outline := O, stroke := S, trail := T, fill := Fill} <- maps:values(Colors)],
	wxBrush:destroy(Bg),
	wxBrush:destroy(Hud),
	wxFont:destroy(F),
	wxFont:destroy(SF),
	wxFont:destroy(BF),
	ok.

%% DC must be a paint/memory DC that stays valid for the duration of the call.
-spec render(wx:wx_object(), {integer(), integer()}, scene(), resources()) -> ok.
render(DC, {W, H} = Size, Scene, Res) ->
	GC = wxGraphicsContext:create(DC),
	try
		wxGraphicsContext:setPen(GC, ?wxTRANSPARENT_PEN),
		wxGraphicsContext:setBrush(GC, maps:get(background, Res)),
		wxGraphicsContext:drawRectangle(GC, 0, 0, W, H),
		case maps:get(frame, Scene) of
			undefined -> ok;
			#{shapes := Shapes} ->
				Cam = maps:get(camera, Scene),
				draw_trails(GC, Cam, maps:get(trails, Scene, []), Res),
				draw_shapes(GC, Size, Cam, Shapes, Res),
				draw_deaths(GC, Cam, maps:get(deaths, Scene, []), Res),
				draw_selected(GC, Cam, maps:get(selected, Scene, undefined), maps:get(frame, Scene))
		end,
		draw_hud(GC, maps:get(hud, Scene), Res),
		draw_chart(GC, Size, maps:get(chart, Scene, undefined), Res),
		draw_banner(GC, Size, maps:get(banner, Scene), Res)
	after
		wxGraphicsContext:destroy(GC)
	end,
	ok.

%%==================================================================== shapes

draw_trails(GC, Cam, Trails, Res) ->
	lists:foreach(
		fun({Color, Points = [_, _ | _]}) ->
			wxGraphicsContext:setPen(GC, maps:get(trail, kit(Color, Res))),
			wxGraphicsContext:strokeLines(GC, screen_points(Cam, Points));
		   (_Short) ->
			ok
		end, Trails).

draw_shapes(GC, Size, Cam, Shapes, Res) ->
	lists:foreach(fun(Shape) -> draw_shape(GC, Size, Cam, Shape, Res) end, Shapes).

draw_shape(GC, {W, H}, Cam, {circle, Color, Center, R}, Res) ->
	{SX, SY} = visor_camera:to_screen(Cam, Center),
	SR = max(?MIN_RADIUS_PX, visor_camera:scale(Cam, R)),
	Visible = SX + SR >= 0 andalso SX - SR =< W andalso SY + SR >= 0 andalso SY - SR =< H,
	case Visible of
		true ->
			#{outline := Pen, fill := Brush} = kit(Color, Res),
			wxGraphicsContext:setPen(GC, Pen),
			wxGraphicsContext:setBrush(GC, Brush),
			wxGraphicsContext:drawEllipse(GC, SX - SR, SY - SR, 2 * SR, 2 * SR);
		false ->
			ok
	end;
draw_shape(GC, _Size, Cam, {line, Color, Coords}, Res) when length(Coords) >= 2 ->
	wxGraphicsContext:setPen(GC, maps:get(stroke, kit(Color, Res))),
	wxGraphicsContext:strokeLines(GC, screen_points(Cam, Coords));
draw_shape(GC, _Size, Cam, {arrow, Color, Coords}, Res) when length(Coords) >= 2 ->
	Points = screen_points(Cam, Coords),
	wxGraphicsContext:setPen(GC, maps:get(stroke, kit(Color, Res))),
	wxGraphicsContext:strokeLines(GC, Points),
	[Tip, Tail | _] = lists:reverse(Points),
	wxGraphicsContext:strokeLines(GC, arrow_head(Tail, Tip));
draw_shape(GC, _Size, Cam, {polygon, Color, Coords}, Res) when length(Coords) >= 3 ->
	#{outline := Pen, fill := Brush} = kit(Color, Res),
	wxGraphicsContext:setPen(GC, Pen),
	wxGraphicsContext:setBrush(GC, Brush),
	wxGraphicsContext:drawLines(GC, screen_points(Cam, Coords));
draw_shape(_GC, _Size, _Cam, _Degenerate, _Res) ->
	ok.

screen_points(Cam, Coords) ->
	[visor_camera:to_screen(Cam, P) || P <- Coords].

arrow_head({TX, TY}, {X, Y}) ->
	Angle = math:atan2(Y - TY, X - TX),
	Wing = fun(Delta) ->
		A = Angle + math:pi() + Delta,
		{X + ?ARROW_HEAD_PX * math:cos(A), Y + ?ARROW_HEAD_PX * math:sin(A)}
	end,
	[Wing(0.45), {X, Y}, Wing(-0.45)].

kit(Color, #{colors := Colors}) ->
	case Colors of
		#{Color := Kit} -> Kit;
		#{'$unknown' := Kit} -> Kit
	end.

%%==================================================================== death markers

%% Markers fade, so their pens carry an alpha and are made per marker; there are
%% at most a few hundred of them, unlike the shapes, which use the cached kits.
draw_deaths(GC, Cam, Prims, Res) ->
	lists:foreach(fun(P) -> draw_death(GC, Cam, P, Res) end, Prims).

draw_death(GC, Cam, {cross, Color, Loc, Alpha}, _Res) ->
	{X, Y} = visor_camera:to_screen(Cam, Loc),
	D = ?CROSS_PX,
	Arms = [[{X - D, Y - D}, {X + D, Y + D}], [{X - D, Y + D}, {X + D, Y - D}]],
	with_pen(GC, {255, 255, 255}, Alpha, 6, ?wxPENSTYLE_SOLID,
		fun() -> [wxGraphicsContext:strokeLines(GC, A) || A <- Arms] end),
	with_pen(GC, rgb(Color), Alpha, 3, ?wxPENSTYLE_SOLID,
		fun() -> [wxGraphicsContext:strokeLines(GC, A) || A <- Arms] end);
draw_death(GC, Cam, {label, Color, Loc, Text, Alpha}, #{small_font := Font}) ->
	{X, Y} = visor_camera:to_screen(Cam, Loc),
	wxGraphicsContext:setFont(GC, Font, rgba(darken(rgb(Color)), Alpha)),
	wxGraphicsContext:drawText(GC, unicode:characters_to_list(Text), X + ?CROSS_PX + 3, Y - ?CROSS_PX - 4);
draw_death(GC, Cam, {link, Color, From, To, Alpha}, _Res) ->
	with_pen(GC, rgb(Color), Alpha * 0.8, 2, ?wxPENSTYLE_SHORT_DASH,
		fun() -> wxGraphicsContext:strokeLines(GC, [visor_camera:to_screen(Cam, From), visor_camera:to_screen(Cam, To)]) end);
draw_death(GC, Cam, {ring, Color, Loc, Progress}, _Res) ->
	{X, Y} = visor_camera:to_screen(Cam, Loc),
	R = ?RING_MIN_PX + (?RING_MAX_PX - ?RING_MIN_PX) * Progress,
	wxGraphicsContext:setBrush(GC, ?wxTRANSPARENT_BRUSH),
	with_pen(GC, rgb(Color), 1.0 - Progress, 3, ?wxPENSTYLE_SOLID,
		fun() -> wxGraphicsContext:drawEllipse(GC, X - R, Y - R, 2 * R, 2 * R) end);
draw_death(_GC, _Cam, _Unknown, _Res) ->
	ok.

with_pen(GC, RGB, Alpha, Width, Style, Fun) ->
	Pen = wxPen:new(rgba(RGB, Alpha), [{width, Width}, {style, Style}]),
	try
		wxGraphicsContext:setPen(GC, Pen),
		Fun()
	after
		wxPen:destroy(Pen)
	end.

rgb(Color) ->
	proplists:get_value(Color, palette(), ?UNKNOWN_COLOR).

rgba({R, G, B}, Alpha) ->
	{R, G, B, max(0, min(255, round(255 * Alpha)))}.

%%==================================================================== overlays

%% Yellow ring around the avatar whose genome is shown (when it is in the arena).
draw_selected(_GC, _Cam, undefined, _Frame) ->
	ok;
draw_selected(GC, Cam, Pid, #{agents := Agents}) ->
	case lists:keyfind(Pid, 1, Agents) of
		{Pid, _Color, Loc} ->
			{X, Y} = visor_camera:to_screen(Cam, Loc),
			R = ?RING_MIN_PX * 2.5,
			with_pen(GC, {230, 200, 0}, 1.0, 3, ?wxPENSTYLE_SOLID, fun() ->
				wxGraphicsContext:setBrush(GC, ?wxTRANSPARENT_BRUSH),
				wxGraphicsContext:drawEllipse(GC, X - R, Y - R, 2 * R, 2 * R)
			end);
		false ->
			ok
	end;
draw_selected(_GC, _Cam, _Pid, _Frame) ->
	ok.

-define(CHART_W, 440).
-define(CHART_H, 220).

%% Bottom-right panel. All species share the x axis (population evaluations) so the
%% predator/prey arms race reads side by side. Per species, in its colour:
%%   thick solid = long moving median (the trend), thin faint = short moving
%%   median, one dot per finished agent (clamped at the top edge when above the axis) and
%%   a dashed line for the median fitness of the species' pool of survivors (the real progress).
%%   The y axis fits the dots' typical values and the medians; best ever is in the HUD text.
draw_chart(_GC, _Size, undefined, _Res) ->
	ok;
draw_chart(GC, {W, H}, #{series := Series, x_range := {XMin, XMax}, y_max := YMax,
		short := Short, long := Long}, #{font := Font, small_font := Small, hud_brush := Brush}) ->
	X0 = W - ?CHART_W - 10, Y0 = H - ?CHART_H - 10,
	Left = 40, Top = 42, Bottom = 22, Right = 12,
	PW = ?CHART_W - Left - Right, PH = ?CHART_H - Top - Bottom,
	PX = X0 + Left, PY = Y0 + Top,
	ToScreen = fun({X, Y}) -> {PX + PW * (X - XMin) / (XMax - XMin), PY + PH * (1 - Y / YMax)} end,
	wxGraphicsContext:setPen(GC, ?wxTRANSPARENT_PEN),
	wxGraphicsContext:setBrush(GC, Brush),
	wxGraphicsContext:drawRoundedRectangle(GC, X0, Y0, ?CHART_W, ?CHART_H, 6),
	wxGraphicsContext:setFont(GC, Font, {255, 255, 255}),
	wxGraphicsContext:drawText(GC, "Fitness of finished agents", X0 + 8, Y0 + 5),
	wxGraphicsContext:setFont(GC, Small, {220, 220, 220}),
	wxGraphicsContext:drawText(GC, io_lib:format("dots: agents  thick: median of last ~p  thin: of last ~p  dashed: pool median",
		[Long, Short]), X0 + 8, Y0 + 24),
	wxGraphicsContext:drawText(GC, io_lib:format("~.2f", [float(YMax)]), X0 + 4, PY - 6),
	wxGraphicsContext:drawText(GC, "0", X0 + 24, PY + PH - 6),
	wxGraphicsContext:drawText(GC, io_lib:format("~p", [round(XMin)]), PX, PY + PH + 4),
	XMaxText = io_lib:format("~p evaluations", [round(XMax)]),
	{TW, _, _, _} = wxGraphicsContext:getTextExtent(GC, XMaxText),
	wxGraphicsContext:drawText(GC, XMaxText, PX + PW - TW, PY + PH + 4),
	with_pen(GC, {200, 200, 200}, 0.6, 1, ?wxPENSTYLE_SOLID, fun() ->
		wxGraphicsContext:strokeLines(GC, [{PX, PY}, {PX, PY + PH}, {PX + PW, PY + PH}])
	end),
	Stroke = fun(_RGB, _Alpha, _Width, _Style, Points) when length(Points) < 2 -> ok;
	            (RGB, Alpha, Width, Style, Points) ->
		with_pen(GC, RGB, Alpha, Width, Style, fun() ->
			wxGraphicsContext:strokeLines(GC, [ToScreen(P) || P <- Points])
		end)
	end,
	lists:foldl(
		fun(#{morphology := Morphology, short := ShortPs, long := LongPs, dots := Dots, pool := PoolPs}, LegendX) ->
			RGB = chart_rgb(Morphology),
			draw_dots(GC, RGB, [ToScreen({X, min(Y, YMax)}) || {X, Y} <- Dots]),
			Stroke(RGB, 0.45, 1, ?wxPENSTYLE_SOLID, ShortPs),
			Stroke(RGB, 1.0, 3, ?wxPENSTYLE_SOLID, LongPs),
			Stroke(RGB, 1.0, 2, ?wxPENSTYLE_SHORT_DASH, [{X, min(Y, YMax)} || {X, Y} <- PoolPs]),
			wxGraphicsContext:setFont(GC, Small, RGB),
			Label = atom_to_list(Morphology),
			wxGraphicsContext:drawText(GC, Label, LegendX, PY + 2),
			{LW, _, _, _} = wxGraphicsContext:getTextExtent(GC, Label),
			LegendX + LW + 12
		end, PX + 8, Series),
	ok.

draw_dots(GC, {R, G, B}, Points) ->
	Brush = wxBrush:new({R, G, B, 110}),
	with_pen(GC, {R, G, B}, 0.0, 1, ?wxPENSTYLE_SOLID, fun() ->
		wxGraphicsContext:setBrush(GC, Brush),
		[wxGraphicsContext:drawEllipse(GC, X - 2, Y - 2, 4, 4) || {X, Y} <- Points]
	end),
	wxBrush:destroy(Brush).

%% The chart sits on the dark HUD panel, so it uses brighter tints than the scene.
chart_rgb(prey) -> {120, 200, 255};
chart_rgb(predator) -> {255, 95, 85};
chart_rgb(Morphology) -> rgb(morphology_color(Morphology)).

morphology_color(prey) -> blue;
morphology_color(predator) -> red;
morphology_color(_) -> black.

draw_hud(_GC, [], _Res) ->
	ok;
draw_hud(GC, Lines, #{font := Font, hud_brush := Brush}) ->
	wxGraphicsContext:setFont(GC, Font, {255, 255, 255}),
	Extents = [wxGraphicsContext:getTextExtent(GC, Line) || Line <- Lines],
	LineH = lists:max([LH || {_, LH, _, _} <- Extents]),
	BoxW = lists:max([LW || {LW, _, _, _} <- Extents]) + 2 * ?HUD_PAD,
	BoxH = LineH * length(Lines) + 2 * ?HUD_PAD,
	wxGraphicsContext:setPen(GC, ?wxTRANSPARENT_PEN),
	wxGraphicsContext:setBrush(GC, Brush),
	wxGraphicsContext:drawRoundedRectangle(GC, 6, 6, BoxW, BoxH, 6),
	lists:foldl(
		fun(Line, Y) ->
			wxGraphicsContext:drawText(GC, Line, 6 + ?HUD_PAD, Y),
			Y + LineH
		end, 6 + ?HUD_PAD, Lines),
	ok.

draw_banner(_GC, _Size, undefined, _Res) ->
	ok;
draw_banner(GC, {W, H}, Text, #{banner_font := Font}) ->
	wxGraphicsContext:setFont(GC, Font, {160, 30, 30}),
	{TW, TH, _, _} = wxGraphicsContext:getTextExtent(GC, Text),
	wxGraphicsContext:drawText(GC, Text, (W - TW) / 2, (H - TH) / 2).

blend({R, G, B}, {R0, G0, B0}, A) ->
	{round(R * A + R0 * (1 - A)), round(G * A + G0 * (1 - A)), round(B * A + B0 * (1 - A))}.

darken({R, G, B}) when R + G + B > 600 -> {110, 110, 110};
darken({R, G, B}) -> {round(R * 0.55), round(G * 0.55), round(B * 0.55)}.
