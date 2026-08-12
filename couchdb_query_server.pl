:- use_module(library(http/json)).
:- use_module(src/query_server_protocol).

:- initialization(main, main).

main :-
    set_stream(user_output, buffer(false)),
    query_server_protocol:reset_state,
    protocol_loop.

protocol_loop :-
    json_read(user_input,
              Raw,
              [ value_string_as(string),
                null(null),
                true(true),
                false(false),
                end_of_file(end_of_file)
              ]),
    (   Raw == end_of_file
    ->  true
    ;   normalize_json(Raw, Message),
        catch(query_server_protocol:handle_command(Message, Reply),
              Error,
              error_reply(Error, Reply)),
        write_reply(Reply),
        protocol_loop
    ).

error_reply(Error, ["error", "prolog_query_server", Message]) :-
    message_to_string(Error, Message).

write_reply(Reply) :-
    json_write_dict(user_output, Reply, [width(0)]),
    nl,
    flush_output.

normalize_json(json(Pairs), Dict) :-
    !,
    maplist(normalize_pair, Pairs, NormalizedPairs),
    dict_create(Dict, json, NormalizedPairs).
normalize_json(List, Normalized) :-
    is_list(List),
    !,
    maplist(normalize_json, List, Normalized).
normalize_json(Value, Value).

normalize_pair(Key=Value, Key-Normalized) :-
    !,
    normalize_json(Value, Normalized).
normalize_pair(Key-Value, Key-Normalized) :-
    normalize_json(Value, Normalized).
