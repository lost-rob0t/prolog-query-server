:- module(config,
          [ server_port/1,
            couchdb_base_url/1,
            couchdb_database/1,
            couchdb_auth_options/1
          ]).

server_port(Port) :-
    env_number('PORT', 8080, Port).

couchdb_base_url(URL) :-
    env_atom('COUCHDB_URL', 'http://127.0.0.1:5984', URL).

couchdb_database(Database) :-
    env_atom('COUCHDB_DATABASE', 'prolog_kb', Database).

couchdb_auth_options(Options) :-
    (   getenv('COUCHDB_USER', User),
        getenv('COUCHDB_PASSWORD', Password),
        User \== '',
        Password \== ''
    ->  Options = [authorization(basic(User, Password))]
    ;   Options = []
    ).

env_atom(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== ''
    ->  Value = Raw
    ;   Value = Default
    ).

env_number(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== '',
        catch(atom_number(Raw, Parsed), _, fail)
    ->  Value = Parsed
    ;   Value = Default
    ).
