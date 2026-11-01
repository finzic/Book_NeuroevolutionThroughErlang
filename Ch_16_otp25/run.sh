#!/bin/sh
# Compile this chapter into ./ebin and open an Erlang shell with it loaded.
cd "$(dirname "$0")" || exit 1
mkdir -p ebin
exec erl -pa ebin -eval 'case make:all([load]) of up_to_date -> ok; error -> io:format("~n*** compile FAILED ***~n") end.' "$@"
