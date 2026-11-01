#!/bin/sh
# Compile this chapter into ./ebin and open an Erlang shell with it loaded.
#   ./run.sh         just the shell
#   ./run.sh start   ...and start polis + visor + a new random population   (sim:start())
#   ./run.sh fresh   ...after wiping the whole database: all genomes from scratch (sim:fresh())
cd "$(dirname "$0")" || exit 1
mkdir -p ebin
case "$1" in
	start|fresh) RUN="sim:$1()"; shift ;;
	*) RUN="ok" ;;
esac
exec erl -pa ebin -eval "case make:all([load]) of up_to_date -> $RUN; error -> io:format(\"~n*** compile FAILED ***~n\") end." "$@"
