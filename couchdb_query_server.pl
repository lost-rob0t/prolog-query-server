:- use_module(library(http/json)).
:- use_module(library(lists), [memberchk/2]).
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
        catch(dispatch_command(Message, Reply),
              Error,
              error_reply(Error, Reply)),
        write_reply(Reply),
        protocol_loop
    ).

% CouchDB validates every view function in a design document through add_fun/1,
% including reduce functions. Reducers are already parsed again when CouchDB
% sends reduce/rereduce, so registration only needs to validate and acknowledge
% the small reducer whitelist. Crucially, reducers are not added to map_function/2.
dispatch_command(["add_fun", Source], true) :-
    reduce_registration_source(Source),
    !.
dispatch_command(Message, Reply) :-
    query_server_protocol:handle_command(Message, Reply).

reduce_registration_source(Source) :-
    text_atom(Source, Atom),
    catch(read_term_from_atom(Atom,
                              Reducer,
                              [ syntax_errors(error),
                                variable_names(Variables)
                              ]),
          _,
          fail),
    Variables == [],
    memberchk(Reducer, [sum, count, min, max, stats]).

text_atom(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
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
