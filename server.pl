:- use_module(library(http/http_server)).
:- use_module(src/config).
:- use_module(src/api).

:- initialization(main, main).

main :-
    config:server_port(Port),
    http_server(http_dispatch, [port(Port)]),
    format(user_error, 'prolog-query-server listening on :~d~n', [Port]),
    thread_get_message(stop).
