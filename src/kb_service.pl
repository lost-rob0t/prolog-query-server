:- module(kb_service,
          [ refresh_kb/2,
            query_kb/4,
            knowledge_documents/2,
            save_fact/2,
            save_rule/2
          ]).

:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(couchdb).
:- use_module(expert_system).

refresh_kb(KB, Stats) :-
    kb_mutex(KB, Mutex),
    with_mutex(Mutex, refresh_kb_unlocked(KB, Stats)).

query_kb(KB, Query, Options, Result) :-
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( ensure_query_snapshot(KB, Options, RefreshStats),
                 expert_system:run_query(KB, Query, Options, QueryResult),
                 put_dict(refresh, QueryResult, RefreshStats, Result)
               )).

knowledge_documents(KB, Documents) :-
    couchdb:find_kb_documents(KB, Documents).

save_fact(Input, Saved) :-
    normalize_kb(Input, KB),
    normalize_enabled(Input, Enabled),
    put_dict(_{type:"prolog_fact", kb:KB, enabled:Enabled}, Input, Document),
    expert_system:validate_document(Document),
    couchdb:save_document(Document, CouchReply),
    Saved = _{document:Document, couchdb:CouchReply}.

save_rule(Input, Saved) :-
    normalize_kb(Input, KB),
    normalize_enabled(Input, Enabled),
    put_dict(_{type:"prolog_rule", kb:KB, enabled:Enabled}, Input, Document),
    expert_system:validate_document(Document),
    couchdb:save_document(Document, CouchReply),
    Saved = _{document:Document, couchdb:CouchReply}.

ensure_query_snapshot(KB, Options, Stats) :-
    option(refresh(Refresh), Options, true),
    (   Refresh == true
    ->  refresh_kb_unlocked(KB, Stats)
    ;   expert_system:knowledge_base_loaded(KB)
    ->  Stats = _{reloaded:false}
    ;   refresh_kb_unlocked(KB, Stats)
    ).

refresh_kb_unlocked(KB, Stats) :-
    couchdb:find_kb_documents(KB, Documents),
    expert_system:replace_kb(KB, Documents, LoadStats),
    length(Documents, DocumentCount),
    put_dict(_{reloaded:true, documents:DocumentCount}, LoadStats, Stats).

normalize_kb(Input, KB) :-
    (   get_dict(kb, Input, KB0)
    ->  KB = KB0
    ;   KB = "default"
    ),
    must_be(string, KB),
    string_length(KB, Length),
    Length > 0.

normalize_enabled(Input, Enabled) :-
    (   get_dict(enabled, Input, Enabled0)
    ->  Enabled = Enabled0
    ;   Enabled = true
    ),
    (   memberchk(Enabled, [true, false])
    ->  true
    ;   throw(error(type_error(boolean, Enabled), _))
    ).

kb_mutex(KB, Mutex) :-
    term_hash(KB, Hash),
    format(atom(Mutex), 'prolog-kb-~d', [Hash]).
