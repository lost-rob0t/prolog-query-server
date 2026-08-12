:- module(kb_service,
          [ refresh_kb/2,
            refresh_kb/3,
            query_kb/4,
            knowledge_documents/2,
            knowledge_documents/3,
            save_fact/2,
            save_rule/2,
            release_status/2,
            activate_release/2
          ]).

:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(couchdb).
:- use_module(expert_system).

:- dynamic kb_sequence/2.

refresh_kb(KB, Stats) :-
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( active_release(KB, Release, _Manifest),
                 refresh_release_unlocked(KB, Release, Stats)
               )).

refresh_kb(KB, Release0, Stats) :-
    normalize_release_value(Release0, Release),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex, refresh_release_unlocked(KB, Release, Stats)).

query_kb(KB, Query, Options, Result) :-
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( resolve_query_release(KB, Options, Release),
                 runtime_key(KB, Release, RuntimeKB),
                 ensure_query_snapshot(RuntimeKB,
                                       KB,
                                       Release,
                                       Options,
                                       RefreshStats),
                 expert_system:run_query(RuntimeKB,
                                         Query,
                                         Options,
                                         RawQueryResult),
                 put_dict(_{kb:KB, release:Release},
                          RawQueryResult,
                          QueryResult),
                 put_dict(refresh, QueryResult, RefreshStats, Result)
               )).

knowledge_documents(KB, Documents) :-
    active_release(KB, Release, _Manifest),
    couchdb:find_kb_documents(KB, Release, Documents).

knowledge_documents(KB, Release0, Documents) :-
    normalize_release_value(Release0, Release),
    couchdb:find_kb_documents(KB, Release, Documents).

save_fact(Input, Saved) :-
    normalize_kb(Input, KB),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex, save_fact_unlocked(Input, KB, Saved)).

save_rule(Input, Saved) :-
    normalize_kb(Input, KB),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex, save_rule_unlocked(Input, KB, Saved)).

release_status(KB, Status) :-
    active_release(KB, Release, Manifest),
    (   Manifest == none
    ->  Status = _{kb:KB,
                    active_release:Release,
                    manifest:null,
                    legacy_fallback:true}
    ;   Status = _{kb:KB,
                    active_release:Release,
                    manifest:Manifest,
                    legacy_fallback:false}
    ).

activate_release(Input, Saved) :-
    normalize_kb(Input, KB),
    required(Input, release, Release0),
    normalize_release_value(Release0, Release),
    optional(Input, '_rev', null, ExpectedRev),
    validate_optional_revision(ExpectedRev),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( couchdb:put_kb_manifest(KB,
                                         Release,
                                         ExpectedRev,
                                         CouchReply),
                 Saved = _{kb:KB,
                           active_release:Release,
                           couchdb:CouchReply}
               )).

save_fact_unlocked(Input, KB, Saved) :-
    normalize_enabled(Input, Enabled),
    normalize_write_release(Input, KB, Release),
    put_dict(_{type:"prolog_fact",
               kb:KB,
               enabled:Enabled,
               release:Release},
             Input,
             Document),
    expert_system:validate_document(Document),
    couchdb:save_document(Document, CouchReply),
    Saved = _{document:Document, couchdb:CouchReply}.

save_rule_unlocked(Input, KB, Saved) :-
    normalize_enabled(Input, Enabled),
    normalize_write_release(Input, KB, Release),
    put_dict(_{type:"prolog_rule",
               kb:KB,
               enabled:Enabled,
               release:Release},
             Input,
             Document),
    expert_system:validate_document(Document),
    couchdb:save_document(Document, CouchReply),
    Saved = _{document:Document, couchdb:CouchReply}.

normalize_write_release(Input, KB, Release) :-
    (   get_dict(release, Input, Release0)
    ->  normalize_release_value(Release0, Release),
        ensure_release_writable(KB, Release)
    ;   active_release(KB, ActiveRelease, _Manifest),
        (   ActiveRelease == "legacy"
        ->  Release = "legacy"
        ;   throw(error(existence_error(key, release), _))
        )
    ).

ensure_release_writable(KB, Release) :-
    active_release(KB, ActiveRelease, _Manifest),
    (   ActiveRelease \== "legacy",
        ActiveRelease == Release
    ->  throw(error(permission_error(modify,
                                     active_knowledge_release,
                                     Release),
                        _))
    ;   true
    ).

resolve_query_release(KB, Options, Release) :-
    option(release(RequestedRelease), Options, null),
    (   RequestedRelease == null
    ->  active_release(KB, Release, _Manifest)
    ;   normalize_release_value(RequestedRelease, Release)
    ).

active_release(KB, Release, Manifest) :-
    couchdb:get_kb_manifest(KB, Manifest0),
    (   Manifest0 == none
    ->  Release = "legacy",
        Manifest = none
    ;   required(Manifest0, active_release, Release0),
        normalize_release_value(Release0, Release),
        Manifest = Manifest0
    ).

ensure_query_snapshot(RuntimeKB, KB, Release, Options, Stats) :-
    option(refresh(Refresh), Options, true),
    (   Refresh == true
    ->  sync_release_unlocked(RuntimeKB, KB, Release, Stats)
    ;   expert_system:knowledge_base_loaded(RuntimeKB)
    ->  Stats = _{reloaded:false,
                  synced:false,
                  full_reload:false,
                  sync_mode:"none",
                  release:Release}
    ;   refresh_release_unlocked(KB, Release, Stats)
    ).

sync_release_unlocked(RuntimeKB, KB, Release, Stats) :-
    (   expert_system:knowledge_base_loaded(RuntimeKB),
        kb_sequence(RuntimeKB, Since)
    ->  catch(sync_from_changes_unlocked(RuntimeKB,
                                         KB,
                                         Release,
                                         Since,
                                         Stats),
              error(couchdb_error(_, _), _),
              refresh_release_unlocked(KB, Release, Stats))
    ;   refresh_release_unlocked(KB, Release, Stats)
    ).

sync_from_changes_unlocked(RuntimeKB, KB, Release, Since, Stats) :-
    couchdb:changes_since(Since, Changes, LastSequence),
    apply_changes(Changes,
                  RuntimeKB,
                  KB,
                  Release,
                  0,
                  0,
                  0,
                  Applied,
                  Removed,
                  Ignored),
    set_kb_sequence(RuntimeKB, LastSequence),
    length(Changes, Seen),
    Stats = _{reloaded:true,
              synced:true,
              full_reload:false,
              sync_mode:"changes",
              release:Release,
              since:Since,
              last_seq:LastSequence,
              changes_seen:Seen,
              knowledge_applied:Applied,
              knowledge_removed:Removed,
              ignored_changes:Ignored}.

apply_changes([], _RuntimeKB, _KB, _Release,
              Applied, Removed, Ignored,
              Applied, Removed, Ignored).
apply_changes([Change|Rest], RuntimeKB, KB, Release,
              Applied0, Removed0, Ignored0,
              Applied, Removed, Ignored) :-
    apply_change(Change, RuntimeKB, KB, Release, Action),
    count_action(Action,
                 Applied0,
                 Removed0,
                 Ignored0,
                 Applied1,
                 Removed1,
                 Ignored1),
    apply_changes(Rest, RuntimeKB, KB, Release,
                  Applied1, Removed1, Ignored1,
                  Applied, Removed, Ignored).

apply_change(Change, RuntimeKB, _KB, _Release, removed) :-
    get_dict(deleted, Change, true),
    !,
    required(Change, id, Id),
    expert_system:remove_document(RuntimeKB, Id).
apply_change(Change, RuntimeKB, KB, Release, Action) :-
    (   get_dict(doc, Change, Document),
        is_dict(Document),
        document_matches_runtime(Document, KB, Release)
    ->  expert_system:upsert_document(RuntimeKB, Document, _Outcome),
        Action = applied
    ;   required(Change, id, Id),
        expert_system:remove_document(RuntimeKB, Id),
        Action = ignored
    ).

count_action(applied, A0, R, I, A, R, I) :-
    A is A0 + 1.
count_action(removed, A, R0, I, A, R, I) :-
    R is R0 + 1.
count_action(ignored, A, R, I0, A, R, I) :-
    I is I0 + 1.

document_matches_runtime(Document, KB, Release) :-
    get_dict(kb, Document, DocumentKB),
    DocumentKB == KB,
    get_dict(type, Document, Type),
    memberchk(Type, ["prolog_fact", "prolog_rule"]),
    document_release(Document, DocumentRelease),
    DocumentRelease == Release.

document_release(Document, Release) :-
    (   get_dict(release, Document, Release0)
    ->  Release = Release0
    ;   Release = "legacy"
    ).

refresh_release_unlocked(KB, Release, Stats) :-
    couchdb:database_update_seq(Sequence),
    couchdb:find_kb_documents(KB, Release, Documents),
    runtime_key(KB, Release, RuntimeKB),
    expert_system:replace_kb(RuntimeKB, Documents, LoadStats),
    set_kb_sequence(RuntimeKB, Sequence),
    length(Documents, DocumentCount),
    put_dict(_{reloaded:true,
               synced:false,
               full_reload:true,
               sync_mode:"full",
               release:Release,
               last_seq:Sequence,
               documents:DocumentCount},
             LoadStats,
             Stats).

set_kb_sequence(RuntimeKB, Sequence) :-
    retractall(kb_sequence(RuntimeKB, _)),
    assertz(kb_sequence(RuntimeKB, Sequence)).

runtime_key(KB, Release, kb_release(KB, Release)).

normalize_kb(Input, KB) :-
    (   get_dict(kb, Input, KB0)
    ->  KB = KB0
    ;   KB = "default"
    ),
    must_be(string, KB),
    string_length(KB, Length),
    Length > 0.

normalize_release_value(Value, Release) :-
    must_be(string, Value),
    string_length(Value, Length),
    (   Length > 0,
        Length =< 128
    ->  Release = Value
    ;   throw(error(domain_error(knowledge_release, Value), _))
    ).

normalize_enabled(Input, Enabled) :-
    (   get_dict(enabled, Input, Enabled0)
    ->  Enabled = Enabled0
    ;   Enabled = true
    ),
    (   memberchk(Enabled, [true, false])
    ->  true
    ;   throw(error(type_error(boolean, Enabled), _))
    ).

validate_optional_revision(null) :- !.
validate_optional_revision(Revision) :-
    must_be(string, Revision),
    string_length(Revision, Length),
    Length > 0.

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

kb_mutex(KB, Mutex) :-
    term_hash(KB, Hash),
    format(atom(Mutex), 'prolog-kb-~d', [Hash]).
