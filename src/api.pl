:- module(api, []).

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_parameters)).
:- use_module(library(error)).
:- use_module(couchdb).
:- use_module(kb_service).
:- use_module(analysis_service).
:- use_module(builtins).
:- use_module(auth).
:- use_module(metrics).
:- use_module(observability).

:- http_handler(root(.), index_handler, [method(get)]).
:- http_handler(root(health), health_handler, [method(get)]).
:- http_handler(root(metrics), metrics_handler, [method(get)]).
:- http_handler(root('v1/facts'), facts_handler, [method(post)]).
:- http_handler(root('v1/rules'), rules_handler, [method(post)]).
:- http_handler(root('v1/query'), query_handler, [method(post)]).
:- http_handler(root('v1/explain'), explain_handler, [method(post)]).
:- http_handler(root('v1/reload'), reload_handler, [method(post)]).
:- http_handler(root('v1/knowledge'), knowledge_handler, [method(get)]).
:- http_handler(root('v1/document'), knowledge_document_handler, []).
:- http_handler(root('v1/bulk'), bulk_handler, [method(post)]).
:- http_handler(root('v1/builtins'), builtins_handler, [method(get)]).
:- http_handler(root('v1/analyze'), analyze_handler, [method(post)]).
:- http_handler(root('v1/conflicts'), conflicts_handler, [method(get)]).
:- http_handler(root('v1/releases'), releases_handler, [method(get)]).
:- http_handler(root('v1/releases/activate'), activate_release_handler, [method(post)]).

index_handler(_Request) :-
    reply_json_dict(_{service:"prolog-query-server",
                      version:"0.7.0",
                      storage:"couchdb",
                      engine:"swi-prolog"}).

health_handler(_Request) :-
    catch(( couchdb:health(CouchDB),
            auth:auth_status(Auth),
            health_status(Auth, Status),
            reply_json_dict(_{status:Status, couchdb:CouchDB, auth:Auth})
          ),
          Error,
          reply_error_with_status(Error, 503)).

health_status(Auth, "ok") :-
    get_dict(configured, Auth, true),
    !.
health_status(_Auth, "degraded").

metrics_handler(Request) :-
    secured_api_call(Request, read,
                     ( metrics:prometheus_text(Text),
                       format('Content-type: text/plain; version=0.0.4; charset=UTF-8~n~n~w',
                              [Text])
                     )).

facts_handler(Request) :-
    secured_api_call(Request, write,
                     ( read_json(Request, Input),
                       kb_service:save_fact(Input, Saved),
                       metrics:increment_knowledge_write(fact_create),
                       reply_json_dict(Saved, [status(201)])
                     )).

rules_handler(Request) :-
    secured_api_call(Request, write,
                     ( read_json(Request, Input),
                       kb_service:save_rule(Input, Saved),
                       metrics:increment_knowledge_write(rule_create),
                       reply_json_dict(Saved, [status(201)])
                     )).

knowledge_document_handler(Request) :-
    memberchk(method(Method), Request),
    document_capability(Method, Capability),
    secured_api_call(Request, Capability, knowledge_document_method(Method, Request)).

document_capability(get, read).
document_capability(put, write).
document_capability(patch, write).
document_capability(delete, write).
document_capability(Method, _) :-
    throw(error(domain_error(knowledge_document_method, Method), _)).

knowledge_document_method(get, Request) :-
    http_parameters(Request, [id(IdAtom, [])]),
    atom_string(IdAtom, Id),
    kb_service:knowledge_document(Id, Document),
    reply_json_dict(_{document:Document}).
knowledge_document_method(put, Request) :-
    read_json(Request, Input),
    kb_service:put_knowledge_document(Input, Saved),
    metrics:increment_knowledge_write(document_put),
    reply_json_dict(Saved).
knowledge_document_method(patch, Request) :-
    read_json(Request, Input),
    kb_service:patch_knowledge_document(Input, Saved),
    metrics:increment_knowledge_write(document_patch),
    reply_json_dict(Saved).
knowledge_document_method(delete, Request) :-
    http_parameters(Request,
                    [ id(IdAtom, []),
                      rev(RevisionAtom, [])
                    ]),
    atom_string(IdAtom, Id),
    atom_string(RevisionAtom, Revision),
    kb_service:delete_knowledge_document(Id, Revision, Saved),
    metrics:increment_knowledge_write(document_delete),
    reply_json_dict(Saved).

bulk_handler(Request) :-
    secured_api_call(Request, write,
                     ( read_json(Request, Input),
                       kb_service:bulk_knowledge_documents(Input, Saved),
                       metrics:increment_knowledge_write(bulk),
                       reply_json_dict(Saved)
                     )).

builtins_handler(Request) :-
    secured_api_call(Request, read,
                     ( builtins:builtin_catalog(Catalog),
                       reply_json_dict(Catalog)
                     )).

conflicts_handler(Request) :-
    secured_api_call(Request, read,
                     ( http_parameters(Request,
                                       [ kb(KBAtom, [default(default)]),
                                         release(ReleaseAtom, [default('')])
                                       ]),
                       atom_string(KBAtom, KB),
                       conflicts_for_release(KB, ReleaseAtom, Conflicts),
                       length(Conflicts, Count),
                       reply_json_dict(_{kb:KB,
                                         count:Count,
                                         conflicts:Conflicts})
                     )).

conflicts_for_release(KB, '', Conflicts) :-
    !,
    kb_service:knowledge_conflicts(KB, Conflicts).
conflicts_for_release(KB, ReleaseAtom, Conflicts) :-
    atom_string(ReleaseAtom, Release),
    kb_service:knowledge_conflicts(KB, Release, Conflicts).

analyze_handler(Request) :-
    secured_api_call(Request, read,
                     ( read_json(Request, Input),
                       input_kb(Input, KB),
                       required(Input, release, Release),
                       analysis_service:analyze_release(KB, Release, Analysis),
                       reply_json_dict(Analysis)
                     )).

query_handler(Request) :-
    secured_api_call(Request, read,
                     ( read_json(Request, Input),
                       query_request(Input, false, KB, Goal, Options),
                       kb_service:query_kb(KB, Goal, Options, Result),
                       observe_query_result(Result, Options),
                       reply_json_dict(Result)
                     )).

explain_handler(Request) :-
    secured_api_call(Request, read,
                     ( read_json(Request, Input),
                       query_request(Input, true, KB, Goal, Options),
                       kb_service:query_kb(KB, Goal, Options, Result),
                       observe_query_result(Result, Options),
                       reply_json_dict(Result)
                     )).

observe_query_result(Result, Options) :-
    metrics:observe_query(Result, Options),
    (   get_dict(refresh, Result, Refresh)
    ->  metrics:observe_refresh(Refresh)
    ;   true
    ).

reload_handler(Request) :-
    secured_api_call(Request, read,
                     ( read_json(Request, Input),
                       input_kb(Input, KB),
                       optional(Input, release, null, Release),
                       reload_release(KB, Release, Stats),
                       metrics:observe_refresh(Stats),
                       reply_json_dict(_{kb:KB, refresh:Stats})
                     )).

knowledge_handler(Request) :-
    secured_api_call(Request, read,
                     ( http_parameters(Request,
                                       [ kb(KBAtom, [default(default)]),
                                         release(ReleaseAtom, [default('')])
                                       ]),
                       atom_string(KBAtom, KB),
                       knowledge_for_release(KB, ReleaseAtom, Release, Documents),
                       length(Documents, Count),
                       reply_json_dict(_{kb:KB,
                                         release:Release,
                                         count:Count,
                                         documents:Documents})
                     )).

releases_handler(Request) :-
    secured_api_call(Request, read,
                     ( http_parameters(Request,
                                       [kb(KBAtom, [default(default)])]),
                       atom_string(KBAtom, KB),
                       kb_service:release_status(KB, Status),
                       reply_json_dict(Status)
                     )).

activate_release_handler(Request) :-
    secured_api_call(Request, write,
                     ( read_json(Request, Input),
                       optional(Input, strict, false, Strict),
                       bool(Strict),
                       activate_release(Strict, Input, Saved),
                       metrics:increment_knowledge_write(release_activate),
                       reply_json_dict(Saved)
                     )).

activate_release(true, Input, Saved) :-
    !,
    analysis_service:activate_release_strict(Input, Saved).
activate_release(false, Input, Saved) :-
    kb_service:activate_release(Input, Saved).

secured_api_call(Request, Capability, Goal) :-
    request_endpoint(Request, Endpoint),
    observability:new_request_id(RequestId),
    get_time(Start),
    catch(( auth:authorize(Request, Capability),
            (   call(Goal)
            ->  Outcome = success
            ;   throw(error(api_handler_failed(Endpoint), _))
            )
          ),
          Error,
          Outcome = error(Error)),
    get_time(End),
    Duration is max(0.0, End - Start),
    complete_api_call(Outcome, RequestId, Endpoint, Capability, Duration).

complete_api_call(success, RequestId, Endpoint, Capability, Duration) :-
    metrics:observe_http(Endpoint, success, Duration),
    observability:log_request(RequestId, Endpoint, Capability, success, Duration).
complete_api_call(error(Error), RequestId, Endpoint, Capability, Duration) :-
    metrics:observe_http(Endpoint, error, Duration),
    metrics:observe_error(Error),
    observability:log_request(RequestId, Endpoint, Capability, error, Duration),
    reply_api_error(Error).

request_endpoint(Request, Endpoint) :-
    (   memberchk(path(Path), Request)
    ->  endpoint_path(Path, Endpoint)
    ;   Endpoint = other
    ).

endpoint_path('/metrics', metrics) :- !.
endpoint_path('/v1/facts', facts) :- !.
endpoint_path('/v1/rules', rules) :- !.
endpoint_path('/v1/query', query) :- !.
endpoint_path('/v1/explain', explain) :- !.
endpoint_path('/v1/reload', reload) :- !.
endpoint_path('/v1/knowledge', knowledge) :- !.
endpoint_path('/v1/document', document) :- !.
endpoint_path('/v1/bulk', bulk) :- !.
endpoint_path('/v1/builtins', builtins) :- !.
endpoint_path('/v1/analyze', analyze) :- !.
endpoint_path('/v1/conflicts', conflicts) :- !.
endpoint_path('/v1/releases', releases) :- !.
endpoint_path('/v1/releases/activate', release_activate) :- !.
endpoint_path(_, other).

query_request(Input, ForceTrace, KB, Goal, Options) :-
    input_kb(Input, KB),
    required(Input, goal, Goal),
    optional(Input, max_depth, 32, MaxDepth),
    optional(Input, max_solutions, 100, MaxSolutions),
    optional(Input, refresh, true, Refresh),
    optional(Input, trace, false, RequestedTrace),
    optional(Input, release, null, Release),
    optional(Input, explanation_mode, "full", ExplanationMode),
    bool(Refresh),
    bool(RequestedTrace),
    (   ForceTrace == true
    ->  Trace = true
    ;   Trace = RequestedTrace
    ),
    Options = [ max_depth(MaxDepth),
                max_solutions(MaxSolutions),
                refresh(Refresh),
                trace(Trace),
                release(Release),
                explanation_mode(ExplanationMode)
              ].

reload_release(KB, null, Stats) :-
    !,
    kb_service:refresh_kb(KB, Stats).
reload_release(KB, Release, Stats) :-
    kb_service:refresh_kb(KB, Release, Stats).

knowledge_for_release(KB, '', Release, Documents) :-
    !,
    kb_service:release_status(KB, Status),
    get_dict(active_release, Status, Release),
    kb_service:knowledge_documents(KB, Release, Documents).
knowledge_for_release(KB, ReleaseAtom, Release, Documents) :-
    atom_string(ReleaseAtom, Release),
    kb_service:knowledge_documents(KB, Release, Documents).

input_kb(Input, KB) :-
    optional(Input, kb, "default", KB),
    must_be(string, KB),
    string_length(KB, Length),
    Length > 0.

read_json(Request, Dict) :-
    http_read_json_dict(Request, Dict),
    must_be(dict, Dict).

reply_api_error(Error) :-
    error_status(Error, Status),
    reply_error_with_status(Error, Status).

reply_error_with_status(Error, Status) :-
    message_to_string(Error, Message),
    reply_json_dict(_{error:Message}, [status(Status)]).

error_status(error(permission_error(access, api_authentication, _), _), 401) :- !.
error_status(error(permission_error(access, api_capability, _), _), 403) :- !.
error_status(error(existence_error(environment_variable, _), _), 503) :- !.
error_status(error(permission_error(activate, invalid_knowledge_release, _), _), 409) :- !.
error_status(error(couchdb_error(409, _), _), 409) :- !.
error_status(error(couchdb_error(_, _), _), 502) :- !.
error_status(error(existence_error(knowledge_document, _), _), 404) :- !.
error_status(error(permission_error(load, conflicted_knowledge_document, _), _), 409) :- !.
error_status(error(permission_error(modify, _, _), _), 409) :- !.
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
