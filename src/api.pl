:- module(api, []).

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_parameters)).
:- use_module(library(error)).
:- use_module(couchdb).
:- use_module(kb_service).

:- http_handler(root(.), index_handler, [method(get)]).
:- http_handler(root(health), health_handler, [method(get)]).
:- http_handler(root('v1/facts'), facts_handler, [method(post)]).
:- http_handler(root('v1/rules'), rules_handler, [method(post)]).
:- http_handler(root('v1/query'), query_handler, [method(post)]).
:- http_handler(root('v1/explain'), explain_handler, [method(post)]).
:- http_handler(root('v1/reload'), reload_handler, [method(post)]).
:- http_handler(root('v1/knowledge'), knowledge_handler, [method(get)]).

index_handler(_Request) :-
    reply_json_dict(_{service:"prolog-query-server",
                      version:"0.1.0",
                      storage:"couchdb",
                      engine:"swi-prolog"}).

health_handler(_Request) :-
    catch(( couchdb:health(CouchDB),
            reply_json_dict(_{status:"ok", couchdb:CouchDB})
          ),
          Error,
          reply_error_with_status(Error, 503)).

facts_handler(Request) :-
    api_call(( read_json(Request, Input),
               kb_service:save_fact(Input, Saved),
               reply_json_dict(Saved, [status(201)])
             )).

rules_handler(Request) :-
    api_call(( read_json(Request, Input),
               kb_service:save_rule(Input, Saved),
               reply_json_dict(Saved, [status(201)])
             )).

query_handler(Request) :-
    api_call(( read_json(Request, Input),
               query_request(Input, false, KB, Goal, Options),
               kb_service:query_kb(KB, Goal, Options, Result),
               reply_json_dict(Result)
             )).

explain_handler(Request) :-
    api_call(( read_json(Request, Input),
               query_request(Input, true, KB, Goal, Options),
               kb_service:query_kb(KB, Goal, Options, Result),
               reply_json_dict(Result)
             )).

reload_handler(Request) :-
    api_call(( read_json(Request, Input),
               input_kb(Input, KB),
               kb_service:refresh_kb(KB, Stats),
               reply_json_dict(_{kb:KB, refresh:Stats})
             )).

knowledge_handler(Request) :-
    api_call(( http_parameters(Request,
                               [ kb(KBAtom, [default(default)])
                               ]),
               atom_string(KBAtom, KB),
               kb_service:knowledge_documents(KB, Documents),
               length(Documents, Count),
               reply_json_dict(_{kb:KB, count:Count, documents:Documents})
             )).

query_request(Input, ForceTrace, KB, Goal, Options) :-
    input_kb(Input, KB),
    required(Input, goal, Goal),
    optional(Input, max_depth, 32, MaxDepth),
    optional(Input, max_solutions, 100, MaxSolutions),
    optional(Input, refresh, true, Refresh),
    optional(Input, trace, false, RequestedTrace),
    bool(Refresh),
    bool(RequestedTrace),
    (   ForceTrace == true
    ->  Trace = true
    ;   Trace = RequestedTrace
    ),
    Options = [ max_depth(MaxDepth),
                max_solutions(MaxSolutions),
                refresh(Refresh),
                trace(Trace)
              ].

input_kb(Input, KB) :-
    optional(Input, kb, "default", KB),
    must_be(string, KB),
    string_length(KB, Length),
    Length > 0.

read_json(Request, Dict) :-
    http_read_json_dict(Request, Dict),
    must_be(dict, Dict).

api_call(Goal) :-
    catch(Goal, Error, reply_api_error(Error)).

reply_api_error(Error) :-
    error_status(Error, Status),
    reply_error_with_status(Error, Status).

reply_error_with_status(Error, Status) :-
    message_to_string(Error, Message),
    reply_json_dict(_{error:Message}, [status(Status)]).

error_status(error(couchdb_error(_, _), _), 502) :- !.
error_status(error(existence_error(knowledge_base, _), _), 409) :- !.
error_status(_, 400).

required(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(error(existence_error(key, Key), _))
    ).

optional(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value0)
    ->  Value = Value0
    ;   Value = Default
    ).

bool(true).
bool(false).
bool(Value) :-
    throw(error(type_error(boolean, Value), _)).
