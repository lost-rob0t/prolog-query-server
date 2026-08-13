:- module(kb_service,
          [ refresh_kb/2,
            refresh_kb/3,
            query_kb/4,
            knowledge_documents/2,
            knowledge_documents/3,
            knowledge_conflicts/2,
            knowledge_conflicts/3,
            knowledge_document/2,
            save_fact/2,
            save_rule/2,
            put_knowledge_document/2,
            patch_knowledge_document/2,
            delete_knowledge_document/3,
            bulk_knowledge_documents/2,
            release_status/2,
            activate_release/2
          ]).

:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(config).
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

knowledge_conflicts(KB, Conflicts) :-
    couchdb:find_kb_documents(KB, Documents),
    conflict_inventory(KB, Documents, Conflicts).

knowledge_conflicts(KB, Release0, Conflicts) :-
    normalize_release_value(Release0, Release),
    couchdb:find_kb_documents(KB, Release, Documents),
    conflict_inventory(KB, Documents, Conflicts).

conflict_inventory(KB, Documents, Conflicts) :-
    findall(Conflict,
            ( member(Document, Documents),
              knowledge_conflict_metadata(Document, Conflict)
            ),
            DocumentConflicts),
    couchdb:get_kb_manifest(KB, Manifest),
    (   Manifest == none
    ->  ManifestConflicts = []
    ;   manifest_conflict_metadata(Manifest, ManifestConflicts)
    ),
    append(ManifestConflicts, DocumentConflicts, Conflicts).

knowledge_conflict_metadata(Document, Conflict) :-
    conflict_revisions(Document, Revisions),
    required(Document, '_id', Id),
    required(Document, '_rev', WinningRevision),
    required(Document, type, Type),
    knowledge_kind(Type, Kind),
    document_release(Document, Release),
    Conflict = _{id:Id,
                 kind:Kind,
                 release:Release,
                 winning_rev:WinningRevision,
                 conflicts:Revisions}.

manifest_conflict_metadata(Manifest, [Conflict]) :-
    conflict_revisions(Manifest, Revisions),
    !,
    required(Manifest, '_id', Id),
    required(Manifest, '_rev', WinningRevision),
    optional(Manifest, active_release, null, ActiveRelease),
    Conflict = _{id:Id,
                 kind:"manifest",
                 release:ActiveRelease,
                 winning_rev:WinningRevision,
                 conflicts:Revisions}.
manifest_conflict_metadata(_Manifest, []).

knowledge_kind("prolog_fact", "fact").
knowledge_kind("prolog_rule", "rule").

knowledge_document(Id0, Document) :-
    normalize_document_id(Id0, Id),
    couchdb:get_document(Id, Found),
    (   Found == none
    ->  throw(error(existence_error(knowledge_document, Id), _))
    ;   ensure_knowledge_type(Found),
        Document = Found
    ).

save_fact(Input, Saved) :-
    normalize_kb(Input, KB),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex, save_fact_unlocked(Input, KB, Saved)).

save_rule(Input, Saved) :-
    normalize_kb(Input, KB),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex, save_rule_unlocked(Input, KB, Saved)).

put_knowledge_document(Input, Saved) :-
    required(Input, '_id', Id0),
    normalize_document_id(Id0, Id),
    required_revision(Input, Revision),
    knowledge_document(Id, Existing),
    document_identity(Existing, Type, KB, Release),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( ensure_release_writable(KB, Release),
                 require_identity(Input, Type, KB, Release),
                 put_dict(_{'_id':Id, '_rev':Revision}, Input, Document),
                 expert_system:validate_document(Document),
                 couchdb:put_document(Id, Document, CouchReply),
                 Saved = _{document:Document, couchdb:CouchReply}
               )).

patch_knowledge_document(Input, Saved) :-
    required(Input, '_id', Id0),
    normalize_document_id(Id0, Id),
    required_revision(Input, Revision),
    knowledge_document(Id, Existing),
    document_identity(Existing, Type, KB, Release),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( ensure_release_writable(KB, Release),
                 require_optional_identity(Input, Type, KB, Release),
                 strip_patch_control(Input, Patch),
                 put_dict(Patch, Existing, Patched0),
                 put_dict(_{'_id':Id, '_rev':Revision,
                            type:Type, kb:KB, release:Release},
                          Patched0,
                          Document),
                 expert_system:validate_document(Document),
                 couchdb:put_document(Id, Document, CouchReply),
                 Saved = _{document:Document, couchdb:CouchReply}
               )).

delete_knowledge_document(Id0, Revision0, Saved) :-
    normalize_document_id(Id0, Id),
    normalize_revision(Revision0, Revision),
    knowledge_document(Id, Existing),
    document_identity(Existing, _Type, KB, Release),
    kb_mutex(KB, Mutex),
    with_mutex(Mutex,
               ( ensure_release_writable(KB, Release),
                 couchdb:delete_document(Id, Revision, CouchReply),
                 Saved = _{id:Id, revision:Revision, couchdb:CouchReply}
               )).

bulk_knowledge_documents(Input, Saved) :-
    required(Input, documents, Documents0),
    must_be(list, Documents0),
    maplist(normalize_bulk_document, Documents0, Documents),
    couchdb:bulk_documents(Documents, Results),
    Saved = _{documents:Documents, results:Results}.

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

normalize_bulk_document(Document0, Document) :-
    must_be(dict, Document0),
    ensure_knowledge_type(Document0),
    normalize_kb(Document0, KB),
    normalize_bulk_release(Document0, KB, Release),
    normalize_enabled(Document0, Enabled),
    put_dict(_{kb:KB, release:Release, enabled:Enabled}, Document0, Candidate0),
    (   get_dict('_rev', Candidate0, Revision0)
    ->  normalize_revision(Revision0, Revision),
        required(Candidate0, '_id', Id0),
        normalize_document_id(Id0, Id),
        knowledge_document(Id, Existing),
        document_identity(Existing, Type, ExistingKB, ExistingRelease),
        ensure_release_writable(ExistingKB, ExistingRelease),
        require_identity(Candidate0, Type, ExistingKB, ExistingRelease),
        put_dict(_{'_id':Id, '_rev':Revision}, Candidate0, Candidate)
    ;   ensure_release_writable(KB, Release),
        Candidate = Candidate0
    ),
    expert_system:validate_document(Candidate),
    Document = Candidate.

normalize_bulk_release(Document, KB, Release) :-
    (   get_dict(release, Document, Release0)
    ->  normalize_release_value(Release0, Release)
    ;   active_release(KB, ActiveRelease, _Manifest),
        (   ActiveRelease == "legacy"
        ->  Release = "legacy"
        ;   throw(error(existence_error(key, release), _))
        )
    ).

require_identity(Document, Type, KB, Release) :-
    required(Document, type, Type0),
    required(Document, kb, KB0),
    required(Document, release, Release0),
    identity_equal(type, Type0, Type),
    identity_equal(kb, KB0, KB),
    identity_equal(release, Release0, Release).

require_optional_identity(Document, Type, KB, Release) :-
    optional_identity(Document, type, Type),
    optional_identity(Document, kb, KB),
    optional_identity(Document, release, Release).

optional_identity(Document, Key, Expected) :-
    (   get_dict(Key, Document, Value)
    ->  identity_equal(Key, Value, Expected)
    ;   true
    ).

identity_equal(_Key, Value, Expected) :-
    Value == Expected,
    !.
identity_equal(Key, Value, Expected) :-
    throw(error(permission_error(modify,
                                 knowledge_document_identity(Key, Expected),
                                 Value),
                _)).

strip_patch_control(Input, Patch) :-
    remove_dict_key('_id', Input, A),
    remove_dict_key('_rev', A, B),
    remove_dict_key(type, B, C),
    remove_dict_key(kb, C, D),
    remove_dict_key(release, D, Patch).

remove_dict_key(Key, Dict0, Dict) :-
    (   del_dict(Key, Dict0, _Value, Dict1)
    ->  Dict = Dict1
    ;   Dict = Dict0
    ).

document_identity(Document, Type, KB, Release) :-
    required(Document, type, Type),
    required(Document, kb, KB),
    document_release(Document, Release).

ensure_knowledge_type(Document) :-
    required(Document, type, Type),
    (   memberchk(Type, ["prolog_fact", "prolog_rule"])
    ->  true
    ;   throw(error(domain_error(prolog_document_type, Type), _))
    ).

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
    ;   ensure_document_conflict_free(Manifest0),
        required(Manifest0, active_release, Release0),
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
    couchdb:ensure_storage,
    config:changes_batch_size(BatchSize),
    empty_change_totals(Totals0),
    sync_change_batches(RuntimeKB,
                        KB,
                        Release,
                        Since,
                        BatchSize,
                        Totals0,
                        LastSequence,
                        Totals),
    get_dict(changes_seen, Totals, Seen),
    get_dict(knowledge_applied, Totals, Applied),
    get_dict(knowledge_removed, Totals, Removed),
    get_dict(ignored_changes, Totals, Ignored),
    get_dict(changes_batches, Totals, Batches),
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
              ignored_changes:Ignored,
              changes_batches:Batches,
              changes_batch_size:BatchSize}.

empty_change_totals(_{changes_seen:0,
                      knowledge_applied:0,
                      knowledge_removed:0,
                      ignored_changes:0,
                      changes_batches:0}).

sync_change_batches(RuntimeKB,
                    KB,
                    Release,
                    Since,
                    BatchSize,
                    Totals0,
                    LastSequence,
                    Totals) :-
    couchdb:changes_page(Since,
                         BatchSize,
                         Changes,
                         NextSequence,
                         Pending),
    length(Changes, PageSeen),
    apply_changes_batch(Changes,
                        RuntimeKB,
                        KB,
                        Release,
                        NextSequence,
                        PageApplied,
                        PageRemoved,
                        PageIgnored),
    add_change_totals(Totals0,
                      PageSeen,
                      PageApplied,
                      PageRemoved,
                      PageIgnored,
                      Totals1),
    (   Pending =:= 0
    ->  LastSequence = NextSequence,
        Totals = Totals1
    ;   PageSeen =:= 0
    ->  LastSequence = NextSequence,
        Totals = Totals1
    ;   sync_change_batches(RuntimeKB,
                            KB,
                            Release,
                            NextSequence,
                            BatchSize,
                            Totals1,
                            LastSequence,
                            Totals)
    ).

apply_changes_batch(Changes,
                    RuntimeKB,
                    KB,
                    Release,
                    NextSequence,
                    Applied,
                    Removed,
                    Ignored) :-
    transaction(( apply_changes(Changes,
                                RuntimeKB,
                                KB,
                                Release,
                                0,
                                0,
                                0,
                                Applied,
                                Removed,
                                Ignored),
                  set_kb_sequence(RuntimeKB, NextSequence)
                )).

add_change_totals(Totals0,
                  Seen,
                  Applied,
                  Removed,
                  Ignored,
                  Totals) :-
    get_dict(changes_seen, Totals0, Seen0),
    get_dict(knowledge_applied, Totals0, Applied0),
    get_dict(knowledge_removed, Totals0, Removed0),
    get_dict(ignored_changes, Totals0, Ignored0),
    get_dict(changes_batches, Totals0, Batches0),
    Seen1 is Seen0 + Seen,
    Applied1 is Applied0 + Applied,
    Removed1 is Removed0 + Removed,
    Ignored1 is Ignored0 + Ignored,
    Batches1 is Batches0 + 1,
    put_dict(_{changes_seen:Seen1,
               knowledge_applied:Applied1,
               knowledge_removed:Removed1,
               ignored_changes:Ignored1,
               changes_batches:Batches1},
             Totals0,
             Totals).

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
    ->  ensure_document_conflict_free(Document),
        expert_system:upsert_document(RuntimeKB, Document, _Outcome),
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

ensure_documents_conflict_free(Documents) :-
    maplist(ensure_document_conflict_free, Documents).

ensure_document_conflict_free(Document) :-
    (   conflict_revisions(Document, Revisions)
    ->  required(Document, '_id', Id),
        throw(error(permission_error(load,
                                     conflicted_knowledge_document,
                                     _{id:Id, conflicts:Revisions}),
                    _))
    ;   true
    ).

conflict_revisions(Document, Revisions) :-
    get_dict('_conflicts', Document, Revisions),
    is_list(Revisions),
    Revisions \== [].

document_release(Document, Release) :-
    (   get_dict(release, Document, Release0)
    ->  normalize_release_value(Release0, Release)
    ;   Release = "legacy"
    ).

refresh_release_unlocked(KB, Release, Stats) :-
    couchdb:database_update_seq(Sequence),
    couchdb:find_kb_documents(KB, Release, Documents),
    ensure_documents_conflict_free(Documents),
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

normalize_document_id(Value, Id) :-
    must_be(string, Value),
    string_length(Value, Length),
    (   Length > 0
    ->  Id = Value
    ;   throw(error(domain_error(document_id, Value), _))
    ).

normalize_revision(Value, Revision) :-
    must_be(string, Value),
    string_length(Value, Length),
    (   Length > 0
    ->  Revision = Value
    ;   throw(error(domain_error(document_revision, Value), _))
    ).

required_revision(Input, Revision) :-
    required(Input, '_rev', Revision0),
    normalize_revision(Revision0, Revision).

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
    normalize_revision(Revision, _).

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
