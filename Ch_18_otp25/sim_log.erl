%% Switchable console output for the simulation.
%%
%% The book's modules print a lot with io:format, several lines per agent per
%% evaluation, and at maximum speed writing to the terminal costs real time.
%% Instead of touching every io:format, this process is an I/O server that
%% sim.erl makes the group leader of everything it starts (polis, scapes,
%% population monitor and, by inheritance, every agent they spawn).
%%   on:  each request is passed to the real group leader (the shell)
%%   off: output requests are answered 'ok' and dropped, so nothing is
%%        formatted or written; input requests still go through.
%%
%% sim_log:toggle(). sim_log:on(). sim_log:off(). sim_log:enabled().
%% Key V in the visor window toggles it too.
-module(sim_log).

-export([ensure/0, with/1, on/0, off/0, toggle/0, enabled/0]).

-define(NAME, sim_log).

%% Start the gate (once) on top of the caller's group leader.
ensure() ->
	case whereis(?NAME) of
		undefined ->
			Real = group_leader(),
			Parent = self(),
			Pid = spawn(fun() -> init(Parent, Real) end),
			receive {?NAME, Pid, Result} -> Result end,
			whereis(?NAME);
		Pid ->
			Pid
	end.

%% Run Fun with the gate as the caller's group leader, so every process Fun
%% starts inherits it.
with(Fun) ->
	Gate = ensure(),
	Old = group_leader(),
	group_leader(Gate, self()),
	try Fun()
	after group_leader(Old, self())
	end.

on() -> set(true).
off() -> set(false).
toggle() -> call(toggle).
enabled() ->
	case whereis(?NAME) of
		undefined -> true;
		_ -> call(enabled)
	end.

set(Bool) -> call({set, Bool}).

call(Msg) ->
	Pid = ensure(),
	Ref = monitor(process, Pid),
	Pid ! {?NAME, self(), Ref, Msg},
	receive
		{Ref, Reply} -> demonitor(Ref, [flush]), Reply;
		{'DOWN', Ref, process, _, Reason} -> error({sim_log_down, Reason})
	end.

%%====================================================================

init(Parent, Real) ->
	Result = try register(?NAME, self()) of true -> ok
		catch error:badarg -> already_started
		end,
	Parent ! {?NAME, self(), Result},
	case Result of
		ok ->
			%% Follow the shell's group leader: if it goes away there is nobody to print to.
			link(Real),
			loop(Real, true);
		already_started ->
			ok
	end.

loop(Real, Enabled) ->
	receive
		{io_request, From, ReplyAs, Request} = Msg ->
			case Enabled orelse not is_output(Request) of
				true -> Real ! Msg;
				false -> From ! {io_reply, ReplyAs, ok}
			end,
			loop(Real, Enabled);
		{?NAME, From, Ref, toggle} ->
			From ! {Ref, not Enabled},
			loop(Real, not Enabled);
		{?NAME, From, Ref, {set, Bool}} ->
			From ! {Ref, Bool},
			loop(Real, Bool);
		{?NAME, From, Ref, enabled} ->
			From ! {Ref, Enabled},
			loop(Real, Enabled);
		_Other ->
			loop(Real, Enabled)
	end.

is_output({put_chars, _Chars}) -> true;
is_output({put_chars, _Enc, _Chars}) -> true;
is_output({put_chars, _M, _F, _A}) -> true;
is_output({put_chars, _Enc, _M, _F, _A}) -> true;
is_output({requests, Requests}) -> lists:all(fun is_output/1, Requests);
is_output(_) -> false.
