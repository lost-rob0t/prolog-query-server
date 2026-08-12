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

:- http_handler(root(.), index_handler, [method(get)]).
:- http_handler(root(health), health_handler, [method(get)]).
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

health_status(Auth, "ok") :- get_dict(configured, Auth, true), !.
health_status(_Auth, "degraded").

facts_handler(Request) :-
    secured_api_call(Request, write,
                     (read_json(Request, Input), kb_service:save_fact(Input, Saved),
                      reply_json_dict(Saved, [status(201)]))).
rules_handler(Request) :-
    secured_api_call(Request, write,
                     (read_json(Request, Input), kb_service:save_rule(Input, Saved),
                      reply_json_dict(Saved, [status(201)]))).

knowledge_document_handler(Request) :-
    memberchk(method(Method), Request),
    document_capability(Method, Capability),
    secured_api_call(Request, Capability, knowledge_document_method(Method, Request)).

document_capability(get, read).
document_capability(put, write).
document_capability(patch, write).
document_capability(delete, write).
document_capability(Method, _) :- throw(error(domain_error(knowledge_document_method, Method), _)).

knowledge_document_method(get, Request) :-
    http_parameters(Request, [id(IdAtom, [])]), atom_string(IdAtom, Id),
    kb_service:knowledge_document(Id, Document), reply_json_dict(_{document:Document}).
knowledge_document_method(put, Request) :-
    read_json(Request, Input), kb_service:put_knowledge_document(Input, Saved), reply_json_dict(Saved).
knowledge_document_method(patch, Request) :-
    read_json(Request, Input), kb_service:patch_knowledge_document(Input, Saved), reply_json_dict(Saved).
knowledge_document_method(delete, Request) :-
    http_parameters(Request, [id(IdAtom, []), rev(RevisionAtom, [])]),
    atom_string(IdAtom, Id), atom_string(RevisionAtom, Revision),
    kb_service:delete_knowledge_document(Id, Revision, Saved), reply_json_dict(Saved).

bulk_handler(Request) :-
    secured_api_call(Request, write,
                     (read_json(Request, Input), kb_service:bulk_knowledge_documents(Input, Saved),
                      reply_json_dict(Saved))).

builtins_handler(Request) :-
    secured_api_call(Request, read,
                     (builtins:builtin_catalog(Catalog), reply_json_dict(Catalog))).

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
                     (read_json(Request, Input), query_request(Input, false, KB, Goal, Options),
                      kb_service:query_kb(KB, Goal, Options, Result), reply_json_dict(Result))).
explain_handler(Request) :-
    secured_api_call(Request, read,
                     (read_json(Request, Input), query_request(Input, true, KB, Goal, Options),
                      kb_service:query_kb(KB, Goal, Options, Result), reply_json_dict(Result))).
reload_handler(Request) :-
    secured_api_call(Request, read,
                     ( read_json(Request, Input), input_kb(Input, KB),
                       optional(Input, release, null, Release), reload_release(KB, Release, Stats),
                       reply_json_dict(_{kb:KB, refresh:Stats}) )).
knowledge_handler(Request) :-
    secured_api_call(Request, read,
                     ( http_parameters(Request, [kb(KBAtom,[default(default)]), release(ReleaseAtom,[default('')])]),
                       atom_string(KBAtom, KB), knowledge_for_release(KB, ReleaseAtom, Release, Documents),
                       length(Documents, Count),
                       reply_json_dict(_{kb:KB,release:Release,count:Count,documents:Documents}) )).
releases_handler(Request) :-
    secured_api_call(Request, read,
                     (http_parameters(Request,[kb(KBAtom,[default(default)])]), atom_string(KBAtom,KB),
                      kb_service:release_status(KB,Status), reply_json_dict(Status))).

activate_release_handler(Request) :-
    secured_api_call(Request, write,
                     ( read_json(Request, Input),
                       optional(Input, strict, false, Strict),
                       bool(Strict),
                       activate_release(Strict, Input, Saved),
                       reply_json_dict(Saved)
                     )).

activate_release(true, Input, Saved) :- !, analysis_service:activate_release_strict(Input, Saved).
activate_release(false, Input, Saved) :- kb_service:activate_release(Input, Saved).

secured_api_call(Request, Capability, Goal) :- api_call((auth:authorize(Request, Capability), Goal)).

query_request(Input, ForceTrace, KB, Goal, Options) :-
    input_kb(Input, KB), required(Input, goal, Goal),
    optional(Input,max_depth,32,MaxDepth), optional(Input,max_solutions,100,MaxSolutions),
    optional(Input,refresh,true,Refresh), optional(Input,trace,false,RequestedTrace),
    optional(Input,release,null,Release), optional(Input,explanation_mode,"full",ExplanationMode),
    bool(Refresh), bool(RequestedTrace),
    (ForceTrace == true -> Trace=true ; Trace=RequestedTrace),
    Options=[max_depth(MaxDepth),max_solutions(MaxSolutions),refresh(Refresh),trace(Trace),
             release(Release),explanation_mode(ExplanationMode)].

reload_release(KB, null, Stats) :- !, kb_service:refresh_kb(KB, Stats).
reload_release(KB, Release, Stats) :- kb_service:refresh_kb(KB, Release, Stats).
knowledge_for_release(KB, '', Release, Documents) :- !,
    kb_service:release_status(KB, Status), get_dict(active_release,Status,Release),
    kb_service:knowledge_documents(KB,Release,Documents).
knowledge_for_release(KB, ReleaseAtom, Release, Documents) :-
    atom_string(ReleaseAtom,Release), kb_service:knowledge_documents(KB,Release,Documents).

input_kb(Input, KB) :-
    optional(Input,kb,"default",KB), must_be(string,KB), string_length(KB,Length), Length>0.
read_json(Request, Dict) :- http_read_json_dict(Request,Dict), must_be(dict,Dict).
api_call(Goal) :- catch(Goal,Error,reply_api_error(Error)).
reply_api_error(Error) :- error_status(Error,Status), reply_error_with_status(Error,Status).
reply_error_with_status(Error, Status) :- message_to_string(Error,Message), reply_json_dict(_{error:Message},[status(Status)]).

error_status(error(permission_error(access,api_authentication,_),_),401) :- !.
error_status(error(permission_error(access,api_capability,_),_),403) :- !.
error_status(error(existence_error(environment_variable,_),_),503) :- !.
error_status(error(permission_error(activate,invalid_knowledge_release,_),_),409) :- !.
error_status(error(couchdb_error(409,_),_),409) :- !.
error_status(error(couchdb_error(_,_),_),502) :- !.
error_status(error(existence_error(knowledge_document,_),_),404) :- !.
error_status(error(permission_error(modify,active_knowledge_release,_),_),409) :- !.
error_status(error(permission_error(modify,knowledge_document_identity(_,_),_),409) :- !.
error_status(error(existence_error(knowledge_base,_),_),409) :- !.
error_status(_,400).

required(Dict,Key,Value) :- (get_dict(Key,Dict,Value)->true;throw(error(existence_error(key,Key),_))).
optional(Dict,Key,Default,Value) :- (get_dict(Key,Dict,V)->Value=V;Value=Default).
bool(true).
bool(false).
bool(Value) :- throw(error(type_error(boolean,Value),_)).
