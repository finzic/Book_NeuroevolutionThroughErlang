%% This source code and work is provided and developed by DXNN Research Group WWW.DXNNResearch.COM
%%
%Copyright (C) 2009 by Gene Sher, DXNN Research Group, CorticalComputer@gmail.com
%All rights reserved.
%
%This code is licensed under the version 3 of the GNU General Public License. Please see the LICENSE file that accompanies this project for the terms of use.

%% Pure world <-> screen transform for the visor. A camera is the book's original
%% "filter" tuple {Zoom,PanX,PanY}: ScreenX = X*Zoom + PanX, ScreenY = Y*Zoom + PanY.
-module(visor_camera).

-export([new/0, to_screen/2, to_world/2, pan/3, zoom_at/3, fit/2, scale/2]).
-export_type([camera/0]).

-type camera() :: {Zoom :: float(), PanX :: float(), PanY :: float()}.

-define(MIN_ZOOM, 0.001).
-define(MAX_ZOOM, 1000.0).
-define(FIT_MARGIN, 0.9).

-spec new() -> camera().
new() -> {1.0, 0.0, 0.0}.

-spec to_screen(camera(), {number(), number()}) -> {float(), float()}.
to_screen({Z, PX, PY}, {X, Y}) -> {X * Z + PX, Y * Z + PY}.

-spec to_world(camera(), {number(), number()}) -> {float(), float()}.
to_world({Z, PX, PY}, {SX, SY}) -> {(SX - PX) / Z, (SY - PY) / Z}.

-spec scale(camera(), number()) -> float().
scale({Z, _, _}, Length) -> Length * Z.

-spec pan(camera(), number(), number()) -> camera().
pan({Z, PX, PY}, DX, DY) -> {Z, PX + DX, PY + DY}.

%% Zooms by Factor while keeping the world point under screen point Anchor fixed.
-spec zoom_at(camera(), number(), {number(), number()}) -> camera().
zoom_at({Z, _, _} = Cam, Factor, {SX, SY} = Anchor) ->
	Z1 = clamp(Z * Factor),
	{WX, WY} = to_world(Cam, Anchor),
	{Z1, SX - WX * Z1, SY - WY * Z1}.

-spec fit({number(), number(), number(), number()} | undefined, {pos_integer(), pos_integer()}) -> camera().
fit(undefined, _Size) ->
	new();
fit({X0, Y0, X1, Y1}, {W, H}) ->
	BW = max(X1 - X0, 1),
	BH = max(Y1 - Y0, 1),
	Z = clamp(?FIT_MARGIN * min(W / BW, H / BH)),
	{CX, CY} = {(X0 + X1) / 2, (Y0 + Y1) / 2},
	{Z, W / 2 - CX * Z, H / 2 - CY * Z}.

clamp(Z) -> min(?MAX_ZOOM, max(?MIN_ZOOM, float(Z))).
